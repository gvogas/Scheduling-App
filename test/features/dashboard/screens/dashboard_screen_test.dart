import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/dashboard/application/dashboard_providers.dart';
import 'package:scheduling/features/dashboard/screens/dashboard_screen.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

/// Fixed clock: Wednesday 2026-07-08, noon.
final _now = DateTime(2026, 7, 8, 12);

const _jane = EmployeeRecord(
  id: 'e1',
  name: 'Jane Doe',
  email: 'jane@example.com',
  status: 'active',
);

AppointmentRecord _appt({
  required String id,
  required DateTime start,
  String status = 'pending',
  List<String> employeeIds = const ['e1'],
}) => AppointmentRecord(
  id: id,
  title: 'Job $id',
  startTime: start,
  endTime: start.add(const Duration(hours: 1)),
  status: status,
  employeeIds: employeeIds,
);

Widget _wrap({
  required List<AppointmentRecord> appointments,
  required ClientsRepository clientsRepo,
  Object? appointmentsError,
  Stream<List<AppointmentRecord>> Function()? appointmentsStream,
  List<EmployeeRecord> users = const [_jane],
}) {
  return ProviderScope(
    // Production disables Riverpod's automatic retry; Retry must do the work.
    retry: (_, _) => null,
    overrides: [
      dashboardClockProvider.overrideWithValue(() => _now),
      appointmentsInRangeProvider.overrideWith(
        (_, _) => appointmentsStream != null
            ? appointmentsStream()
            : appointmentsError != null
            ? Stream<List<AppointmentRecord>>.error(appointmentsError)
            : Stream.value(appointments),
      ),
      // The settled weeks are a one-shot read, not part of the live stream —
      // these tests supply everything through the live half.
      dashboardHistoryProvider.overrideWith(
        (_) async => const <AppointmentRecord>[],
      ),
      // Fresh stream per provider: Stream.value is single-subscription.
      employeesStreamProvider.overrideWith((_) => Stream.value(const [_jane])),
      allUsersStreamProvider.overrideWith((_) => Stream.value(users)),
      clientsRepositoryProvider.overrideWithValue(clientsRepo),
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
        home: const DashboardScreen(isAdmin: true, employeeId: 'admin1'),
      ),
    ),
  );
}

