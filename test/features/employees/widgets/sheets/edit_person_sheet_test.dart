import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/account_deletion_service.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';
import 'package:scheduling/features/employees/widgets/sheets/edit_person_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockRepo extends Mock implements EmployeesRepository {}

class _MockReauth extends Mock implements AccountDeletionService {}

void main() {
  late _MockRepo repo;
  late _MockReauth reauth;

  setUpAll(() {
    registerFallbackValue(const EmployeeRecord(id: 'fallback'));
    registerFallbackValue(EmergencyContact.empty);
  });

  setUp(() {
    repo = _MockRepo();
    reauth = _MockReauth();
    when(
      () => reauth.reauthenticateWithPassword(any()),
    ).thenAnswer((_) async {});
    // The sheet's body is a lazy scroll view, so a phone-sized viewport never
    // builds the availability panel or the footer. Every test but the scale
    // sweep runs tall enough to build the whole form at once.

    when(
      () => repo.updateEmployee(
        docId: any(named: 'docId'),
        employee: any(named: 'employee'),
      ),
    ).thenAnswer((_) async {});

    // The emergency pair is a second read/write against
    // users/{id}/private/emergency, not a field on the record.
    when(
      () => repo.watchEmergencyContact(any()),
    ).thenAnswer((_) => Stream.value(EmergencyContact.empty));
    when(
      () => repo.saveEmergencyContact(any(), any()),
    ).thenAnswer((_) async {});
  });

  /// Builds the whole lazy form at once so a below-the-fold row is findable.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget wrap(
    EmployeeRecord employee, {
    Set<int> usedColors = const {},
    int futureAssignments = 0,
    bool offline = false,
    double textScale = 1,
    String? signedInUid = 'admin-uid',
    NoticeService? notices,
  }) => ProviderScope(
    overrides: [
      employeesRepositoryProvider.overrideWithValue(repo),
      accountDeletionServiceProvider.overrideWithValue(reauth),
      isOfflineProvider.overrideWithValue(offline),
      authUidProvider.overrideWith((ref) => Stream<String?>.value(signedInUid)),
      if (notices != null) noticeServiceProvider.overrideWithValue(notices),
      futureAssignmentCountProvider(
        employee.id,
      ).overrideWith((_) async => futureAssignments),
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: textScale,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: EditPersonSheet(employee: employee, usedColors: usedColors),
        ),
      ),
    ),
  );

  /// The single EmployeeRecord the mocked repository received.
  EmployeeRecord capturedSave() =>
      verify(
            () => repo.updateEmployee(
              docId: any(named: 'docId'),
              employee: captureAny(named: 'employee'),
            ),
          ).captured.single
          as EmployeeRecord;

  void verifyNoSave() => verifyNever(
    () => repo.updateEmployee(
      docId: any(named: 'docId'),
      employee: any(named: 'employee'),
    ),
  );

  testWidgets('saving composes name from first and last', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap(const EmployeeRecord(id: 'e1', name: 'Old')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('firstName')), 'Theo');
    await tester.enterText(find.byKey(const Key('lastName')), 'Roy');
    await tester.enterText(find.byKey(const Key('email')), 'theo@x.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(capturedSave().name, 'Theo Roy');
  });

  testWidgets('the email stays editable once an Auth account exists', (
    tester,
  ) async {
    // It was read-only while the field wrote Firestore alone. The repository
    // now routes a change through changeEmployeeEmail, so Auth and the users
    // doc move together and the admin can fix a wrong address.
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          name: 'Theo',
          email: 'old@x.com',
          uid: 'auth-uid',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('email')), 'new@x.com');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(capturedSave().email, 'new@x.com');
  });

  testWidgets('a legacy single-name doc seeds First and survives a save', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(const EmployeeRecord(id: 'e1', name: 'Jean-Luc', email: 'j@x.com')),
    );
    await tester.pumpAndSettle();

    // Seeded, so the admin can actually see and edit the stored name.
    expect(find.text('Jean-Luc'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Never blank: the repository preserves the stored fallback name.
    expect(capturedSave().name, 'Jean-Luc');
  });

  testWidgets('an end at or before the start blocks Save', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          name: 'Theo',
          email: 'theo@x.com',
          // Equal to the default start: an end that is not after it.
          workEndMinutes: kDefaultWorkStartMinutes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Must be after start time'), findsOneWidget);
    verifyNoSave();
  });

  testWidgets('the test account switch is saved with the record', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('testAccount')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(capturedSave().isTestAccount, isTrue);
  });

  testWidgets('picking a job title does not touch the admin toggle', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dispatcher'));
    await tester.pumpAndSettle();

    // jobTitle is what they do; role is what they can see. Never coupled.
    final adminSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('adminAccess')),
    );
    expect(adminSwitch.value, isFalse);
  });

  testWidgets('max jobs per day is picked, and no cap saves as 0', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          name: 'Theo',
          email: 'theo@x.com',
          maxJobsPerDay: 5,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Renders the stored cap, not an empty field.
    expect(find.text('5'), findsOneWidget);

    await tester.tap(find.text('Max jobs per day'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No cap').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(capturedSave().maxJobsPerDay, 0);
  });

  testWidgets('shows how many colours are left', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com'),
        usedColors: const {
          0xFF005CC8, // crewPalette[0]
          0xFF7A3FF2, // crewPalette[1]
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('8 colours left'), findsOneWidget);
  });

  testWidgets('shows the reassign count under Disable', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com'),
        futureAssignments: 3,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('3 upcoming jobs stay assigned'),
      findsOneWidget,
    );
  });

  testWidgets('disabling asks for confirmation and calls the repository', (
    tester,
  ) async {
    when(() => repo.deactivateEmployee('e1')).thenAnswer((_) async {});

    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          name: 'Theo',
          email: 'theo@x.com',
          status: 'active',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disable employee'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "This employee will be signed out immediately and won't be able to "
        'log back in.',
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Disable employee'),
      ),
    );
    await tester.pumpAndSettle();

    verify(() => repo.deactivateEmployee('e1')).called(1);
    // The footer flips to the re-enable action without leaving the sheet.
    expect(find.text('Enable employee'), findsOneWidget);
  });

  testWidgets('saving disables the status toggle until the write finishes', (
    tester,
  ) async {
    final saveCompleter = Completer<void>();
    when(
      () => repo.updateEmployee(
        docId: any(named: 'docId'),
        employee: any(named: 'employee'),
      ),
    ).thenAnswer((_) => saveCompleter.future);

    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          name: 'Theo',
          email: 'theo@x.com',
          status: 'active',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump();

    final disableButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Disable employee'),
    );
    expect(disableButton.onPressed, isNull);

    saveCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('status toggle disables Save until the change finishes', (
    tester,
  ) async {
    final toggleCompleter = Completer<void>();
    when(
      () => repo.deactivateEmployee('e1'),
    ).thenAnswer((_) => toggleCompleter.future);

    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          name: 'Theo',
          email: 'theo@x.com',
          status: 'active',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disable employee'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Disable employee'),
      ),
    );
    await tester.pump();

    expect(find.text('Save'), findsNothing);

    toggleCompleter.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('offline save fails fast without calling the repository', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com'),
        offline: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    verifyNoSave();
  });

  testWidgets('saving before the emergency read lands leaves it untouched', (
    tester,
  ) async {
    // The pair lives in users/{id}/private/emergency and seeds asynchronously,
    // so the two fields are blank until it arrives. Writing them anyway merged
    // two empty strings over a stored contact and destroyed it.
    when(
      () => repo.watchEmergencyContact(any()),
    ).thenAnswer((_) => const Stream<EmergencyContact>.empty());

    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The users doc still saves — only the emergency write is withheld.
    capturedSave();
    verifyNever(() => repo.saveEmergencyContact(any(), any()));
  });

  testWidgets('a loaded emergency contact is written back on save', (
    tester,
  ) async {
    when(() => repo.watchEmergencyContact(any())).thenAnswer(
      (_) => Stream.value(
        const EmergencyContact(contact: 'Marie', phone: '555-0199'),
      ),
    );

    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => repo.saveEmergencyContact('e1', captureAny()),
    ).captured.single;
    expect((captured as EmergencyContact).contact, 'Marie');
    expect(captured.phone, '555-0199');
  });

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(id: 'e1', name: 'Theo', email: 'theo@x.com'),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('an admin gets the month-end reminder switch, and it saves', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e1',
          firstName: 'Paul',
          email: 'paul@example.com',
          role: 'admin',
          status: 'active',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('monthEndReviewPush')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(capturedSave().monthEndReviewPush, isTrue);
  });

  testWidgets('a non-admin never sees the month-end reminder switch', (
    tester,
  ) async {
    useTallViewport(tester);
    await tester.pumpWidget(
      wrap(
        const EmployeeRecord(
          id: 'e2',
          firstName: 'Theo',
          email: 'theo@example.com',
          status: 'active',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('monthEndReviewPush')), findsNothing);
  });

  group('Reset password', () {
    const teammate = EmployeeRecord(
      id: 'e1',
      name: 'Theo',
      email: 'theo@x.com',
      status: 'active',
      uid: 'emp-uid',
    );
    const issued = NewAccountCredentials(
      email: 'theo@x.com',
      password: 'Tmp2pass!wd9',
    );
    final resetButton = find.byKey(const Key('resetPassword'));
    Finder confirmButton() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Reset password'),
    );

    /// The confirm doubles as the admin's re-auth: it enables only once their
    /// own password is typed.
    Future<void> confirmWithPassword(WidgetTester tester) async {
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'admin-pw',
      );
      await tester.pump();
      await tester.tap(confirmButton());
    }

    testWidgets('an active teammate offers Reset password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      expect(resetButton, findsOneWidget);
    });

    testWidgets('the signed-in admin gets no Reset on their own sheet', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, signedInUid: 'emp-uid'));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('an unknown signed-in uid hides Reset password', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, signedInUid: null));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('a person with no uid has no Reset password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate.copyWith(uid: '')));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('disabling the person in the sheet hides Reset password', (
      tester,
    ) async {
      when(() => repo.deactivateEmployee('e1')).thenAnswer((_) async {});
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Disable employee'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Disable employee'),
        ),
      );
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('a disabled person has no Reset password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate.copyWith(status: 'disabled')));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('an invited person has no Reset password here', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate.copyWith(status: 'invited')));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('confirming issues and shows the temporary password', (
      tester,
    ) async {
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) async => issued);
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      expect(find.text("Reset Theo's password?"), findsOneWidget);
      await confirmWithPassword(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(() => repo.resetEmployeePassword('e1')).called(1);
      expect(find.text('Password reset'), findsOneWidget);
      expect(find.text('Tmp2pass!wd9'), findsOneWidget);
      expect(
        find.text('New temporary password — the previous one no longer works'),
        findsOneWidget,
      );
      expect(find.textContaining('first time they sign in'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing the sheet mid-reset still shows the password', (
      tester,
    ) async {
      final pending = Completer<NewAccountCredentials>();
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) => pending.future);
      useTallViewport(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeesRepositoryProvider.overrideWithValue(repo),
            accountDeletionServiceProvider.overrideWithValue(reauth),
            isOfflineProvider.overrideWithValue(false),
            authUidProvider.overrideWith(
              (ref) => Stream<String?>.value('admin-uid'),
            ),
            futureAssignmentCountProvider('e1').overrideWith((_) async => 0),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: lightTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const EditPersonSheet(employee: teammate),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await confirmWithPassword(tester);
      await tester.pump();

      // A drag-dismiss pops the route directly, which PopScope cannot veto.
      Navigator.of(tester.element(find.byType(EditPersonSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(EditPersonSheet), findsNothing);

      pending.complete(issued);
      await tester.pumpAndSettle();

      expect(find.text('Password reset'), findsOneWidget);
      expect(find.text('Tmp2pass!wd9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling at the re-auth prompt resets nothing', (
      tester,
    ) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      // The sheet header carries its own Cancel, so scope to the dialog.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      verifyNever(() => reauth.reauthenticateWithPassword(any()));
      verifyNever(() => repo.resetEmployeePassword(any()));
    });

    testWidgets('a failed reset composes the reset-password notice', (
      tester,
    ) async {
      final notices = NoticeService();
      final seen = <AppNotice>[];
      notices.stream.listen(seen.add);
      when(() => repo.resetEmployeePassword('e1')).thenThrow(Exception('boom'));
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, notices: notices));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await confirmWithPassword(tester);
      await tester.pumpAndSettle();

      expect(seen.single, isA<NoticeError>());
      expect(seen.single.message, startsWith("Couldn't reset the password"));
    });

    testWidgets('offline, the reset fails fast without the server', (
      tester,
    ) async {
      final notices = NoticeService();
      final seen = <AppNotice>[];
      notices.stream.listen(seen.add);
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, offline: true, notices: notices));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await confirmWithPassword(tester);
      await tester.pumpAndSettle();

      verifyNever(() => repo.resetEmployeePassword(any()));
      expect(seen.single, isA<NoticeError>());
    });

    testWidgets('an admin teammate has no Reset password', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate.copyWith(role: 'admin')));
      await tester.pumpAndSettle();

      expect(resetButton, findsNothing);
    });

    testWidgets('the admin re-authenticates BEFORE the reset is called', (
      tester,
    ) async {
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenAnswer((_) async => issued);
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(confirmButton()).onPressed,
        isNull,
        reason: 'no password typed yet',
      );
      await confirmWithPassword(tester);
      await tester.pumpAndSettle();

      verifyInOrder([
        () => reauth.reauthenticateWithPassword('admin-pw'),
        () => repo.resetEmployeePassword('e1'),
      ]);
    });

    testWidgets('a wrong admin password resets nothing and says so', (
      tester,
    ) async {
      final notices = NoticeService();
      final seen = <AppNotice>[];
      notices.stream.listen(seen.add);
      when(
        () => reauth.reauthenticateWithPassword(any()),
      ).thenThrow(const AuthFailureWrongCredentials());
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, notices: notices));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await confirmWithPassword(tester);
      await tester.pumpAndSettle();

      verifyNever(() => repo.resetEmployeePassword(any()));
      expect(seen.single.message, 'Invalid email or password');
    });

    testWidgets('an admin-target refusal shows its own message', (
      tester,
    ) async {
      final notices = NoticeService();
      final seen = <AppNotice>[];
      notices.stream.listen(seen.add);
      when(
        () => repo.resetEmployeePassword('e1'),
      ).thenThrow(const EmployeesFailureTargetIsAdmin());
      useTallViewport(tester);
      await tester.pumpWidget(wrap(teammate, notices: notices));
      await tester.pumpAndSettle();

      await tester.tap(resetButton);
      await tester.pumpAndSettle();
      await confirmWithPassword(tester);
      await tester.pumpAndSettle();

      expect(
        seen.single.message,
        "An admin's password can't be reset from here.",
      );
    });

    testWidgets('the footer survives 260 px at 2.0 text scale', (tester) async {
      tester.view.physicalSize = const Size(260, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(teammate, textScale: 2));
      await tester.pumpAndSettle();
      // Lazy form: its extent grows as rows build, so jump until built.
      final list = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      for (var i = 0; i < 5 && resetButton.evaluate().isEmpty; i++) {
        list.position.jumpTo(list.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }

      expect(resetButton, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
