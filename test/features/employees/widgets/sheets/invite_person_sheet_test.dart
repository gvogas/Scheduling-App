import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/widgets/sheets/invite_person_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';

import '../../../../support/tour_test_support.dart';

class _MockRepo extends Mock implements EmployeesRepository {}

void main() {
  late _MockRepo repo;

  setUp(() {
    markFormToursSeen();
    repo = _MockRepo();
    when(
      () => repo.createEmployeeAccount(
        name: any(named: 'name'),
        firstName: any(named: 'firstName'),
        lastName: any(named: 'lastName'),
        email: any(named: 'email'),
        phone: any(named: 'phone'),
        colorValue: any(named: 'colorValue'),
        jobTitle: any(named: 'jobTitle'),
      ),
    ).thenAnswer(
      (_) async => const NewAccountCredentials(
        email: 'zoe@example.com',
        password: 'Welcome123!',
      ),
    );
  });

  /// Builds the whole lazy form at once so a below-the-fold row is findable.
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget wrap({Set<int> usedColors = const {}, double textScale = 1}) =>
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          isOfflineProvider.overrideWithValue(false),
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
            home: Scaffold(body: InvitePersonSheet(usedColors: usedColors)),
          ),
        ),
      );

  Future<void> fillRequired(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('firstName')), 'Theo');
    await tester.enterText(find.byKey(const Key('lastName')), 'Roy');
    await tester.enterText(find.byKey(const Key('email')), 'theo@x.com');
    await tester.pumpAndSettle();
  }

  testWidgets('sends every field to the callable', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await fillRequired(tester);
    await tester.tap(find.text('Technician'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send Invite'));
    // Fixed-duration pump: the dialog's SelectableText cursor never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(
      () => repo.createEmployeeAccount(
        name: 'Theo Roy',
        firstName: 'Theo',
        lastName: 'Roy',
        email: 'theo@x.com',
        phone: '',
        colorValue: any(named: 'colorValue'),
        jobTitle: 'technician',
      ),
    ).called(1);
  });

  testWidgets('offers no admin toggle — new accounts are always employees', (
    tester,
  ) async {
    // Tall viewport: the lazy sheet body must actually build past where the
    // access section used to sit, or `findsNothing` proves nothing.
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // Positive anchor: the invited note is the LAST widget in the body, at
    // the tail of the colour section — exactly where the deleted access
    // section used to begin. Finding it proves the form built past that
    // point, so the `findsNothing` below is a real absence and not an
    // unbuilt row. (`FormSheetFrame`'s ListView carries
    // kTourScrollCacheExtent = 3000px, which with this viewport builds the
    // whole form anyway — but the anchor is the half that survives someone
    // shrinking either number.)
    expect(find.byType(WarningNote), findsOneWidget);
    expect(find.byKey(const Key('adminAccess')), findsNothing);
  });

  testWidgets('shows the credentials dialog on success', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await fillRequired(tester);
    await tester.tap(find.text('Send Invite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Both halves: the password alone loses which account it opens.
    expect(find.text('zoe@example.com'), findsOneWidget);
    expect(find.text('Welcome123!'), findsOneWidget);
    expect(find.textContaining('first time they sign in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing the sheet mid-create still shows the password', (
    tester,
  ) async {
    final pending = Completer<NewAccountCredentials>();
    when(
      () => repo.createEmployeeAccount(
        name: any(named: 'name'),
        firstName: any(named: 'firstName'),
        lastName: any(named: 'lastName'),
        email: any(named: 'email'),
        phone: any(named: 'phone'),
        colorValue: any(named: 'colorValue'),
        jobTitle: any(named: 'jobTitle'),
      ),
    ).thenAnswer((_) => pending.future);
    useTallViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(repo),
          isOfflineProvider.overrideWithValue(false),
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
                  builder: (_) => const InvitePersonSheet(),
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

    await fillRequired(tester);
    await tester.tap(find.text('Send Invite'));
    await tester.pump();

    // A drag-dismiss pops the route directly, which PopScope cannot veto.
    Navigator.of(tester.element(find.byType(InvitePersonSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(InvitePersonSheet), findsNothing);

    pending.complete(
      const NewAccountCredentials(
        email: 'theo@x.com',
        password: 'Tmp2pass!wd9',
      ),
    );
    // Fixed-duration pump: the dialog's SelectableText cursor never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('theo@x.com'), findsOneWidget);
    expect(find.text('Tmp2pass!wd9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an email already in use becomes a field error, not a notice', (
    tester,
  ) async {
    when(
      () => repo.createEmployeeAccount(
        name: any(named: 'name'),
        firstName: any(named: 'firstName'),
        lastName: any(named: 'lastName'),
        email: any(named: 'email'),
        phone: any(named: 'phone'),
        colorValue: any(named: 'colorValue'),
        jobTitle: any(named: 'jobTitle'),
      ),
    ).thenThrow(const EmployeesFailureEmailAlreadyExists());

    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await fillRequired(tester);
    await tester.tap(find.text('Send Invite'));
    await tester.pumpAndSettle();

    expect(
      find.text('An employee with this email already exists'),
      findsOneWidget,
    );
    // The sheet stays open on a field error.
    expect(find.text('Send Invite'), findsOneWidget);
  });

  testWidgets('seeds a colour nobody already holds', (tester) async {
    useTallViewport(tester);
    // crewPalette[0] is taken, so the default pick must move on.
    await tester.pumpWidget(wrap(usedColors: const {0xFF005CC8}));
    await tester.pumpAndSettle();

    await fillRequired(tester);
    await tester.tap(find.text('Send Invite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final captured = verify(
      () => repo.createEmployeeAccount(
        name: any(named: 'name'),
        firstName: any(named: 'firstName'),
        lastName: any(named: 'lastName'),
        email: any(named: 'email'),
        phone: any(named: 'phone'),
        colorValue: captureAny(named: 'colorValue'),
        jobTitle: any(named: 'jobTitle'),
      ),
    ).captured.single;
    expect(captured, isNot('${0xFF005CC8}'));
  });

  testWidgets('renders the invited note', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // Wording follows P4c: the admin hands over a starting password, there is
    // no signup code to "sign up with" any more.
    expect(find.textContaining('starting password'), findsOneWidget);
  });

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