void main() {
  late _MockClientsRepo clientsRepo;

  setUpAll(() {
    registerFallbackValue(DateTime(2026));
  });

  setUp(() {
    clientsRepo = _MockClientsRepo();
    when(() => clientsRepo.fetchClientsCreatedSince(any())).thenAnswer(
      (_) async => [
        ClientRecord.fromMap('c1', {
          'name': 'Alice',
          'createdAt': DateTime(2026, 7, 7),
        }),
      ],
    );
  });

  Future<void> withPhoneViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412 * 3, 915 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('renders the hero, all section headers, and a workload row', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: [
          // Upcoming today AND pending-within-48h.
          _appt(id: 'up', start: DateTime(2026, 7, 8, 14)),
          // Ended yesterday, never closed.
          _appt(
            id: 'overdue',
            start: DateTime(2026, 7, 7, 9),
            status: 'in_progress',
          ),
        ],
        clientsRepo: clientsRepo,
      ),
    );
    await tester.pumpAndSettle();

    // Hero label lives in a Text.rich span; singular because only one visit is today.
    expect(
      find.textContaining('visit today', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('NEXT UP TODAY'), findsOneWidget);
    expect(find.text('EMPLOYEE WORKLOAD'), findsOneWidget);
    expect(find.text('BUSINESS TRENDS'), findsOneWidget);
    expect(find.text('NEEDS ATTENTION'), findsOneWidget);
    expect(find.text('Jane Doe'), findsWidgets);
    expect(find.text('1 pending visit starts within 48 hours'), findsOneWidget);
    expect(find.text('1 past visit was never closed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the unassigned pill for an unassigned visit today', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: [
          _appt(
            id: 'open',
            start: DateTime(2026, 7, 8, 15),
            employeeIds: const [],
          ),
        ],
        clientsRepo: clientsRepo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 unassigned job today'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty data shows all-clear and no-visits states', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    when(
      () => clientsRepo.fetchClientsCreatedSince(any()),
    ).thenAnswer((_) async => const []);
    await tester.pumpWidget(
      _wrap(appointments: const [], clientsRepo: clientsRepo),
    );
    await tester.pumpAndSettle();

    expect(find.text('No upcoming visits today'), findsOneWidget);
    expect(find.text('All clear — nothing needs attention'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an account never set up is flagged even with no createdAt', (
    tester,
  ) async {
    // `createdAt` is function-owned and absent on legacy docs, so "unknown
    // age" must not become "not shown" — the person is still holding the
    // shared starting password either way.
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: const [],
        clientsRepo: clientsRepo,
        users: const [
          _jane,
          EmployeeRecord(
            id: 'e2',
            name: 'Sam Pending',
            email: 'sam@example.com',
            status: 'invited',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 account was never set up'), findsOneWidget);
    expect(find.text('Sam Pending'), findsOneWidget);
    // The section is no longer all-clear just because the jobs are.
    expect(find.text('All clear — nothing needs attention'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active roster alone stays all clear', (tester) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(appointments: const [], clientsRepo: clientsRepo),
    );
    await tester.pumpAndSettle();

    expect(find.text('All clear — nothing needs attention'), findsOneWidget);
  });

  testWidgets('an archived client is neither counted nor listed', (
    tester,
  ) async {
    // Behaviour change, owner call 2026-08-10: the dashboard answers "what
    // should I look at now", and an archived client is one you decided not to
    // look at. `fetchClientsCreatedSince` has no archived filter, so this can
    // only be excluded in Dart.
    when(() => clientsRepo.fetchClientsCreatedSince(any())).thenAnswer(
      (_) async => [
        ClientRecord.fromMap('c1', {
          'name': 'Alice',
          'createdAt': DateTime(2026, 7, 7),
        }),
        ClientRecord.fromMap('c2', {
          'name': 'Bob',
          'createdAt': DateTime(2026, 7, 7),
          'archived': true,
        }),
      ],
    );
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(appointments: const [], clientsRepo: clientsRepo),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    // The card leads with the figure and captions the window under it. Keyed,
    // because bare numbers also appear on the KPI tiles and on this card's own
    // trend chip.
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('new-clients-total'))).data,
      '1',
    );
    expect(find.text('In the last 8 weeks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching the period re-counts the KPI tiles', (tester) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: [
          // Today.
          _appt(id: 'today', start: DateTime(2026, 7, 8, 14)),
          // Monday of the same ISO week — in Week and Month, not in Today.
          _appt(id: 'mon', start: DateTime(2026, 7, 6, 9)),
          // Earlier in July — only in Month.
          _appt(id: 'early', start: DateTime(2026, 7, 2, 9)),
        ],
        clientsRepo: clientsRepo,
      ),
    );
    await tester.pumpAndSettle();

    Finder bookedValue() => find.descendant(
      of: find
          .ancestor(of: find.text('Booked'), matching: find.byType(Column))
          .first,
      matching: find.byType(Text),
    );
    String booked() => tester.widget<Text>(bookedValue().first).data!;

    expect(booked(), '1');

    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    expect(booked(), '2');

    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    expect(booked(), '3');

    expect(tester.takeException(), isNull);
  });

  testWidgets('stream error renders the error body without throwing', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    await tester.pumpWidget(
      _wrap(
        appointments: const [],
        clientsRepo: clientsRepo,
        appointmentsError: Exception('boom'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load the dashboard"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Retry re-subscribes the errored source, not the combiner', (
    tester,
  ) async {
    await withPhoneViewport(tester);
    var subscriptions = 0;
    await tester.pumpWidget(
      _wrap(
        appointments: const [],
        clientsRepo: clientsRepo,
        appointmentsStream: () => subscriptions++ == 0
            ? Stream<List<AppointmentRecord>>.error(Exception('boom'))
            : Stream.value(const <AppointmentRecord>[]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load the dashboard"), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(subscriptions, 2);
    expect(find.text("Couldn't load the dashboard"), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
