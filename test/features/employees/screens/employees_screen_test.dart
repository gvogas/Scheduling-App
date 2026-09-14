import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/screens/employees_screen.dart';
import 'package:scheduling/features/employees/widgets/cards/employee_card.dart';
import 'package:scheduling/features/employees/widgets/cards/employee_profile_card.dart';
import 'package:scheduling/features/employees/widgets/cards/pending_invite_tile.dart';
import 'package:scheduling/features/employees/widgets/fields/employee_color_grid.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

const _jane = EmployeeRecord(
  id: 'e1',
  name: 'Jane Doe',
  email: 'jane@example.com',
  status: 'active',
);

const _bob = EmployeeRecord(
  id: 'e2',
  name: 'Bob Smith',
  email: 'bob@example.com',
  status: 'active',
);

const _disabledJane = EmployeeRecord(
  id: 'e1',
  name: 'Jane Doe',
  email: 'jane@example.com',
  status: 'disabled',
);

const _activeJane = EmployeeRecord(
  id: 'e1',
  name: 'Jane Doe',
  email: 'jane@example.com',
  status: 'active',
);

Widget _wrap({
  required Stream<List<EmployeeRecord>> Function() employees,
  Stream<List<EmployeeRecord>> Function()? allUsers,
  List<Override> overrides = const [],
}) {
  // Overrides both allUsersStreamProvider and employeesStreamProvider — each
  // employees() call must return a fresh stream since the two subscribe independently.
  // [allUsers] splits them where the distinction is the point (watchEmployees
  // filters to active; watchAllUsers does not).
  return ProviderScope(
    overrides: [
      employeesStreamProvider.overrideWith((_) => employees()),
      allUsersStreamProvider.overrideWith((_) => (allUsers ?? employees)()),
      ...overrides,
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: const AddEmployeePage(isAdmin: true, employeeId: 'admin'),
      ),
    ),
  );
}

/// Broadcast users stream with an `emit` helper; `make` replays the latest
/// value on subscription so a late subscriber doesn't miss the seed.
typedef _SeededUsers = ({
  Stream<List<EmployeeRecord>> Function() make,
  void Function(List<EmployeeRecord>) emit,
  StreamController<List<EmployeeRecord>> controller,
});

_SeededUsers _seededUsers(List<EmployeeRecord> initial) {
  final controller = StreamController<List<EmployeeRecord>>.broadcast();
  var current = initial;
  Stream<List<EmployeeRecord>> make() async* {
    yield current;
    yield* controller.stream;
  }

  void emit(List<EmployeeRecord> next) {
    current = next;
    controller.add(next);
  }

  return (make: make, emit: emit, controller: controller);
}

