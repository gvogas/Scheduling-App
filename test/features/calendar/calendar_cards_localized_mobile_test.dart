import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/calendar/widgets/views/details_view_body.dart';
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
  name: 'Client de demonstration avec nom long',
  phone: '555-1111',
  address: '1 rue Principale',
  contacts: [
    ClientContact(
      name: 'Contact secondaire tres long',
      phone: '555-2222',
      email: 'contact.secondaire@example.com',
    ),
  ],
);

const _employee = EmployeeRecord(id: 'e1', name: 'Alexandrine Tremblay');

final _appointment = AppointmentRecord(
  id: 'appt-fr-1',
  title:
      'Installation de traitement capillaire avec description volontairement longue',
  startTime: DateTime(2026, 5, 10, 9),
  endTime: DateTime(2026, 5, 10, 10),
  clientId: 'c1',
  clientName: 'Client de demonstration avec nom long',
  clientPhone: '555-1111',
  address: '1 rue Principale',
  employeeIds: const ['e1'],
  employeeNames: const ['Alexandrine Tremblay'],
  status: 'in_progress',
);

Widget _materialWrap(Widget child) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('fr'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late PhotoUploadNotifier uploadNotifier;

  setUpAll(() async {
    await initializeDateFormatting('fr');
  });

  setUp(() {
    appointments = _MockAppointmentsRepo();
    clients = _MockClientsRepo();
    employees = _MockEmployeesRepo();
    uploadNotifier = PhotoUploadNotifier();
    when(() => clients.getClientById(any())).thenAnswer((_) async => _client);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const [_employee]));
    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
  });

  testWidgets(
    'appointment card does not overflow under French localized strings at 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _materialWrap(
            Padding(
              padding: const EdgeInsets.all(8),
              child: AppointmentCard(
                appointment: _appointment,
                crew: const [
                  AppointmentCrew(
                    name: 'Alexandrine Tremblay',
                    color: Color(0xFF6366F1),
                  ),
                  AppointmentCrew(
                    name: 'Jean-Sebastien Belanger',
                    color: Color(0xFF0E9B6E),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'appointment detail body does not overflow under French localized strings at 2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            employeesRepositoryProvider.overrideWithValue(employees),
            photoUploadNotifierProvider.overrideWithValue(uploadNotifier),
          ],
          child: MaterialApp(
            locale: const Locale('fr'),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child ?? const SizedBox.shrink(),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: DetailsViewBody(
                  appointment: _appointment,
                  showActions: true,
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}
