import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/images/image_storage_service.dart';
import 'package:scheduling/core/images/images_providers.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
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

class _MockStorage extends Mock implements ImageStorageService {}

const _existingClient = ClientRecord(
  id: 'c1',
  name: 'Existing Client',
  phone: '555-1111',
  address: '1 First St',
);

const _newClient = ClientRecord(
  id: 'c2',
  name: 'Different Client',
  phone: '555-2222',
  address: '2 Second St',
);

const _employeeA = EmployeeRecord(id: 'e1', name: 'Alex');
const _employeeB = EmployeeRecord(id: 'e2', name: 'Bea');

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
    registerFallbackValue(<AppointmentImage>[]);
    registerFallbackValue(<AppointmentRecord>[]);
    registerFallbackValue(<String>[]);
  });

  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late _MockUploader uploader;
  late _MockStorage storage;
  late ProviderContainer container;

  setUp(() {
    appointments = _MockAppointmentsRepo();
    clients = _MockClientsRepo();
    employees = _MockEmployeesRepo();
    uploader = _MockUploader();
    when(
      () => uploader.enqueuePhotos(
        appointmentId: any(named: 'appointmentId'),
        newImages: any(named: 'newImages'),
      ),
    ).thenAnswer((_) async {});
    storage = _MockStorage();

    when(
      () => clients.getClientById(any()),
    ).thenAnswer((_) async => _existingClient);
    when(
      employees.watchEmployees,
    ).thenAnswer((_) => Stream.value(const [_employeeA, _employeeB]));
    when(
      () => appointments.updateAppointment(any(), base: any(named: 'base')),
    ).thenAnswer((_) async {});
    when(
      () => appointments.updateAppointmentStatus(
        id: any(named: 'id'),
        status: any(named: 'status'),
      ),
    ).thenAnswer((_) async {});
    when(() => appointments.deleteAppointment(any())).thenAnswer((_) async {});
    when(() => storage.deleteImages(any())).thenAnswer((_) async {});
    when(
      () => appointments.onLocalWrite,
    ).thenAnswer((_) => const Stream.empty());
    // No clash by default; the conflict tests override this.
    when(
      () => appointments.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).thenAnswer((_) async => const <EmployeeRecord>[]);
    when(
      () => appointments.findClashingAppointments(
        employeeIds: any(named: 'employeeIds'),
        start: any(named: 'start'),
        end: any(named: 'end'),
      ),
    ).thenAnswer((_) async => const <AppointmentRecord>[]);

    container =
        ProviderContainer(
            overrides: [
              appointmentsRepositoryProvider.overrideWithValue(appointments),
              clientsRepositoryProvider.overrideWithValue(clients),
              employeesRepositoryProvider.overrideWithValue(employees),
              appointmentImageUploadProvider.overrideWithValue(uploader),
              imageStorageProvider.overrideWithValue(storage),
              // Deterministic online by default; the offline test builds its own.
              isOfflineProvider.overrideWithValue(false),
            ],
          )
          // Keep the provider alive across reads so autoDispose doesn't tear
          // down the seeded state between assertions.
          ..listen(
            eventDetailsControllerProvider(EventDetailsKey(_appointment)),
            (_, _) {},
          );
    addTearDown(container.dispose);
  });

  EventDetailsController readNotifier() => container.read(
    eventDetailsControllerProvider(EventDetailsKey(_appointment)).notifier,
  );

  EventDetailsState readState() => container.read(
    eventDetailsControllerProvider(EventDetailsKey(_appointment)),
  );

  Future<void> waitForSeed() async {
    // Allow microtasks for client + employee seeding to complete.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('build / seeding', () {
    test('seeds date, times, status from the appointment', () {
      final state = readState();
      expect(state.selectedDate, _appointment.startTime);
      expect(state.selectedStartTime, const TimeOfDay(hour: 9, minute: 0));
      expect(state.selectedEndTime, const TimeOfDay(hour: 10, minute: 0));
      // The fixture's unknown 'booked' status normalizes to 'pending' via
      // AppointmentStatus.fromRaw so it's always re-written as an allowlisted
      // value.
      expect(state.editingStatus, 'pending');
      expect(state.isEditing, isFalse);
    });

    test('loads client + selected employees on first build', () async {
      readNotifier(); // trigger build
      await waitForSeed();
      expect(readState().client, _existingClient);
      expect(readState().selectedEmployees, [_employeeA]);
    });

    test('skips the client load for a known non-admin session (the clients '
        'read rule is admin-only)', () async {
      // Own mock: the shared setUp container's admin-path controller would pollute verifyNever.
      final scopedClients = _MockClientsRepo();
      when(
        () => scopedClients.getClientById(any()),
      ).thenAnswer((_) async => _existingClient);
      final scoped = ProviderContainer(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(scopedClients),
          employeesRepositoryProvider.overrideWithValue(employees),
          appointmentImageUploadProvider.overrideWithValue(uploader),
          imageStorageProvider.overrideWithValue(storage),
          currentUserDocProvider.overrideWith(
            (ref) => Stream.value(const {'role': 'employee', 'uid': 'u1'}),
          ),
        ],
      );
      addTearDown(scoped.dispose);
      // Keep the user-doc stream alive and settled before the controller builds
      // — mirrors main.dart's app-lifetime listen.
      scoped.listen(currentUserDocProvider, (_, _) {});
      await scoped.read(currentUserDocProvider.future);

      scoped
        ..listen(
          eventDetailsControllerProvider(EventDetailsKey(_appointment)),
          (_, _) {},
        )
        ..read(eventDetailsControllerProvider(EventDetailsKey(_appointment)));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => scopedClients.getClientById(any()));
    });

    test(
      'waits for role resolution before deciding whether to load the client',
      () async {
        final scopedClients = _MockClientsRepo();
        final docs = StreamController<Map<String, dynamic>>();
        when(
          () => scopedClients.getClientById(any()),
        ).thenAnswer((_) async => _existingClient);
        final scoped = ProviderContainer(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(scopedClients),
            employeesRepositoryProvider.overrideWithValue(employees),
            appointmentImageUploadProvider.overrideWithValue(uploader),
            imageStorageProvider.overrideWithValue(storage),
            currentUserDocProvider.overrideWith((ref) => docs.stream),
          ],
        );
        addTearDown(docs.close);
        addTearDown(scoped.dispose);

        scoped
          ..listen(currentUserDocProvider, (_, _) {})
          ..listen(
            eventDetailsControllerProvider(EventDetailsKey(_appointment)),
            (_, _) {},
          )
          ..read(eventDetailsControllerProvider(EventDetailsKey(_appointment)));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        verifyNever(() => scopedClients.getClientById(any()));

        docs.add(const {'role': 'employee', 'uid': 'u1'});
        await pumpEventQueue();

        verifyNever(() => scopedClients.getClientById(any()));
      },
    );

    test(
      'a user-doc stream that ERRORS mid-await does not escape as a fatal',
      () async {
        // Shipped as a FATAL on 2026-08-31 and fixed by putting the await INSIDE
        // the try.
        final scopedClients = _MockClientsRepo();
        final docs = StreamController<Map<String, dynamic>>();
        when(
          () => scopedClients.getClientById(any()),
        ).thenAnswer((_) async => _existingClient);
        final scoped = ProviderContainer(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(scopedClients),
            employeesRepositoryProvider.overrideWithValue(employees),
            appointmentImageUploadProvider.overrideWithValue(uploader),
            imageStorageProvider.overrideWithValue(storage),
            currentUserDocProvider.overrideWith((ref) => docs.stream),
          ],
        );
        addTearDown(docs.close);
        addTearDown(scoped.dispose);

        scoped
          ..listen(currentUserDocProvider, (_, _) {})
          ..listen(
            eventDetailsControllerProvider(EventDetailsKey(_appointment)),
            (_, _) {},
          )
          ..read(eventDetailsControllerProvider(EventDetailsKey(_appointment)));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        // The controller is now parked on `.future`, mid-await.
        docs.addError(StateError('unavailable'));
        await pumpEventQueue();

        // The doc really did settle as an error, the client load was abandoned,
        // and nothing escaped — an unhandled async error out of the discarded
        // microtask fails this test on its own.
        expect(scoped.read(currentUserDocProvider).hasError, isTrue);
        verifyNever(() => scopedClients.getClientById(any()));
      },
    );

    test('loads the client once an admin role settles', () async {
      final scopedClients = _MockClientsRepo();
      final docs = StreamController<Map<String, dynamic>>();
      when(
        () => scopedClients.getClientById(any()),
      ).thenAnswer((_) async => _existingClient);
      final scoped = ProviderContainer(
        overrides: [
          appointmentsRepositoryProvider.overrideWithValue(appointments),
          clientsRepositoryProvider.overrideWithValue(scopedClients),
          employeesRepositoryProvider.overrideWithValue(employees),
          appointmentImageUploadProvider.overrideWithValue(uploader),
          imageStorageProvider.overrideWithValue(storage),
          currentUserDocProvider.overrideWith((ref) => docs.stream),
        ],
      );
      addTearDown(docs.close);
      addTearDown(scoped.dispose);

      scoped
        ..listen(currentUserDocProvider, (_, _) {})
        ..listen(
          eventDetailsControllerProvider(EventDetailsKey(_appointment)),
          (_, _) {},
        )
        ..read(eventDetailsControllerProvider(EventDetailsKey(_appointment)));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      verifyNever(() => scopedClients.getClientById(any()));

      docs.add(const {'role': 'admin', 'uid': 'u1'});
      await pumpEventQueue();

      verify(() => scopedClients.getClientById('c1')).called(1);
    });
  });

  group('mode toggles', () {
    test('enterEditing flips isEditing and clears errors', () async {
      final c = readNotifier();
      await c.save(
        _appointment,
        title: '',
        address: '',
        notes: '',
        materialsNeeded: '',
      );
      expect(readState().errors, isNotEmpty);
      c.enterEditing();
      expect(readState().isEditing, isTrue);
      expect(readState().errors, isEmpty);
    });

    test('turning Personal off KEEPS all-day (retired invariant: all-day now '
        'applies to client jobs too, so the flag is reachable and repairable '
        'rather than an unrepairable dead end)', () {
      final c = readNotifier()
        ..setPersonal(value: true)
        ..setAllDay(value: true);
      expect(readState().isAllDay, isTrue);

      c.setPersonal(value: false);
      expect(readState().isAllDay, isTrue);
    });

    test('turning Personal on again does not resurrect all-day', () {
      final c = readNotifier()..setPersonal(value: true);
      expect(readState().isAllDay, isFalse);

      c.setAllDay(value: true);
      expect(readState().isAllDay, isTrue);
    });
  });

  group('end date (multi-day)', () {
    final multiDay = _appointment.copyWith(
      id: 'multi-1',
      startTime: DateTime(2026, 8, 1, 9),
      endTime: DateTime(2026, 8, 5, 17),
    );

    final overnight = _appointment.copyWith(
      id: 'overnight-1',
      startTime: DateTime(2026, 8, 1, 22),
      endTime: DateTime(2026, 8, 4, 6),
    );

    test('seeds the end date from the stored last work day', () {
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(multiDay)),
        (_, _) {},
      );
      final state = container.read(
        eventDetailsControllerProvider(EventDetailsKey(multiDay)),
      );
      expect(state.endDate, DateTime(2026, 8, 5));
      expect(state.endDateTouched, isTrue);
    });

    test('a night shift seeds the last NIGHT, not the morning', () {
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(overnight)),
        (_, _) {},
      );
      final state = container.read(
        eventDetailsControllerProvider(EventDetailsKey(overnight)),
      );
      expect(state.endDate, DateTime(2026, 8, 3));
    });

    test('moving the start date preserves the run length', () {
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(multiDay)),
        (_, _) {},
      );
      container
          .read(
            eventDetailsControllerProvider(EventDetailsKey(multiDay)).notifier,
          )
          .selectDate(DateTime(2026, 8, 3));

      final state = container.read(
        eventDetailsControllerProvider(EventDetailsKey(multiDay)),
      );
      expect(state.endDate, DateTime(2026, 8, 7));
    });

    test('selectEndDate sets the date and marks it touched', () {
      readNotifier().selectEndDate(DateTime(2026, 5, 12));
      expect(readState().endDate, DateTime(2026, 5, 12));
      expect(readState().endDateTouched, isTrue);
    });
  });

  group('toggleEmployee', () {
    test('toggles employees idempotently', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..toggleEmployee(_employeeB);
      expect(readState().selectedEmployees.map((e) => e.id), ['e1', 'e2']);
      c.toggleEmployee(_employeeA);
      expect(readState().selectedEmployees.map((e) => e.id), ['e2']);
    });
  });

  group('markAsDone / cancelAppointment', () {
    test('markAsDone writes status="done" and reports Ok', () async {
      final outcome = await readNotifier().markAsDone(_appointment);
      expect(outcome, isA<EventDetailsActionOk>());
      verify(
        () => appointments.updateAppointmentStatus(
          id: _appointment.id!,
          status: 'done',
        ),
      ).called(1);
    });

    test(
      'cancelAppointment writes status="cancelled" and reports Ok',
      () async {
        final outcome = await readNotifier().cancelAppointment(_appointment);
        expect(outcome, isA<EventDetailsActionOk>());
        verify(
          () => appointments.updateAppointmentStatus(
            id: _appointment.id!,
            status: 'cancelled',
          ),
        ).called(1);
      },
    );

    test('markAsDone reports Failed with the error and resets isSaving '
        'when repo throws', () async {
      final failure = Exception('boom');
      when(
        () => appointments.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      ).thenThrow(failure);
      final outcome = await readNotifier().markAsDone(_appointment);
      expect(outcome, isA<EventDetailsActionFailed>());
      expect((outcome as EventDetailsActionFailed).error, same(failure));
      expect(readState().isSaving, isFalse);
    });

    test('a status write skipped by the busy guard reports Busy', () async {
      final notifier = readNotifier()..setSaving(busy: true);
      final outcome = await notifier.markAsDone(_appointment);
      expect(outcome, isA<EventDetailsActionBusy>());
      verifyNever(
        () => appointments.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      );
    });
  });

  group('save', () {
    test('reports validation errors and skips repo call', () async {
      readNotifier();
      await waitForSeed();
      final outcome = await readNotifier().save(
        _appointment,
        title: '',
        address: '',
        notes: '',
        materialsNeeded: '',
      );
      expect(outcome, isA<EventDetailsInvalid>());
      verifyNever(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      );
    });

    test('a double-tapped save returns SaveBusy, not Invalid', () async {
      // The save family's sibling of `EventDetailsActionBusy`, which the status
      // setters and the delete already return.
      readNotifier();
      await waitForSeed();
      final gate = Completer<void>();
      when(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).thenAnswer((_) => gate.future);

      final c = readNotifier();
      final first = c.save(
        _appointment,
        title: 'Job',
        address: '',
        notes: '',
        materialsNeeded: '',
      );
      final second = await c.save(
        _appointment,
        title: 'Job',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      expect(second, isA<EventDetailsSaveBusy>());
      gate.complete();
      await first;
      verify(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).called(1);
    });

    test(
      'an all-day edit saves midnight to 23:59, not the picked times',
      () async {
        // The EDIT half of the appointmentSpan invariant.
        readNotifier();
        await waitForSeed();
        final c = readNotifier()
          // Times picked BEFORE the switch was flipped stay in state; the span
          // helper must ignore them.
          ..selectStartTime(const TimeOfDay(hour: 14, minute: 0))
          ..selectEndTime(const TimeOfDay(hour: 16, minute: 0))
          ..setPersonal(value: true)
          ..setAllDay(value: true);

        final outcome = await c.save(
          _appointment,
          title: 'Dentist',
          address: '',
          notes: '',
          materialsNeeded: '',
        );

        expect(outcome, isA<EventDetailsSaved>());
        final saved = (outcome as EventDetailsSaved).appointment;
        expect(saved.isAllDay, isTrue);
        expect(saved.startTime, DateTime(2026, 5, 10));
        expect(saved.endTime, DateTime(2026, 5, 10, 23, 59));
      },
    );

    test('a personal job keeps its address and drops its client', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..setPersonal(value: true);

      final outcome = await c.save(
        _appointment,
        title: 'Dentist',
        address: '99 New St',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsSaved>());
      final saved = (outcome as EventDetailsSaved).appointment;
      expect(saved.isPersonal, isTrue);
      // The client is cleared — its picker is gone from the form.
      expect(saved.clientId, isEmpty);
      expect(saved.clientName, isEmpty);
      expect(saved.address, '99 New St');
    });

    test('writes updated appointment with edited values on success', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()
        ..setStatus('done')
        ..selectStartTime(const TimeOfDay(hour: 14, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 16, minute: 0));

      final outcome = await c.save(
        _appointment,
        title: 'Updated title',
        address: '99 New St',
        notes: 'see notes',
        materialsNeeded: 'pliers',
      );

      expect(outcome, isA<EventDetailsSaved>());
      final saved = (outcome as EventDetailsSaved).appointment;
      expect(saved.title, 'Updated title');
      expect(saved.address, '99 New St');
      expect(saved.notes, 'see notes');
      expect(saved.materialsNeeded, 'pliers');
      expect(saved.status, 'done');
      expect(saved.startTime, DateTime(2026, 5, 10, 14));
      expect(saved.endTime, DateTime(2026, 5, 10, 16));

      verify(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).called(1);
    });

    test('preserves a disabled assignee not in the active list (B1)', () async {
      final withDisabled = _appointment.copyWith(
        employeeIds: const ['e1', 'e9'],
        employeeNames: const ['Alex', 'Zoe'],
      );
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(withDisabled)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(withDisabled)).notifier,
      );
      await waitForSeed();
      // Only the active assignee is resolvable into the picker.
      expect(
        container
            .read(eventDetailsControllerProvider(EventDetailsKey(withDisabled)))
            .selectedEmployees
            .map((e) => e.id),
        ['e1'],
      );

      final outcome = await c.save(
        withDisabled,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );

      // e9 (disabled, never shown in the picker) is retained, not dropped.
      final saved = (outcome as EventDetailsSaved).appointment;
      expect(saved.employeeIds, ['e1', 'e9']);
      expect(saved.employeeNames, ['Alex', 'Zoe']);
    });

    test('a genuinely-empty active list retains every original assignee', () {
      // The counterpart to the retain rule above.
      when(employees.watchEmployees).thenAnswer((_) => Stream.value(const []));

      final withTwo = _appointment.copyWith(
        id: 'appt-empty-active',
        employeeIds: const ['e1', 'e2'],
        employeeNames: const ['Alex', 'Bea'],
      );
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(withTwo)),
        (_, _) {},
      );

      // Seeded from the record itself, so the picker still names them even
      // though none resolves against the (empty) active set.
      expect(
        container
            .read(eventDetailsControllerProvider(EventDetailsKey(withTwo)))
            .selectedEmployees
            .map((e) => e.id),
        ['e1', 'e2'],
      );
    });

    test(
      'awaits the employee seed before validating (B1 race): a save fired '
      'before seeding settles keeps active assignees, not "employees required"',
      () async {
        final fresh = _appointment.copyWith(id: 'appt-race');
        container.listen(
          eventDetailsControllerProvider(EventDetailsKey(fresh)),
          (_, _) {},
        );
        final c = container.read(
          eventDetailsControllerProvider(EventDetailsKey(fresh)).notifier,
        );

        // Intentionally omits waitForSeed — save() must settle the seed itself,
        // or validation would see an empty selection and return
        // employeesRequired.
        final outcome = await c.save(
          fresh,
          title: 'x',
          address: 'y',
          notes: '',
          materialsNeeded: '',
        );

        expect(outcome, isA<EventDetailsSaved>());
        final saved = (outcome as EventDetailsSaved).appointment;
        expect(saved.employeeIds, ['e1']);
        expect(saved.employeeNames, ['Alex']);
      },
    );

    test('uses freshly-picked client over the loaded one', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..selectClient(_newClient);

      final outcome = await c.save(
        _appointment,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );
      final saved = (outcome as EventDetailsSaved).appointment;
      expect(saved.clientId, _newClient.id);
      expect(saved.clientName, _newClient.displayName);
      expect(saved.clientPhone, _newClient.phone);
    });

    test('reports clientRequired after the client is cleared', () async {
      readNotifier();
      await waitForSeed();
      final c = readNotifier()..clearClient();

      final outcome = await c.save(
        _appointment,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsInvalid>());
      expect(readState().errors, contains('client'));
      verifyNever(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      );
    });

    test('does not call deleteImages when nothing was removed', () async {
      readNotifier();
      await waitForSeed();
      await readNotifier().save(
        _appointment,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );
      verifyNever(() => storage.deleteImages(any()));
    });

    test('does not run uploader when no new images are queued', () async {
      readNotifier();
      await waitForSeed();
      await readNotifier().save(
        _appointment,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );
      verifyNever(
        () => uploader.enqueuePhotos(
          appointmentId: any(named: 'appointmentId'),
          newImages: any(named: 'newImages'),
        ),
      );
    });

    test('rewrites the series when the repeat rule changes', () async {
      var nextId = 0;
      when(appointments.newDocId).thenAnswer((_) => 'copy-${++nextId}');
      when(
        () => appointments.rewriteSeries(
          updated: any(named: 'updated'),
          deleteIds: any(named: 'deleteIds'),
          copies: any(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      ).thenAnswer((_) async {});

      readNotifier();
      await waitForSeed();
      final c = readNotifier()..selectRepeat(RepeatInterval.sixMonths);

      final outcome = await c.save(
        _appointment,
        title: 'Furnace check',
        address: '99 New St',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsSaved>());
      // 60-month horizon / 6 = 10 future visits, booked across five years.
      expect((outcome as EventDetailsSaved).futureBookings, 10);
      expect(outcome.appointment.repeat, RepeatInterval.sixMonths);
      // A doc without a series gets one keyed by its own id.
      expect(outcome.appointment.seriesId, 'appt-1');

      final captured = verify(
        () => appointments.rewriteSeries(
          updated: captureAny(named: 'updated'),
          deleteIds: captureAny(named: 'deleteIds'),
          copies: captureAny(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      ).captured;
      expect((captured[1] as List).cast<String>(), isEmpty);
      final copies = (captured[2] as List).cast<AppointmentRecord>();
      expect(copies, hasLength(10));
      expect(copies.first.id, 'copy-1');
      expect(copies.last.id, 'copy-10');
      expect(copies[0].startTime, DateTime(2026, 11, 10, 9));
      expect(copies[1].startTime, DateTime(2027, 5, 10, 9));
      expect(copies.last.startTime, DateTime(2031, 5, 10, 9));
      expect(copies.every((a) => a.status == 'pending'), isTrue);
      expect(copies.every((a) => a.pictureCount == 0), isTrue);
      expect(copies.every((a) => a.seriesId == 'appt-1'), isTrue);

      // The rule is now the baseline — a second save is a plain update.
      final second = await c.save(
        _appointment,
        title: 'Furnace check',
        address: '99 New St',
        notes: '',
        materialsNeeded: '',
      );
      expect((second as EventDetailsSaved).futureBookings, 0);
      verify(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).called(1);
    });

    test('deletes the old future visits when replacing a series', () async {
      var nextId = 0;
      when(appointments.newDocId).thenAnswer((_) => 'copy-${++nextId}');
      when(
        () => appointments.rewriteSeries(
          updated: any(named: 'updated'),
          deleteIds: any(named: 'deleteIds'),
          copies: any(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      ).thenAnswer((_) async {});

      final repeating = _appointment.copyWith(
        repeat: RepeatInterval.fourMonths,
        seriesId: 'series-1',
      );
      when(() => appointments.getSeries('series-1')).thenAnswer(
        (_) async => [
          repeating,
          repeating.copyWith(id: 'old-1', startTime: DateTime(2026, 9, 10, 9)),
          repeating.copyWith(id: 'old-2', startTime: DateTime(2027, 1, 10, 9)),
          repeating.copyWith(
            id: 'old-done',
            startTime: DateTime(2027, 5, 10, 9),
            status: 'done',
          ),
        ],
      );

      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );
      await waitForSeed();
      c.selectRepeat(RepeatInterval.oneYear);

      final outcome = await c.save(
        repeating,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );

      // 60-month horizon / 12 = 5 future visits across five years.
      expect((outcome as EventDetailsSaved).futureBookings, 5);
      expect(outcome.removedBookings, 2);

      final captured = verify(
        () => appointments.rewriteSeries(
          updated: captureAny(named: 'updated'),
          deleteIds: captureAny(named: 'deleteIds'),
          copies: captureAny(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      ).captured;
      // The edited doc itself and the done visit are preserved.
      expect((captured[1] as List).cast<String>(), ['old-1', 'old-2']);
      final copies = (captured[2] as List).cast<AppointmentRecord>();
      expect(copies, hasLength(5));
      expect(copies.first.startTime, DateTime(2027, 5, 10, 9));
      expect(copies.last.startTime, DateTime(2031, 5, 10, 9));
      expect(copies.every((a) => a.seriesId == 'series-1'), isTrue);
    });

    test('stops a repeat rewrite when a future copy conflicts', () async {
      var nextId = 0;
      when(appointments.newDocId).thenAnswer((_) => 'copy-${++nextId}');

      final repeating = _appointment.copyWith(
        repeat: RepeatInterval.fourMonths,
        seriesId: 'series-1',
      );
      when(() => appointments.getSeries('series-1')).thenAnswer(
        (_) async => [
          repeating,
          repeating.copyWith(id: 'old-1', startTime: DateTime(2026, 9, 10, 9)),
          repeating.copyWith(id: 'old-2', startTime: DateTime(2027, 1, 10, 9)),
        ],
      );
      when(
        () => appointments.findClashingAppointments(
          employeeIds: any(named: 'employeeIds'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      ).thenAnswer((invocation) async {
        final start = invocation.namedArguments[#start] as DateTime;
        if (start != DateTime(2027, 5, 10, 9)) {
          return const <AppointmentRecord>[];
        }
        return [
          AppointmentRecord(
            id: 'external',
            startTime: start,
            endTime: start.add(const Duration(hours: 1)),
            employeeIds: const ['e1'],
            employeeNames: const ['Alex'],
          ),
        ];
      });

      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );
      await waitForSeed();
      c.selectRepeat(RepeatInterval.oneYear);

      final outcome = await c.save(
        repeating,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsBusyEmployees>());
      final busy = outcome as EventDetailsBusyEmployees;
      expect(busy.busyEmployees, const [_employeeA]);
      expect(busy.start, DateTime(2027, 5, 10, 9));
      verifyNever(
        () => appointments.rewriteSeries(
          updated: any(named: 'updated'),
          deleteIds: any(named: 'deleteIds'),
          copies: any(named: 'copies'),
          base: any(named: 'base'),
          deleteBases: any(named: 'deleteBases'),
        ),
      );
      expect(
        container
            .read(eventDetailsControllerProvider(EventDetailsKey(repeating)))
            .isSaving,
        isFalse,
      );
    });

    test('applyToSeries propagates details + time of day to future visits, '
        'keeping each visit date', () async {
      when(
        () =>
            appointments.updateAppointments(any(), bases: any(named: 'bases')),
      ).thenAnswer((_) async {});

      final repeating = _appointment.copyWith(
        id: 'series-1',
        seriesId: 'series-1',
        repeat: RepeatInterval.sixMonths,
      );
      when(() => appointments.getSeries('series-1')).thenAnswer(
        (_) async => [
          repeating,
          repeating.copyWith(id: 'past', startTime: DateTime(2025, 11, 10, 9)),
          repeating.copyWith(
            id: 'fut-1',
            startTime: DateTime(2026, 11, 10, 9),
            status: 'confirmed',
          ),
          repeating.copyWith(
            id: 'fut-2',
            startTime: DateTime(2027, 5, 10, 9),
            status: 'in_progress',
          ),
          repeating.copyWith(
            id: 'fut-done',
            startTime: DateTime(2027, 11, 10, 9),
            status: 'done',
          ),
        ],
      );

      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );
      await waitForSeed();
      // Move the time of day; the repeat rule is unchanged.
      c
        ..selectStartTime(const TimeOfDay(hour: 8, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 9, minute: 0));

      final outcome = await c.save(
        repeating,
        title: 'New title',
        address: 'New address',
        notes: 'n',
        materialsNeeded: 'm',
        applyToSeries: true,
      );

      // Two future non-terminal siblings updated; past and done preserved.
      expect((outcome as EventDetailsSaved).updatedSiblings, 2);

      final captured = verify(
        () => appointments.updateAppointments(
          captureAny(),
          bases: any(named: 'bases'),
        ),
      ).captured.single;
      final batch = (captured as List).cast<AppointmentRecord>();
      // This visit plus the two future siblings, in order.
      expect(batch.map((a) => a.id), ['series-1', 'fut-1', 'fut-2']);
      expect(batch.every((a) => a.title == 'New title'), isTrue);
      expect(batch.every((a) => a.address == 'New address'), isTrue);
      expect(batch.every((a) => a.seriesId == 'series-1'), isTrue);
      // Status stays per-visit (never propagated) but is canonicalized:
      // 'confirmed' normalizes to 'pending', 'in_progress' round-trips
      // unchanged.
      expect(batch[1].status, 'pending');
      expect(batch[2].status, 'in_progress');
      // Each sibling keeps its own date but takes the new time of day.
      expect(batch[1].startTime, DateTime(2026, 11, 10, 8));
      expect(batch[1].endTime, DateTime(2026, 11, 10, 9));
      expect(batch[2].startTime, DateTime(2027, 5, 10, 8));
      expect(batch[2].endTime, DateTime(2027, 5, 10, 9));

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

    test('applyToSeries reports a conflict on a future sibling', () async {
      final repeating = _appointment.copyWith(
        id: 'series-1',
        seriesId: 'series-1',
        repeat: RepeatInterval.sixMonths,
      );
      when(() => appointments.getSeries('series-1')).thenAnswer(
        (_) async => [
          repeating,
          repeating.copyWith(id: 'fut-1', startTime: DateTime(2026, 11, 10, 9)),
        ],
      );
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      ).thenAnswer((invocation) async {
        final start = invocation.namedArguments[#start] as DateTime;
        return start == DateTime(2026, 11, 10, 8)
            ? const [_employeeA]
            : const <EmployeeRecord>[];
      });

      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );
      await waitForSeed();
      c
        ..selectStartTime(const TimeOfDay(hour: 8, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 9, minute: 0));

      final outcome = await c.save(
        repeating,
        title: 'New title',
        address: 'New address',
        notes: '',
        materialsNeeded: '',
        applyToSeries: true,
      );

      expect(outcome, isA<EventDetailsBusyEmployees>());
      final busy = outcome as EventDetailsBusyEmployees;
      expect(busy.start, DateTime(2026, 11, 10, 8));
      expect(busy.end, DateTime(2026, 11, 10, 9));
      verifyNever(
        () =>
            appointments.updateAppointments(any(), bases: any(named: 'bases')),
      );
    });

    test('applyToSeries false edits only this visit', () async {
      final repeating = _appointment.copyWith(
        id: 'series-1',
        seriesId: 'series-1',
        repeat: RepeatInterval.sixMonths,
      );
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );
      await waitForSeed();

      final outcome = await c.save(
        repeating,
        title: 'New title',
        address: 'New address',
        notes: '',
        materialsNeeded: '',
      );

      expect((outcome as EventDetailsSaved).updatedSiblings, 0);
      verify(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      ).called(1);
      verifyNever(() => appointments.getSeries(any()));
      verifyNever(
        () =>
            appointments.updateAppointments(any(), bases: any(named: 'bases')),
      );
    });

    test('seeds the stored repeat and does not re-book it unchanged', () async {
      // Distinct id — the family is keyed by appointment id, so reusing
      // _appointment's id would return setUp's already-seeded (repeat: none)
      // instance.
      final repeating = _appointment.copyWith(
        id: 'repeat-seed-1',
        repeat: RepeatInterval.sixMonths,
      );
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );
      await waitForSeed();
      expect(
        container
            .read(eventDetailsControllerProvider(EventDetailsKey(repeating)))
            .repeat,
        RepeatInterval.sixMonths,
      );

      final outcome = await c.save(
        repeating,
        title: 'x',
        address: 'y',
        notes: '',
        materialsNeeded: '',
      );

      expect((outcome as EventDetailsSaved).futureBookings, 0);
      // The unchanged rule still persists on the saved doc.
      expect(outcome.appointment.repeat, RepeatInterval.sixMonths);
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

    test('does not book copies when repeat stays none', () async {
      readNotifier();
      await waitForSeed();
      await readNotifier().save(
        _appointment,
        title: 'x',
        address: 'y',
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

    test(
      'returns EventDetailsFailed and resets isSaving when repo throws',
      () async {
        when(
          () => appointments.updateAppointment(any(), base: any(named: 'base')),
        ).thenThrow(Exception('boom'));
        readNotifier();
        await waitForSeed();
        final outcome = await readNotifier().save(
          _appointment,
          title: 'x',
          address: 'y',
          notes: '',
          materialsNeeded: '',
        );
        expect(outcome, isA<EventDetailsFailed>());
        expect(readState().isSaving, isFalse);
      },
    );

    // The offline invariant covered `save()` alone, and there are FOUR guards
    // on this controller.
    ProviderContainer offlineContainer() {
      final c =
          ProviderContainer(
            overrides: [
              appointmentsRepositoryProvider.overrideWithValue(appointments),
              clientsRepositoryProvider.overrideWithValue(clients),
              employeesRepositoryProvider.overrideWithValue(employees),
              appointmentImageUploadProvider.overrideWithValue(uploader),
              imageStorageProvider.overrideWithValue(storage),
              isOfflineProvider.overrideWithValue(true),
            ],
          )..listen(
            eventDetailsControllerProvider(EventDetailsKey(_appointment)),
            (_, _) {},
          );
      addTearDown(c.dispose);
      return c;
    }

    test('markComplete fails fast offline and never writes', () async {
      final offline = offlineContainer();
      final key = EventDetailsKey(_appointment);

      final outcome = await offline
          .read(eventDetailsControllerProvider(key).notifier)
          .markAsDone(_appointment);

      expect(outcome, isA<EventDetailsActionFailed>());
      // A SocketException, NOT a Busy: `_classifyError` keys on the type, so
      // this is what renders the offline notice rather than a generic error.
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
      // The flag is untouched, so the button is still usable on reconnect.
      expect(
        offline.read(eventDetailsControllerProvider(key)).isSaving,
        isFalse,
      );
    });

    test('deleteAppointment fails fast offline and never writes', () async {
      final offline = offlineContainer();
      final key = EventDetailsKey(_appointment);

      final outcome = await offline
          .read(eventDetailsControllerProvider(key).notifier)
          .deleteAppointment(_appointment);

      expect(outcome, isA<EventDetailsActionFailed>());
      expect(
        (outcome as EventDetailsActionFailed).error,
        isA<SocketException>(),
      );
      verifyNever(() => appointments.deleteAppointment(any()));
      expect(
        offline.read(eventDetailsControllerProvider(key)).isSaving,
        isFalse,
      );
    });

    test(
      'a series cancel fails fast offline and never reads the series',
      () async {
        final offline = offlineContainer();
        final key = EventDetailsKey(_appointment);

        final outcome = await offline
            .read(eventDetailsControllerProvider(key).notifier)
            .cancelAppointment(
              _appointment.copyWith(seriesId: 'series-1'),
              includeFuture: true,
            );

        expect(outcome, isA<EventDetailsActionFailed>());
        expect(
          (outcome as EventDetailsActionFailed).error,
          isA<SocketException>(),
        );
        verifyNever(() => appointments.getSeries(any()));
        expect(
          offline.read(eventDetailsControllerProvider(key)).isSaving,
          isFalse,
        );
      },
    );

    test(
      'offline fails fast without touching the repo or the busy flag',
      () async {
        final key = EventDetailsKey(_appointment);
        final offline = ProviderContainer(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            employeesRepositoryProvider.overrideWithValue(employees),
            appointmentImageUploadProvider.overrideWithValue(uploader),
            imageStorageProvider.overrideWithValue(storage),
            isOfflineProvider.overrideWithValue(true),
          ],
        )..listen(eventDetailsControllerProvider(key), (_, _) {});
        addTearDown(offline.dispose);

        final outcome = await offline
            .read(eventDetailsControllerProvider(key).notifier)
            .save(
              _appointment,
              title: 'x',
              address: 'y',
              notes: '',
              materialsNeeded: '',
            );

        expect(outcome, isA<EventDetailsFailed>());
        expect((outcome as EventDetailsFailed).error, isA<SocketException>());
        verifyNever(
          () => appointments.updateAppointment(any(), base: any(named: 'base')),
        );
        expect(
          offline.read(eventDetailsControllerProvider(key)).isSaving,
          isFalse,
        );
      },
    );
  });

  group('deleteAppointment', () {
    test(
      'returns Ok on repo success and calls the repo with the doc id',
      () async {
        final outcome = await readNotifier().deleteAppointment(_appointment);
        expect(outcome, isA<EventDetailsActionOk>());
        verify(() => appointments.deleteAppointment('appt-1')).called(1);
      },
    );

    test('returns Failed and resets isSaving when repo throws', () async {
      when(
        () => appointments.deleteAppointment(any()),
      ).thenThrow(Exception('boom'));
      final outcome = await readNotifier().deleteAppointment(_appointment);
      expect(outcome, isA<EventDetailsActionFailed>());
      expect(readState().isSaving, isFalse);
    });

    test('a reentrant delete returns Busy, not a success', () async {
      // B3: the guard used to return the same `null` success meant, so the
      // sheet announced "Appointment deleted" for a write it never made.
      final notifier = readNotifier()..setSaving(busy: true);

      final outcome = await notifier.deleteAppointment(_appointment);

      expect(outcome, isA<EventDetailsActionBusy>());
      verifyNever(() => appointments.deleteAppointment(any()));
    });

    test('a delete without a doc id returns Failed', () async {
      final outcome = await readNotifier().deleteAppointment(
        _appointment.copyWith(id: null),
      );
      expect(outcome, isA<EventDetailsActionFailed>());
      verifyNever(() => appointments.deleteAppointment(any()));
    });

    test('includeFuture deletes the series future visits too', () async {
      when(
        () => appointments.deleteAppointments(any()),
      ).thenAnswer((_) async {});
      final repeating = _appointment.copyWith(
        repeat: RepeatInterval.fourMonths,
        seriesId: 'series-1',
      );
      when(() => appointments.getSeries('series-1')).thenAnswer(
        (_) async => [
          repeating,
          repeating.copyWith(id: 'past-1', startTime: DateTime(2026, 1, 10, 9)),
          repeating.copyWith(id: 'old-1', startTime: DateTime(2026, 9, 10, 9)),
          repeating.copyWith(
            id: 'old-done',
            startTime: DateTime(2027, 1, 10, 9),
            status: 'done',
          ),
        ],
      );
      container.listen(
        eventDetailsControllerProvider(EventDetailsKey(repeating)),
        (_, _) {},
      );
      final c = container.read(
        eventDetailsControllerProvider(EventDetailsKey(repeating)).notifier,
      );

      final outcome = await c.deleteAppointment(repeating, includeFuture: true);

      expect(outcome, isA<EventDetailsActionOk>());
      final captured = verify(
        () => appointments.deleteAppointments(captureAny()),
      ).captured.single;
      // Past and done visits stay; itself plus the future pending one go.
      expect((captured as List).cast<String>(), ['appt-1', 'old-1']);
      verifyNever(() => appointments.deleteAppointment(any()));
    });

    test('includeFuture without a series is a single delete', () async {
      final outcome = await readNotifier().deleteAppointment(
        _appointment,
        includeFuture: true,
      );
      expect(outcome, isA<EventDetailsActionOk>());
      verify(() => appointments.deleteAppointment('appt-1')).called(1);
    });
  });

  group('busy-employee conflict', () {
    test('save returns the busy outcome and clears the saving flag', () async {
      await waitForSeed();
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      ).thenAnswer((_) async => const [_employeeA]);

      final outcome = await readNotifier().save(
        _appointment,
        title: 'Job',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsBusyEmployees>());
      // The flag must clear or Save stays stuck once the dialog is dismissed.
      expect(readState().isSaving, isFalse);
      verifyNever(
        () => appointments.updateAppointment(any(), base: any(named: 'base')),
      );
    });

    test('a PERSONAL save never returns the busy outcome — the clash alert '
        'handles it after the write', () async {
      // Two dialogs about the same clash, back to back, is what running both
      // would give.
      await waitForSeed();
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      ).thenAnswer((_) async => const [_employeeA]);

      readNotifier().setPersonal(value: true);
      final outcome = await readNotifier().save(
        _appointment,
        title: 'Dentist',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<EventDetailsSaved>());
      verifyNever(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      );
    });

    test(
      'excludes the appointment being edited from its own conflicts',
      () async {
        await waitForSeed();

        await readNotifier().save(
          _appointment,
          title: 'Job',
          address: '',
          notes: '',
          materialsNeeded: '',
        );

        final captured = verify(
          () => appointments.findBusyEmployees(
            candidates: any(named: 'candidates'),
            start: any(named: 'start'),
            end: any(named: 'end'),
            excludeAppointmentId: captureAny(named: 'excludeAppointmentId'),
          ),
        ).captured.single;
        expect(captured, 'appt-1');
      },
    );

    test('forceBusy skips the conflict check and writes', () async {
      await waitForSeed();

      final outcome = await readNotifier().save(
        _appointment,
        title: 'Job',
        address: '',
        notes: '',
        materialsNeeded: '',
        forceBusy: true,
      );

      expect(outcome, isA<EventDetailsSaved>());
      verifyNever(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      );
    });
  });

  group('per-day completion', () {
    List<AppointmentRecord> runOf(int days) => [
      for (var i = 1; i <= days; i++)
        AppointmentRecord(
          id: 'd$i',
          seriesId: 'd1',
          dayIndex: i,
          dayCount: days,
          startTime: DateTime(2026, 8, 2 + i, 9),
          endTime: DateTime(2026, 8, 2 + i, 17),
        ),
    ];

    EventDetailsController notifierFor(AppointmentRecord a) => container.read(
      eventDetailsControllerProvider(EventDetailsKey(a)).notifier,
    );

    test('marking one day done leaves the rest of the run untouched', () async {
      final run = runOf(5);
      final outcome = await notifierFor(run[2]).markAsDone(run[2]);

      expect(outcome, isA<EventDetailsActionOk>());
      // THE regression this whole change exists to prevent: one document, one
      // status.
      verify(
        () => appointments.updateAppointmentStatus(id: 'd3', status: 'done'),
      ).called(1);
      verifyNever(
        () => appointments.updateAppointmentStatuses(
          ids: any(named: 'ids'),
          status: any(named: 'status'),
        ),
      );
    });

    test(
      'cancelling with the run scope closes this day and the ones after',
      () async {
        final run = runOf(5);
        when(() => appointments.getSeries('d1')).thenAnswer((_) async => run);
        when(
          () => appointments.updateAppointmentStatuses(
            ids: any(named: 'ids'),
            status: any(named: 'status'),
          ),
        ).thenAnswer((_) async {});

        final outcome = await notifierFor(
          run[2],
        ).cancelAppointment(run[2], includeFuture: true);

        expect(outcome, isA<EventDetailsActionOk>());
        final ids =
            verify(
                  () => appointments.updateAppointmentStatuses(
                    ids: captureAny(named: 'ids'),
                    status: 'cancelled',
                  ),
                ).captured.single
                as List<String>;
        expect(ids, ['d3', 'd4', 'd5']);
      },
    );

    test('cancelling without the run scope closes only this day', () async {
      final run = runOf(3);
      final outcome = await notifierFor(run.first).cancelAppointment(run.first);

      expect(outcome, isA<EventDetailsActionOk>());
      verify(
        () =>
            appointments.updateAppointmentStatus(id: 'd1', status: 'cancelled'),
      ).called(1);
      verifyNever(() => appointments.getSeries(any()));
    });

    test('a run cancel is skipped while one is already in flight', () async {
      final run = runOf(3);
      when(() => appointments.getSeries('d1')).thenAnswer((_) async => run);
      final notifier = notifierFor(run.first)..setSaving(busy: true);

      expect(
        await notifier.cancelAppointment(run.first, includeFuture: true),
        isA<EventDetailsActionBusy>(),
      );
      verifyNever(() => appointments.getSeries(any()));
    });
  });
}