/// Forces the wide viewport the master-detail split needs to render its detail
/// pane (>= Breakpoints.tablet), resetting after the test.
void _useWideViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() => registerFallbackValue(const EmployeeRecord(id: 'fallback')));

  testWidgets('renders employee cards from the stream', (tester) async {
    await tester.pumpWidget(
      _wrap(employees: () => Stream.value(const [_jane, _bob])),
    );
    await tester.pumpAndSettle();

    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.text('Bob Smith'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a test account leaves the main list for a collapsed section', (
    tester,
  ) async {
    const testAccount = EmployeeRecord(
      id: 't1',
      name: 'Apple Tester',
      email: 'tester@example.com',
      status: 'active',
      isTestAccount: true,
    );
    await tester.pumpWidget(
      _wrap(employees: () => Stream.value(const [_jane, testAccount])),
    );
    await tester.pumpAndSettle();

    expect(find.text('Apple Tester'), findsNothing);
  });

  testWidgets('expanding the test accounts section reaches the account', (
    tester,
  ) async {
    const testAccount = EmployeeRecord(
      id: 't1',
      name: 'Apple Tester',
      email: 'tester@example.com',
      status: 'active',
      isTestAccount: true,
    );
    await tester.pumpWidget(
      _wrap(employees: () => Stream.value(const [_jane, testAccount])),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('1 TEST ACCOUNT'));
    await tester.pumpAndSettle();

    expect(find.text('Apple Tester'), findsOneWidget);
  });

  testWidgets('shows empty-state copy when the list is empty', (tester) async {
    await tester.pumpWidget(_wrap(employees: () => Stream.value(const [])));
    await tester.pumpAndSettle();

    expect(find.textContaining('No employees'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows error copy when the stream errors', (tester) async {
    await tester.pumpWidget(
      _wrap(employees: () => Stream.error(StateError('boom'))),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('rror'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invite FAB stays disabled until the roster stream settles', (
    tester,
  ) async {
    final controller = StreamController<List<EmployeeRecord>>();
    addTearDown(controller.close);

    await tester.pumpWidget(_wrap(employees: () => controller.stream));
    await tester.pump();

    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.onPressed, isNull);
  });

  testWidgets(
    'split-layout detail pane reflects an external re-enable of the selected '
    'employee instead of showing the stale disabled snapshot',
    (tester) async {
      _useWideViewport(tester);
      final users = _seededUsers(const [_disabledJane]);
      addTearDown(users.controller.close);

      await tester.pumpWidget(_wrap(employees: users.make));
      await tester.pumpAndSettle();

      // Open the disabled employee in the split-layout detail pane. The pane's
      // status chip is what reflects the record now that Disable/Enable has
      // moved to the edit sheet — and it reads the rendered record directly,
      // which is a tighter check on the stale snapshot than a button label.
      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(EmployeeProfileCard),
          matching: find.text('Disabled'),
        ),
        findsOneWidget,
      );

      // Another admin re-enables her elsewhere; the live stream emits active.
      users.emit(const [_activeJane]);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(EmployeeProfileCard),
          matching: find.text('Active'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(EmployeeProfileCard),
          matching: find.text('Disabled'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile detail sheet reflects a live status change instead of keeping the '
    'stale opening snapshot',
    (tester) async {
      final users = _seededUsers(const [_disabledJane]);
      addTearDown(users.controller.close);

      await tester.pumpWidget(_wrap(employees: users.make));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeProfileCard), findsOneWidget);

      // Scoped to the sheet's own card: the list row behind it carries a
      // status chip too, so an unscoped finder matches both.
      Finder statusInSheet(String label) => find.descendant(
        of: find.byType(EmployeeProfileCard),
        matching: find.text(label),
      );
      expect(statusInSheet('Disabled'), findsOneWidget);

      users.emit(const [_activeJane]);
      await tester.pumpAndSettle();

      expect(statusInSheet('Active'), findsOneWidget);
      expect(statusInSheet('Disabled'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'split-layout detail pane clears when the selected employee vanishes '
    'from the live stream (deleted elsewhere), leaving no ghost actions',
    (tester) async {
      _useWideViewport(tester);
      final users = _seededUsers(const [_disabledJane]);
      addTearDown(users.controller.close);

      await tester.pumpWidget(_wrap(employees: users.make));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeProfileCard), findsOneWidget);

      // The employee is deleted (e.g. by another admin) — the live list drops
      // them entirely.
      users.emit(const []);
      await tester.pumpAndSettle();

      // No ghost detail pane still offering actions against a gone record.
      expect(find.byType(EmployeeProfileCard), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile detail sheet closes when the employee vanishes from the live stream',
    (tester) async {
      final users = _seededUsers(const [_disabledJane]);
      addTearDown(users.controller.close);

      await tester.pumpWidget(_wrap(employees: users.make));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeProfileCard), findsOneWidget);

      users.emit(const []);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(EmployeeProfileCard), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets("a disabled employee's colour is offered as taken", (
    tester,
  ) async {
    // Tall viewport so the whole invite sheet is built: the colour grid sits
    // below the fold of its lazy ListView at the default 800x600, and the
    // sheet's inner list does not scroll under tester.drag.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // crewPalette[1], not [0]: the add sheet seeds [0] as the selection, and
    // EmployeeColorGrid always keeps the selected swatch visible.
    final takenColor = AppColors.crewPalette[1];
    final disabled = EmployeeRecord(
      id: 'e9',
      name: 'Old Tech',
      status: 'disabled',
      color: takenColor,
    );

    await tester.pumpWidget(
      _wrap(
        // watchEmployees filters to active, so this is empty — which is
        // exactly the bug: the old code read this provider.
        employees: () => Stream.value(const <EmployeeRecord>[]),
        allUsers: () => Stream.value([disabled]),
        overrides: [
          employeesRepositoryProvider.overrideWithValue(_MockEmployeesRepo()),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // The grid must actually be built for the absence check below to mean
    // anything — an unbuilt grid would pass it for the wrong reason. It sits
    // past the fold of the sheet's lazy ListView at the default viewport, so
    // this asserts it is present before asserting what it contains.
    expect(find.byType(EmployeeColorGrid), findsOneWidget);

    // EmployeeColorGrid HIDES taken colours, so the assertion is an absence.
    expect(find.byKey(ValueKey(takenColor.toARGB32())), findsNothing);
    // The palette is otherwise intact — this isn't an empty-grid false pass.
    expect(
      find.byKey(ValueKey(AppColors.crewPalette[2].toARGB32())),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an invited row renders the pending-invite tile and expands in place '
    'instead of opening the detail sheet',
    (tester) async {
      _useWideViewport(tester);
      const invited = EmployeeRecord(
        id: 'inv1',
        name: 'Zoe Roy',
        email: 'zoe@example.com',
        status: 'invited',
      );

      // Expanding the row re-issues, so the callable has to answer.
      final repo = _MockEmployeesRepo();
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

      await tester.pumpWidget(
        _wrap(
          employees: () => Stream.value(const [_jane, invited]),
          overrides: [employeesRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PendingInviteTile), findsOneWidget);
      expect(find.byType(EmployeeCard), findsOneWidget);

      await tester.tap(find.text('Zoe Roy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // In-place expansion, and no detail pane claimed the row.
      expect(find.text('SIGN-IN DETAILS'), findsOneWidget);
      expect(find.byType(EmployeeProfileCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile detail sheet opens edit with the latest live employee snapshot',
    (tester) async {
      final repo = _MockEmployeesRepo();
      when(
        () => repo.watchEmergencyContact(any()),
      ).thenAnswer((_) => Stream.value(EmergencyContact.empty));
      when(
        () => repo.updateEmployee(
          docId: any(named: 'docId'),
          employee: any(named: 'employee'),
        ),
      ).thenAnswer((_) async {});

      const staleJane = EmployeeRecord(
        id: 'e1',
        name: 'Jane Doe',
        email: 'old@example.com',
        status: 'active',
      );
      const freshJane = EmployeeRecord(
        id: 'e1',
        name: 'Jane Doe',
        email: 'new@example.com',
        status: 'active',
      );
      final users = _seededUsers(const [staleJane]);
      addTearDown(users.controller.close);

      await tester.pumpWidget(
        _wrap(
          employees: users.make,
          overrides: [
            employeesRepositoryProvider.overrideWithValue(repo),
            futureAssignmentCountProvider('e1').overrideWith((_) async => 0),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Jane Doe'));
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeProfileCard), findsOneWidget);
      expect(find.text('old@example.com'), findsWidgets);

      users.emit(const [freshJane]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();

      final emailField = find.descendant(
        of: find.byKey(const Key('email')),
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(emailField).controller.text,
        'new@example.com',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
