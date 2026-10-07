import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/views/event_details_view.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../support/tour_test_support.dart';

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

class _MockClientsRepo extends Mock implements ClientsRepository {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

const _client = ClientRecord(
  id: 'c1',
  name: 'Existing Client',
  phone: '555-1111',
  address: '1 First St',
);

const _employeeA = EmployeeRecord(id: 'e1', name: 'Alex');

final _appointment = AppointmentRecord(
  id: 'appt-1',
  title: 'Leak fix',
  startTime: DateTime(2026, 5, 10, 9),
  endTime: DateTime(2026, 5, 10, 10),
  clientId: 'c1',
  clientName: 'Existing Client',
  clientPhone: '555-1111',
  address: '1 First St',
  employeeIds: const ['e1'],
  employeeNames: const ['Alex'],
  status: 'booked',
);

void main() {
  setUpAll(() {
    registerFallbackValue(
      AppointmentRecord(
        id: '_',
        startTime: DateTime(2026),
        endTime: DateTime(2026),
      ),
    );
  });

  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late PhotoUploadNotifier uploadNotifier;

  setUp(() {
    // The details sheet carries a tour now; without this its showcase
    // animation repeats forever and pumpAndSettle times out.
    markFormToursSeen();
    appointments = _MockAppointmentsRepo();
    clients = _MockClientsRepo();
    employees = _MockEmployeesRepo();
    uploadNotifier = PhotoUploadNotifier();

    when(() => clients.getClientById(any())).thenAnswer((_) async => _client);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const [_employeeA]));
    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(() => appointments.updateAppointment(any())).thenAnswer((_) async {});
    // The edit flow now runs a conflict check before writing; no clash here.
    when(
      () => appointments.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).thenAnswer((_) async => const <EmployeeRecord>[]);
  });

  // Tall viewport so the whole lazily-built edit form lays out without scrolling.
  Future<void> pumpDetails(
    WidgetTester tester, {
    void Function(Object? result)? onClose,
    AppointmentRecord? appointment,
  }) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(clients),
          employeesRepositoryProvider.overrideWithValue(employees),
          photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
        ],
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            // Explicit: showActions defaults CLOSED, and these cases exercise
            // the admin-only Edit affordance.
            body: EventDetailsView(
              appointment: appointment ?? _appointment,
              analyticsSource: AnalyticsSources.calendar,
              showActions: true,
              onClose: onClose,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('view mode shows details with no editable text fields', (
    tester,
  ) async {
    await pumpDetails(tester);

    expect(find.text('Leak fix'), findsOneWidget);
    // View mode never builds the edit controllers/fields.
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Edit builds the edit form prefilled from the '
      'appointment', (tester) async {
    await pumpDetails(tester);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // The lazily-created title controller is seeded from the appointment.
    expect(find.widgetWithText(TextField, 'Leak fix'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing the title and saving writes the updated appointment', (
    tester,
  ) async {
    Object? closeResult;
    var closed = false;
    await pumpDetails(
      tester,
      onClose: (result) {
        closed = true;
        closeResult = result;
      },
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Leak fix'),
      'Updated title',
    );
    // Let SheetFocusScroll's 280 ms focus-scroll timer fire.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final saved =
        verify(
              () => appointments.updateAppointment(captureAny()),
            ).captured.single
            as AppointmentRecord;
    expect(saved.title, 'Updated title');
    expect(closed, isTrue);
    expect(closeResult, isA<AppointmentRecord>());
    expect(tester.takeException(), isNull);
  });

  AppointmentRecord spanning(DateTime start, DateTime end) => AppointmentRecord(
    id: 'appt-span',
    title: 'Repipe',
    startTime: start,
    endTime: end,
    clientId: 'c1',
    clientName: 'Existing Client',
    clientPhone: '555-1111',
    address: '1 First St',
    employeeIds: const ['e1'],
    employeeNames: const ['Alex'],
  );

  Future<void> openEditForm(
    WidgetTester tester, {
    AppointmentRecord? appointment,
  }) async {
    await pumpDetails(tester, appointment: appointment);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
  }

  testWidgets('a multi-day record shows its end date and daily-window time '
      'labels', (tester) async {
    await openEditForm(
      tester,
      appointment: spanning(DateTime(2026, 8, 1, 9), DateTime(2026, 8, 3, 17)),
    );

    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 8, 3))),
      findsOneWidget,
    );
    expect(find.text('3 days'), findsOneWidget);
    expect(find.text('Start time · each day'), findsOneWidget);
    expect(find.text('End time · each day'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overnight record ends on the last night the crew starts, '
      'not the morning it finishes', (tester) async {
    await openEditForm(
      tester,
      appointment: spanning(DateTime(2026, 8, 1, 22), DateTime(2026, 8, 4, 6)),
    );

    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 8, 3))),
      findsOneWidget,
    );
    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 8, 4))),
      findsNothing,
    );
    expect(find.text('3 nights'), findsOneWidget);
    expect(find.text('Start time · each night'), findsOneWidget);
    expect(find.text('End time · next morning'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('moving the start date shifts the displayed end date and keeps '
      'the run length', (tester) async {
    await openEditForm(
      tester,
      appointment: spanning(DateTime(2026, 8, 1, 9), DateTime(2026, 8, 3, 17)),
    );

    // The row drops the month down beneath itself rather than opening a modal
    // picker, so the day is one tap inside the form.
    await tester.tap(find.text('Start date'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inline-date-day-2026-08-05')));
    await tester.pumpAndSettle();

    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 8, 5))),
      findsOneWidget,
    );
    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 8, 7))),
      findsOneWidget,
    );
    expect(find.text('3 days'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single-day record shows plain time labels and no run length', (
    tester,
  ) async {
    await openEditForm(tester);

    // ONE date row, not two: editing may not widen a one-day client job into a
    // multi-day one, because only the ADD path splits a span into per-day
    // documents — so the end-date row is withheld here for the same reason it
    // is withheld on a run member. This asserted two rows until 2026-08-28,
    // when offering the second one still wrote a wide document.
    expect(
      find.text(DateUtilsHelper.formatDate(DateTime(2026, 5, 10))),
      findsOneWidget,
    );
    expect(find.text('End date'), findsNothing);
    expect(find.textContaining(RegExp(r'\d+ (days|nights)')), findsNothing);
    expect(find.text('Start time'), findsOneWidget);
    expect(find.text('End time'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
