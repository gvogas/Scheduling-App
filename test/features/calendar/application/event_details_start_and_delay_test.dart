import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/images_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

class _MockClientsRepo extends Mock implements ClientsRepository {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockUploader extends Mock implements AppointmentImageUploadService {}

class _MockStorage extends Mock implements ImageStorageService {}

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
  employeeIds: const ['e1'],
  employeeNames: const ['Alex'],
  // A legacy status, so the normalization on write is observable.
  status: 'booked',
);

/// The two detail-sheet actions added 2026-09-01: "Start job" and the admin's
/// "Push back".
void main() {
  setUpAll(() {
    registerFallbackValue(
      AppointmentRecord(
        id: '_',
        startTime: DateTime(2026),
        endTime: DateTime(2026),
      ),
    );
    registerFallbackValue(<EmployeeRecord>[]);
  });

  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;

  ProviderContainer makeContainer({bool offline = false}) {
    final container =
        ProviderContainer(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            employeesRepositoryProvider.overrideWithValue(employees),
            appointmentImageUploadProvider.overrideWithValue(_MockUploader()),
            imageStorageProvider.overrideWithValue(_MockStorage()),
            isOfflineProvider.overrideWithValue(offline),
          ],
        )..listen(
          eventDetailsControllerProvider(EventDetailsKey(_appointment)),
          (_, _) {},
        );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    appointments = _MockAppointmentsRepo();
    clients = _MockClientsRepo();
    employees = _MockEmployeesRepo();
    when(() => clients.getClientById(any())).thenAnswer((_) async => _client);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const [_employeeA]));
    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => appointments.updateAppointment(any(), base: any(named: 'base')),
    ).thenAnswer((_) async {});
    when(
      () => appointments.updateAppointmentStatus(
        id: any(named: 'id'),
        status: any(named: 'status'),
      ),
    ).thenAnswer((_) async {});
    // The single-booking check excludes the job's own id, which routes through
    // `findBusyEmployees`; no clash by default.
    when(
      () => appointments.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).thenAnswer((_) async => const <EmployeeRecord>[]);
  });

  EventDetailsController notifierOf(ProviderContainer c) => c.read(
    eventDetailsControllerProvider(EventDetailsKey(_appointment)).notifier,
  );

  EventDetailsState stateOf(ProviderContainer c) =>
      c.read(eventDetailsControllerProvider(EventDetailsKey(_appointment)));

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('startJob', () {
    test('writes in_progress through the two-key status path', () async {
      final c = makeContainer();
      final outcome = await notifierOf(c).startJob(_appointment);

      expect(outcome, isA<EventDetailsActionOk>());
      verify(
        () => appointments.updateAppointmentStatus(
          id: 'appt-1',
          status: 'in_progress',
        ),
      ).called(1);
    });

    test('is refused offline rather than spinning until reconnect', () async {
      final c = makeContainer(offline: true);
      final outcome = await notifierOf(c).startJob(_appointment);

      expect(outcome, isA<EventDetailsActionFailed>());
      expect(
        (outcome as EventDetailsActionFailed).error,
        isA<SocketException>(),
      );
      verifyNever(
        () => appointments.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      );
    });
  });

  group('delayAppointment', () {
    test('shifts both instants by the offset and keeps the length', () async {
      final c = makeContainer();
      await settle();
      final outcome = await notifierOf(
        c,
      ).delayAppointment(_appointment, minutes: 30);

      expect(outcome, isA<EventDetailsSaved>());
      final written =
          verify(
                () => appointments.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                ),
              ).captured.single
              as AppointmentRecord;
      expect(written.startTime, DateTime(2026, 5, 10, 9, 30));
      expect(written.endTime, DateTime(2026, 5, 10, 10, 30));
      expect(written.id, 'appt-1');
    });

    test('normalizes a legacy status so the rules accept the write', () async {
      final c = makeContainer();
      await settle();
      await notifierOf(c).delayAppointment(_appointment, minutes: 15);

      final written =
          verify(
                () => appointments.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                ),
              ).captured.single
              as AppointmentRecord;
      expect(written.status, 'pending');
    });

    test('a clash returns the busy outcome and clears isSaving', () async {
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      ).thenAnswer((_) async => const [_employeeA]);
      final c = makeContainer();
      await settle();

      final outcome = await notifierOf(
        c,
      ).delayAppointment(_appointment, minutes: 30);

      expect(outcome, isA<EventDetailsBusyEmployees>());
      expect(stateOf(c).isSaving, isFalse);
      verifyNever(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      );
    });

    test('forceBusy skips the clash check and writes', () async {
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      ).thenThrow(StateError('must not be consulted'));
      final c = makeContainer();
      await settle();

      final outcome = await notifierOf(
        c,
      ).delayAppointment(_appointment, minutes: 60, forceBusy: true);

      expect(outcome, isA<EventDetailsSaved>());
      verify(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).called(1);
    });

    test('a second tap while saving is Busy, not a second write', () async {
      final c = makeContainer();
      await settle();
      notifierOf(c).setSaving(busy: true);

      final outcome = await notifierOf(
        c,
      ).delayAppointment(_appointment, minutes: 15);

      expect(outcome, isA<EventDetailsSaveBusy>());
      verifyNever(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      );
    });

    test('is refused offline before the flag is set', () async {
      final c = makeContainer(offline: true);
      await settle();

      final outcome = await notifierOf(
        c,
      ).delayAppointment(_appointment, minutes: 15);

      expect(outcome, isA<EventDetailsFailed>());
      expect((outcome as EventDetailsFailed).error, isA<SocketException>());
      expect(stateOf(c).isSaving, isFalse);
    });
  });
}
