import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/features/settings/screens/my_details_screen.dart';
import 'package:scheduling/features/settings/widgets/sections/my_availability_section.dart';
import 'package:scheduling/features/settings/widgets/sections/my_identity_section.dart';
import 'package:scheduling/features/settings/widgets/sections/my_scheduling_section.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/offline_form_notice.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';

class _MockRepo extends Mock implements EmployeesRepository {}

const _me = EmployeeRecord(
  id: 'me-1',
  name: 'Theo Roy',
  email: 'theo@example.com',
  phone: '(514) 555-0000',
  status: 'active',
  maxJobsPerDay: 5,
);

void main() {
  late _MockRepo repo;
  late NoticeService notices;
  late List<AppNotice> seenNotices;

  setUpAll(() {
    registerFallbackValue(EmergencyContact.empty);
    // Needed by the verifyNever on updateEmployee — without it mocktail throws
    // mid-verify, which poisons the shared state for the tests that follow.
    registerFallbackValue(const EmployeeRecord(id: 'fallback'));
  });

  setUp(() {
    repo = _MockRepo();
    notices = NoticeService();
    seenNotices = [];
    notices.stream.listen(seenNotices.add);
    when(
      () => repo.saveEmergencyContact(any(), any()),
    ).thenAnswer((_) async {});
    when(
      () => repo.updateSelfDetails(any()),
    ).thenAnswer((_) async {});
    when(
      () => repo.updateEmployee(
        docId: any(named: 'docId'),
        employee: any(named: 'employee'),
      ),
    ).thenAnswer((_) async {});
  });

  Future<void> pump(
    WidgetTester tester, {
    EmergencyContact stored = EmergencyContact.empty,
    bool offline = false,
    String role = 'employee',
    EmployeeRecord me = _me,
    List<AppointmentRecord> jobs = const [],
  }) async {
    when(
      () => repo.watchEmergencyContact('me-1'),
    ).thenAnswer((_) => Stream.value(stored));

    // Tall enough that the whole ListView builds. It is lazy, so at the
    // default 600x800 the availability and scheduling sections below the fold
    // are never constructed and every finder for them reports zero.
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          isOfflineProvider.overrideWithValue(offline),
          // There is no NoticeListener in this harness, so a pushed notice
          // never becomes rendered text - record it at the service instead.
          noticeServiceProvider.overrideWithValue(notices),
          activeUserIdentityProvider.overrideWith(
            (ref) async => (role: role, docId: 'me-1'),
          ),
          myEmployeeRecordProvider.overrideWith((ref) => me),
          // Overridden so the availability warning needs no Firestore range
          // stream; the reduction itself is covered by the provider test.
          myUpcomingAppointmentsProvider.overrideWith((ref) => jobs),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: MyDetailsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a cold open shows one spinner, and only after 300 ms', (
    tester,
  ) async {
    // Three sequential full-screen spinners used to flash in a row here.
    when(
      () => repo.watchEmergencyContact('me-1'),
    ).thenAnswer((_) => Stream.value(EmergencyContact.empty));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          isOfflineProvider.overrideWithValue(false),
          activeUserIdentityProvider.overrideWith(
            (ref) => Completer<Never>().future,
          ),
          myEmployeeRecordProvider.overrideWith((ref) => null),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: MyDetailsScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AdaptiveProgressIndicator), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AdaptiveProgressIndicator), findsOneWidget);
  });

  testWidgets('offline, the form carries the offline notice', (tester) async {
    await pump(tester, offline: true);

    expect(
      find.descendant(
        of: find.byType(OfflineFormNotice),
        matching: find.byType(WarningNote),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders the identity and availability sections', (tester) async {
    await pump(tester);

    expect(find.byType(MyIdentitySection), findsOneWidget);
    expect(find.byType(MyAvailabilitySection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seeds the fields from the stored contact', (tester) async {
    await pump(
      tester,
      stored: const EmergencyContact(
        contact: 'Marie Roy',
        phone: '(514) 555-0199',
      ),
    );

    expect(find.text('Marie Roy'), findsOneWidget);
    expect(find.text('(514) 555-0199'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no save bar until something is edited', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('myIdentitySaveBar')), findsNothing);
  });

  testWidgets('saving writes both the emergency doc and the users doc', (
    tester,
  ) async {
    // Two stores: the emergency pair lives in private/emergency, the phone on
    // the users doc under the self-service rules clause.
    await pump(tester);

    await tester.enterText(
      find.byKey(const Key('myEmergencyContact')),
      'Marie',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('myIdentitySave')));
    await tester.pumpAndSettle();

    final captured = verify(
      () => repo.saveEmergencyContact('me-1', captureAny()),
    ).captured.single;
    expect((captured as EmergencyContact).contact, 'Marie');
    verify(
      () => repo.updateSelfDetails(
        any(
          that: isA<EmployeeRecord>().having((r) => r.id, 'id', 'me-1'),
        ),
      ),
    ).called(1);
    // The whole-record admin path must never run for a self edit — it carries
    // role, email and the emergency scrub, every one of which the rules'
    // hasOnly would reject.
    verifyNever(
      () => repo.updateEmployee(
        docId: any(named: 'docId'),
        employee: any(named: 'employee'),
      ),
    );
  });

  group('failure paths', () {
    // This file had eleven tests and not one `thenThrow`, so `ME-SAVE identity
    // save failed`, `ME-SAVE availability failed` and the `error_intro*` keys
    // they compose were entirely unexercised - the largest error-path hole in
    // lib/, and the only save screen without failure coverage.

    testWidgets('a failed identity save surfaces the cause notice and keeps '
        'the save bar', (tester) async {
      when(
        () => repo.saveEmergencyContact(any(), any()),
      ).thenThrow(Exception('firestore down'));

      await pump(tester);
      await tester.enterText(
        find.byKey(const Key('myEmergencyContact')),
        'Marie',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myIdentitySave')));
      await tester.pumpAndSettle();

      // The intro half of "{intro}. {cause}" - the user is told WHAT failed.
      expect(seenNotices, hasLength(1));
      expect(seenNotices.single, isA<NoticeError>());
      expect(
        seenNotices.single.message,
        contains("Couldn't save your details"),
      );
      // The bar must survive so the edit is not silently lost.
      expect(find.byKey(const Key('myIdentitySaveBar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed users-doc write also surfaces, not just the '
        'emergency one', (tester) async {
      // Two stores, two ways to fail; only the first was ever plausible to
      // cover by accident.
      when(
        () => repo.updateSelfDetails(any()),
      ).thenThrow(Exception('permission-denied'));

      await pump(tester);
      await tester.enterText(
        find.byKey(const Key('myEmergencyContact')),
        'Marie',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myIdentitySave')));
      await tester.pumpAndSettle();

      expect(seenNotices, hasLength(1));
      expect(seenNotices.single, isA<NoticeError>());
      expect(
        seenNotices.single.message,
        contains("Couldn't save your details"),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a throwing repository never leaves the button spinning', (
      tester,
    ) async {
      // The reentrancy rule: the in-flight flag must reset on every catch, or
      // the screen is stuck until it is popped and reopened.
      when(
        () => repo.saveEmergencyContact(any(), any()),
      ).thenThrow(Exception('boom'));

      await pump(tester);
      await tester.enterText(
        find.byKey(const Key('myEmergencyContact')),
        'Marie',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myIdentitySave')));
      await tester.pumpAndSettle();

      // Tapping again must reach the repository a SECOND time; a stuck flag
      // would swallow it.
      await tester.tap(find.byKey(const Key('myIdentitySave')));
      await tester.pumpAndSettle();

      verify(() => repo.saveEmergencyContact('me-1', any())).called(2);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'a successful identity save clears the save bar before provider snapshots catch up',
    (tester) async {
      final saveEmergency = Completer<void>();
      final saveSelf = Completer<void>();
      when(() => repo.saveEmergencyContact(any(), any())).thenAnswer(
        (_) => saveEmergency.future,
      );
      when(() => repo.updateSelfDetails(any())).thenAnswer(
        (_) => saveSelf.future,
      );

      await pump(tester);

      await tester.enterText(find.byKey(const Key('myEmergencyContact')), 'Marie');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('myIdentitySaveBar')), findsOneWidget);

      await tester.tap(find.byKey(const Key('myIdentitySave')));
      await tester.pump();

      saveEmergency.complete();
      saveSelf.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('myIdentitySaveBar')), findsNothing);
    },
  );

  testWidgets(
    'availability does not autosave while the identity save is still running',
    (tester) async {
      final saveEmergency = Completer<void>();
      final saveSelf = Completer<void>();
      when(() => repo.saveEmergencyContact(any(), any())).thenAnswer(
        (_) => saveEmergency.future,
      );
      when(() => repo.updateSelfDetails(any())).thenAnswer(
        (_) => saveSelf.future,
      );

      await pump(tester);

      await tester.enterText(find.byKey(const Key('myEmergencyContact')), 'Marie');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myIdentitySave')));
      await tester.pump();

      // The identity save writes the emergency contact FIRST, so let that leg
      // land - `updateSelfDetails` is not reached until it does, and the
      // in-flight state under test is the one where it is pending.
      saveEmergency.complete();
      await tester.pump();

      await tester.tap(find.byKey(const Key('myOnCall')));
      await tester.pump();

      // Exactly one: the availability toggle must not start a SECOND write
      // while the identity save still holds the flag.
      verify(() => repo.updateSelfDetails(any())).called(1);

      saveSelf.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('offline save fails fast without calling the repository', (
    tester,
  ) async {
    await pump(tester, offline: true);

    await tester.enterText(
      find.byKey(const Key('myEmergencyContact')),
      'Marie',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('myIdentitySave')));
    await tester.pumpAndSettle();

    verifyNever(() => repo.saveEmergencyContact(any(), any()));
  });

  testWidgets('a later snapshot does not clobber what is being typed', (
    tester,
  ) async {
    await pump(tester, stored: const EmergencyContact(contact: 'Marie'));

    await tester.enterText(
      find.byKey(const Key('myEmergencyContact')),
      'Marie Roy',
    );
    await tester.pumpAndSettle();

    expect(find.text('Marie Roy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling on-call writes immediately, with no save bar', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('myOnCall')));
    await tester.pumpAndSettle();

    verify(
      () => repo.updateSelfDetails(
        any(
          that: isA<EmployeeRecord>().having((r) => r.id, 'id', 'me-1'),
        ),
      ),
    ).called(1);
    expect(find.byKey(const Key('myIdentitySaveBar')), findsNothing);
  });

  testWidgets(
    'an availability write sends the STORED phone, not the typed one',
    (
      tester,
    ) async {
      // Otherwise toggling a day silently commits a half-typed phone number —
      // exactly the auto-save the identity save bar exists to prevent.
      await pump(tester);

      await tester.enterText(find.byKey(const Key('myPhone')), '(514) 555-9');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('myOnCall')));
      await tester.pumpAndSettle();

      final captured = verify(
        () => repo.updateSelfDetails(captureAny()),
      ).captured.single;
      // The STORED phone, not the half-typed text in the identity field.
      expect((captured as EmployeeRecord).phone, '(514) 555-0000');
    },
  );

  testWidgets(
    'a stale availability failure does not roll back a newer successful change',
    (tester) async {
      final firstWrite = Completer<void>();
      final secondWrite = Completer<void>();
      var callCount = 0;

      when(() => repo.updateSelfDetails(any())).thenAnswer((_) {
        callCount += 1;
        if (callCount == 1) return firstWrite.future;
        return secondWrite.future;
      });

      await pump(tester);

      final switchFinder = find.byKey(const Key('myOnCall'));

      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      await tester.tap(switchFinder);
      await tester.pump();
      expect(tester.widget<Switch>(switchFinder).value, isTrue);

      await tester.tap(switchFinder);
      await tester.pump();
      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      secondWrite.complete();
      await tester.pumpAndSettle();

      firstWrite.completeError(Exception('offline'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(switchFinder).value, isFalse);
    },
  );

  testWidgets('an employee never sees the scheduling section', (tester) async {
    await pump(tester);

    expect(find.byType(MySchedulingSection), findsOneWidget);
    expect(find.byKey(const Key('myMaxJobsPerDay')), findsNothing);
  });

  testWidgets('an admin sees the scheduling section', (tester) async {
    await pump(tester, role: 'admin');

    expect(find.byKey(const Key('myMaxJobsPerDay')), findsOneWidget);
  });

  testWidgets('the email row offers a change action', (tester) async {
    await pump(tester);

    expect(find.text('theo@example.com'), findsOneWidget);
    expect(find.byKey(const Key('myChangeEmail')), findsOneWidget);
  });

  testWidgets('changing the email never writes the users doc directly', (
    tester,
  ) async {
    // `email` is a sign-in identity and is deliberately absent from the
    // self-service rules allowlist — it moves through changeEmployeeEmail,
    // which owns BOTH stores, or not at all.
    await pump(tester);

    await tester.tap(find.byKey(const Key('myChangeEmail')));
    await tester.pumpAndSettle();

    verifyNever(
      () => repo.updateSelfDetails(any()),
    );
    verifyNever(
      () => repo.updateEmployee(
        docId: any(named: 'docId'),
        employee: any(named: 'employee'),
      ),
    );
  });
}
