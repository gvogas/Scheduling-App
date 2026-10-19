import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/event_details_controller.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
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

const _employeeA = EmployeeRecord(id: 'e1', name: 'Alex');

const _existingClient = ClientRecord(
  id: 'c1',
  name: 'Jane Doe',
  phone: '555-0001',
  address: '1 First St',
);

/// Day 3 of a 5-day run. Its own window is ONE day, which is exactly why the
/// widget-layer `isMultiDay` flag cannot recognise it.
final _runDay = AppointmentRecord(
  id: 'day-3',
  title: 'Repipe',
  startTime: DateTime(2026, 8, 5, 9),
  endTime: DateTime(2026, 8, 5, 17),
  clientId: 'c1',
  clientName: 'Jane Doe',
  clientPhone: '555-0001',
  address: '1 First St',
  employeeIds: const ['e1'],
  employeeNames: const ['Alex'],
  seriesId: 'day-1',
  dayIndex: 3,
  dayCount: 5,
  // A stored repeat that predates the picker gate.
  repeat: RepeatInterval.fourMonths,
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
    registerFallbackValue(<AppointmentImage>[]);
    registerFallbackValue(<AppointmentRecord>[]);
    registerFallbackValue(<String>[]);
  });

  late _MockAppointmentsRepo appointments;
  late ProviderContainer container;

  setUp(() {
    appointments = _MockAppointmentsRepo();
    final clients = _MockClientsRepo();
    final employees = _MockEmployeesRepo();

    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => clients.getClientById(any()),
    ).thenAnswer((_) async => _existingClient);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const [_employeeA]));
    when(
      () => appointments.updateAppointment(any(), base: any(named: 'base')),
    ).thenAnswer((_) async {});
    when(
      () => appointments.fetchAppointmentPictures(any()),
    ).thenAnswer((_) async => const <AppointmentImage>[]);
    when(
      () => appointments.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).thenAnswer((_) async => const <EmployeeRecord>[]);

    container =
        ProviderContainer(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            employeesRepositoryProvider.overrideWithValue(employees),
            appointmentImageUploadProvider.overrideWithValue(_MockUploader()),
            isOfflineProvider.overrideWithValue(false),
          ],
        )..listen(
          eventDetailsControllerProvider(EventDetailsKey(_runDay)),
          (_, _) {},
        );
    addTearDown(container.dispose);
  });

  EventDetailsController readNotifier() => container.read(
    eventDetailsControllerProvider(EventDetailsKey(_runDay)).notifier,
  );

  Future<void> waitForSeed() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  // The critical guard. A run member's `seriesId` names the RUN, so letting a
  // repeat change reach `rewriteSeries` deletes the run's trailing days and
  // cascade-deletes their photos — with no scope dialog and no confirmation.
  group('a run member never rewrites its series', () {
    test('changing the repeat does NOT read or rewrite the series', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..selectRepeat(RepeatInterval.sixMonths);

      final outcome = await c.save(
        _runDay,
        title: 'Repipe',
        address: '1 First St',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsSaved>());
      // The run's trailing days must be untouched.
      verifyNever(() => appointments.getSeries(any()));
      verifyNever(
        () => appointments.rewriteSeries(
          updated: any(named: 'updated'),
          deleteIds: any(named: 'deleteIds'),
          copies: any(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      );
      // It saves as a plain single-document update instead.
      verify(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).called(1);
    });

    test('clearing the repeat is also refused a rewrite', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..selectRepeat(RepeatInterval.none);

      await c.save(
        _runDay,
        title: 'Repipe',
        address: '1 First St',
        notes: '',
        materialsNeeded: '',
      );

      verifyNever(
        () => appointments.rewriteSeries(
          updated: any(named: 'updated'),
          deleteIds: any(named: 'deleteIds'),
          copies: any(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      );
    });

    test('the run label survives the save', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..selectRepeat(RepeatInterval.sixMonths);

      await c.save(
        _runDay,
        title: 'Repipe',
        address: '1 First St',
        notes: '',
        materialsNeeded: '',
      );

      final written =
          verify(
                () => appointments.updateAppointment(
                  captureAny(),
                  base: any(named: 'base'),
                ),
              ).captured.single
              as AppointmentRecord;
      expect(written.dayIndex, 3);
      expect(written.dayCount, 5);
      expect(written.isRunMember, isTrue);
    });
  });

  test('isRunMember is dayCount > 1', () {
    expect(_runDay.isRunMember, isTrue);
    expect(
      AppointmentRecord(
        startTime: DateTime(2026),
        endTime: DateTime(2026),
      ).isRunMember,
      isFalse,
    );
  });
}
