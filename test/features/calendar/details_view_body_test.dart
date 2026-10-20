import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/views/details_action_bar.dart';
import 'package:scheduling/features/calendar/widgets/views/details_view_body.dart';
import 'package:scheduling/features/calendar/widgets/views/details_view_leaf_widgets.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

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

final _appointmentWithNotes = AppointmentRecord(
  id: 'appt-2',
  title: 'Leak fix',
  startTime: DateTime(2026, 5, 10, 9),
  endTime: DateTime(2026, 5, 10, 10),
  clientId: 'c1',
  clientName: 'Existing Client',
  clientPhone: '555-1111',
  address: '1 First St',
  employeeIds: const ['e1'],
  employeeNames: const ['Alex'],
  notes: 'Gate code 4821',
  status: 'booked',
);

final _dayOff = AppointmentRecord(
  id: 'appt-off',
  title: 'Vacation',
  startTime: DateTime(2026, 5, 10),
  endTime: DateTime(2026, 5, 12, 23, 59),
  address: '1 First St',
  materialsNeeded: 'copper pipe',
  employeeIds: const ['e1'],
  employeeNames: const ['Alex'],
  notes: 'Back on the Monday.',
  isPersonal: true,
  isDayOff: true,
);

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

List<Override> _overrides(
  AppointmentsRepository appointments,
  ClientsRepository clients,
  EmployeesRepository employees,
  PhotoUploadNotifier uploadNotifier,
) => [
  appointmentsRepositoryProvider.overrideWithValue(appointments),
  clientsRepositoryProvider.overrideWithValue(clients),
  employeesRepositoryProvider.overrideWithValue(employees),
  photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
];

void main() {
  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late PhotoUploadNotifier uploadNotifier;

  setUp(() {
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
  });

  testWidgets(
    'photo-failure banner appears when notifier reports a failure for this id',
    (tester) async {
      uploadNotifier.reportFailure('appt-1', failedCount: 2);

      await tester.pumpWidget(
        _wrap(
          DetailsViewBody(
            appointment: _appointment,
            showActions: true,
            onClose: () {},
          ),
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            employeesRepositoryProvider.overrideWithValue(employees),
            photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('failed to upload'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the Edit chip clears the 48 px tap floor at its painted size', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          appointment: _appointment,
          showActions: true,
          onClose: () {},
        ),
        overrides: _overrides(appointments, clients, employees, uploadNotifier),
      ),
    );
    await tester.pumpAndSettle();

    // The hit box is the InkWell; the painted chip inside it stays ~26 px.
    final chip = find.byType(DetailsEditChip);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    expect(
      tester
          .getSize(
            find.descendant(of: chip, matching: find.byType(Container)).first,
          )
          .height,
      lessThan(40),
    );
  });

  testWidgets('shows the client phone number and address', (tester) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          appointment: _appointment,
          showActions: true,
          onClose: () {},
        ),
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(clients),
          employeesRepositoryProvider.overrideWithValue(employees),
          photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Existing Client'), findsOneWidget);
    expect(find.text('555-1111'), findsOneWidget);
    expect(find.text('1 First St'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'no failure banner when notifier reports a failure for a different id',
    (tester) async {
      uploadNotifier.reportFailure('some-other-appt', failedCount: 5);

      await tester.pumpWidget(
        _wrap(
          DetailsViewBody(
            appointment: _appointment,
            showActions: true,
            onClose: () {},
          ),
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            employeesRepositoryProvider.overrideWithValue(employees),
            photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('failed to upload'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renders the mono when-line in place of the icon rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          appointment: _appointment,
          showActions: true,
          onClose: () {},
        ),
        overrides: _overrides(appointments, clients, employees, uploadNotifier),
      ),
    );
    await tester.pumpAndSettle();

    // "SUN 10 MAY · 9:00 AM – 10:00 AM" — one mono line, middot and en-dash.
    expect(find.textContaining('MAY'), findsOneWidget);
    expect(find.textContaining(' · '), findsOneWidget);
    expect(find.textContaining('–'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('omits the notes row entirely when there are no notes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          appointment: _appointment,
          showActions: true,
          onClose: () {},
        ),
        overrides: _overrides(appointments, clients, employees, uploadNotifier),
      ),
    );
    await tester.pumpAndSettle();

    // Read-only bodies drop empty sections rather than showing a placeholder.
    expect(find.text('NOTES'), findsNothing);
  });

  testWidgets('shows the notes row inside the panel when notes exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          appointment: _appointmentWithNotes,
          showActions: true,
          onClose: () {},
        ),
        overrides: _overrides(appointments, clients, employees, uploadNotifier),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('NOTES'), findsOneWidget);
    expect(find.text('Gate code 4821'), findsOneWidget);
  });
  testWidgets('an untitled day off leads with the person, not "Personal"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          // What an unnamed personal block actually stores.
          appointment: _dayOff.copyWith(title: 'Personal'),
          showActions: true,
          onClose: () {},
        ),
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(clients),
          employeesRepositoryProvider.overrideWithValue(employees),
          photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('Personal'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a day off opens as its own body, not an appointment', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DetailsViewBody(
          appointment: _dayOff,
          showActions: true,
          onClose: () {},
        ),
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(clients),
          employeesRepositoryProvider.overrideWithValue(employees),
          photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Leads with the typed REASON, person underneath — the same hierarchy
    // the agenda strip shows, so tapping "Vacation" cannot open a screen
    // that has dropped the word.
    expect(find.text('Vacation'), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('3 days'), findsOneWidget);
    expect(find.text('Back on the Monday.'), findsOneWidget);

    // Nothing a day off does not have — even though the record still carries
    // a stale address and materials from before it was marked as one.
    expect(find.text('1 First St'), findsNothing);
    expect(find.text('copper pipe'), findsNothing);
    // No lifecycle: neither action is offered.
    expect(find.text('Mark as complete'), findsNothing);
    expect(find.text('Cancel appointment'), findsNothing);
    expect(find.byType(DetailsActionBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
