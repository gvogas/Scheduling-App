import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/calendar/application/add_event_controller.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_prefill.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/clients/domain/policies/phone_query_policy.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';

class _MockAppointmentsRepo extends Mock implements AppointmentsRepository {}

class _MockClientsRepo extends Mock implements ClientsRepository {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockUploader extends Mock implements AppointmentImageUploadService {}

const _aClient = ClientRecord(
  id: 'c1',
  name: 'Jane Doe',
  phone: '555-0001',
  address: '123 Main St',
);

const _employeeA = EmployeeRecord(id: 'e1', name: 'Alex');
const _employeeB = EmployeeRecord(id: 'e2', name: 'Bea');
const _dispatcher = EmployeeRecord(
  id: 'e3',
  name: 'Dee',
  jobTitle: JobTitle.dispatcher,
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
    registerFallbackValue(<EmployeeRecord>[]);
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(<AppointmentImage>[]);
    registerFallbackValue(<AppointmentRecord>[]);
    registerFallbackValue(<File>[]);
  });

  late _MockAppointmentsRepo appointments;
  late _MockClientsRepo clients;
  late _MockEmployeesRepo employees;
  late _MockUploader uploader;
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

    // The roster a prefill resolves its crew against: two crew, one dispatcher.
    when(employees.watchEmployees).thenAnswer(
      (_) => Stream.value(const [_employeeA, _employeeB, _dispatcher]),
    );

    when(appointments.newDocId).thenReturn('appt-1');
    when(() => appointments.addAppointment(any())).thenAnswer((_) async {});
    when(
      () => appointments.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
      ),
    ).thenAnswer((_) async => const []);

    container = ProviderContainer(
      overrides: [
        appointmentsRepositoryProvider.overrideWithValue(appointments),
        clientsRepositoryProvider.overrideWithValue(clients),
        appointmentImageUploadProvider.overrideWithValue(uploader),
        employeesRepositoryProvider.overrideWithValue(employees),
        authUidProvider.overrideWith((ref) => Stream<String?>.value('uid-1')),
        // Online by default here — the offline test below builds its own.
        isOfflineProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    // Auto-dispose: keep the roster stream alive across the prefill's read.
    container.listen(employeesStreamProvider, (_, _) {});
  });

  AddEventController readNotifier([DateTime? initialDate]) =>
      container.read(addEventControllerProvider(initialDate).notifier);

  AddEventState readState([DateTime? initialDate]) =>
      container.read(addEventControllerProvider(initialDate));

  AddEventState fillValid(AddEventController c, {DateTime? initialDate}) {
    c
      ..selectDate(DateTime(2026, 5, 10))
      ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
      ..selectEndTime(const TimeOfDay(hour: 10, minute: 0))
      ..selectClient(_aClient)
      ..toggleEmployee(_employeeA);
    return readState(initialDate);
  }

  group('selectStartTime', () {
    test('auto-advances end by one hour when end was not picked manually', () {
      readNotifier().selectStartTime(const TimeOfDay(hour: 9, minute: 0));
      expect(readState().selectedEndTime, const TimeOfDay(hour: 10, minute: 0));
    });

    test('does not overwrite end after a manual end pick', () {
      readNotifier()
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 14, minute: 0))
        ..selectStartTime(const TimeOfDay(hour: 11, minute: 0));
      expect(readState().selectedEndTime, const TimeOfDay(hour: 14, minute: 0));
    });
  });

  group('end date', () {
    test('mirrors the start date until it is touched', () {
      final c = readNotifier()..selectDate(DateTime(2026, 8));
      expect(readState().endDate, DateTime(2026, 8));

      c.selectDate(DateTime(2026, 8, 4));
      expect(readState().endDate, DateTime(2026, 8, 4));
    });

    test('once touched, moving the start shifts the end by the same days', () {
      final c = readNotifier()
        ..selectDate(DateTime(2026, 8))
        ..selectEndDate(DateTime(2026, 8, 5));
      expect(readState().endDateTouched, isTrue);

      c.selectDate(DateTime(2026, 8, 3));
      expect(readState().endDate, DateTime(2026, 8, 7));
    });

    test('a start date moved past a touched end date drags the end along', () {
      readNotifier()
        ..selectDate(DateTime(2026, 8))
        ..selectEndDate(DateTime(2026, 8, 2))
        ..selectDate(DateTime(2026, 8, 10));
      expect(readState().endDate, DateTime(2026, 8, 11));
    });

    test('selectEndDate clears any endDate error', () async {
      final c = readNotifier()
        ..selectDate(DateTime(2026, 8, 5))
        // Before the start date, so validate() flags it once submit() runs.
        ..selectEndDate(DateTime(2026, 8));
      await c.submit(title: '', address: '', notes: '', materialsNeeded: '');
      expect(readState().errors.containsKey('endDate'), isTrue);

      c.selectEndDate(DateTime(2026, 8, 10));
      expect(readState().errors.containsKey('endDate'), isFalse);
    });
  });

  group('toggleEmployee', () {
    test('adds employees and removes them idempotently', () {
      final c = readNotifier()
        ..toggleEmployee(_employeeA)
        ..toggleEmployee(_employeeB);
      expect(readState().selectedEmployees, [_employeeA, _employeeB]);

      c.toggleEmployee(_employeeA);
      expect(readState().selectedEmployees, [_employeeB]);
    });
  });

  group('searchClients', () {
    const marie = ClientRecord(
      id: 'c1',
      name: 'Marie Tremblay',
      phone: '5145628332',
    );
    const jp = ClientRecord(id: 'c2', name: 'J-P Gagnon', phone: '5145628901');

    test('clears results without hitting the repo on empty query', () async {
      final c = readNotifier();
      await c.searchClients('');
      verifyNever(() => clients.searchClients(any()));
      expect(readState().clientResults, isEmpty);
      expect(readState().isSearchingClient, isFalse);
    });

    test('populates results from the repo on non-empty query', () async {
      when(
        () => clients.searchClients('jan'),
      ).thenAnswer((_) async => const [_aClient]);
      final c = readNotifier();
      await c.searchClients('jan');
      expect(readState().clientResults, [_aClient]);
      expect(readState().isSearchingClient, isFalse);
    });

    test('a slow older search never overwrites a newer one', () async {
      const bClient = ClientRecord(
        id: 'c2',
        name: 'Marc Roy',
        phone: '555-0002',
        address: '9 Oak St',
      );
      final slow = Completer<List<ClientRecord>>();
      when(() => clients.searchClients('ma')).thenAnswer((_) => slow.future);
      when(
        () => clients.searchClients('mar'),
      ).thenAnswer((_) async => const [bClient]);

      final c = readNotifier();
      final first = c.searchClients('ma');
      await c.searchClients('mar');
      expect(readState().clientResults, [bClient]);

      // The older read resolving late must be discarded, not published.
      slow.complete(const [_aClient]);
      await first;
      expect(readState().clientResults, [bClient]);
      expect(readState().isSearchingClient, isFalse);
    });

    test(
      'a digits-only query under seven digits never hits the repository',
      () async {
        await readNotifier().searchClients('514');
        await readNotifier().searchClients('514562');
        verifyNever(() => clients.searchClients(any()));
        expect(readState().clientSearchStatus.isHolding, isTrue);
        expect(readState().clientSearchStatus.digitsTyped, 6);
      },
    );

    test('a text query still searches from the first character', () async {
      when(() => clients.searchClients(any())).thenAnswer((_) async => []);
      await readNotifier().searchClients('t');
      verify(() => clients.searchClients('t')).called(1);
      expect(readState().clientSearchStatus.mode, ClientQueryMode.text);
    });

    test('seven digits sends the canonical query once', () async {
      when(() => clients.searchClients(any())).thenAnswer((_) async => [marie]);
      await readNotifier().searchClients('(514) 562-8');
      verify(() => clients.searchClients('5145628')).called(1);
      expect(readState().clientResults, [marie]);
      expect(readState().clientSearchStatus.answeredRung, PhoneRung.canonical);
    });

    test('a leading 1 is dropped before the query is sent', () async {
      when(() => clients.searchClients(any())).thenAnswer((_) async => [marie]);
      await readNotifier().searchClients('1 514 562 8332');
      verify(() => clients.searchClients('5145628332')).called(1);
    });

    test(
      'extra digits narrow the previous answer with no second call',
      () async {
        when(
          () => clients.searchClients('5145628'),
        ).thenAnswer((_) async => [marie, jp]);
        await readNotifier().searchClients('5145628');
        await readNotifier().searchClients('5145628332');
        verify(() => clients.searchClients('5145628')).called(1);
        verifyNever(() => clients.searchClients('5145628332'));
        expect(readState().clientResults, [marie]);
      },
    );

    // F5
    test('a truncated answer is re-queried rather than narrowed', () async {
      final full = List.generate(
        25,
        (i) => ClientRecord(id: 'c$i', name: '514562$i', phone: '514562$i'),
      );
      when(
        () => clients.searchClients('5145628'),
      ).thenAnswer((_) async => full);
      when(
        () => clients.searchClients('5145628332'),
      ).thenAnswer((_) async => [marie]);
      await readNotifier().searchClients('5145628');
      await readNotifier().searchClients('5145628332');
      verify(() => clients.searchClients('5145628332')).called(1);
    });

    test('a miss at ten digits falls back to the first seven', () async {
      when(
        () => clients.searchClients('5145628233'),
      ).thenAnswer((_) async => []);
      when(
        () => clients.searchClients('5145628'),
      ).thenAnswer((_) async => [marie]);
      await readNotifier().searchClients('5145628233');
      expect(readState().clientResults, [marie]);
      expect(readState().clientSearchStatus.answeredRung, PhoneRung.firstSeven);
      expect(readState().clientSearchStatus.isFallback, isTrue);
    });

    test('a miss on both seven-digit rungs leaves an honest empty', () async {
      when(() => clients.searchClients(any())).thenAnswer((_) async => []);
      await readNotifier().searchClients('5145628233');
      expect(readState().clientResults, isEmpty);
      expect(readState().clientSearchStatus.failed, isFalse);
      expect(readState().clientSearchStatus.answeredRung, isNull);
    });

    test('a thrown search is flagged as failed, not as empty', () async {
      when(() => clients.searchClients(any())).thenThrow(Exception('boom'));
      await readNotifier().searchClients('5145628332');
      expect(readState().clientSearchStatus.failed, isTrue);
      expect(readState().isSearchingClient, isFalse);
    });

    test(
      'starting a new search clears the previous rows immediately',
      () async {
        when(
          () => clients.searchClients('5145628'),
        ).thenAnswer((_) async => [marie]);
        await readNotifier().searchClients('5145628');
        expect(readState().clientResults, isNotEmpty);

        final gate = Completer<List<ClientRecord>>();
        when(
          () => clients.searchClients('4385551'),
        ).thenAnswer((_) => gate.future);
        final pending = readNotifier().searchClients('4385551');
        expect(
          readState().clientResults,
          isEmpty,
          reason: 'stale rows must not stay tappable behind the spinner',
        );
        expect(readState().isSearchingClient, isTrue);
        gate.complete([jp]);
        await pending;
        expect(readState().clientResults, [jp]);
      },
    );
  });

  group('selectClient', () {
    test('picking a normal client leaves the address in client mode', () {
      readNotifier().selectClient(_aClient);
      expect(readState().selectedClient, _aClient);
      expect(readState().clientResults, isEmpty);
      // _aClient has a real address, so the custom-address toggle stays off.
      expect(readState().useCustomAddress, isFalse);
    });

    test('picking a no-fixed-address client seeds the custom address on', () {
      const nomad = ClientRecord(
        id: 'c9',
        name: 'Nomad',
        phone: '555-0009',
        noFixedAddress: true,
      );
      readNotifier().selectClient(nomad);
      expect(readState().useCustomAddress, isTrue);
    });

    test('picking a client with a blank address seeds custom address on', () {
      const blank = ClientRecord(
        id: 'c8',
        name: 'Blank',
        phone: '555-0008',
        address: '   ',
      );
      readNotifier().selectClient(blank);
      expect(readState().useCustomAddress, isTrue);
    });
  });

  group('submit', () {
    test(
      'returns AddEventInvalid and populates errors on empty form',
      () async {
        final outcome = await readNotifier().submit(
          title: '',
          address: '',
          notes: '',
          materialsNeeded: '',
        );
        expect(outcome, isA<AddEventInvalid>());
        expect(
          readState().errors.keys,
          containsAll(['title', 'client', 'employees']),
        );
        verifyNever(() => appointments.addAppointment(any()));
      },
    );

    test(
      'returns AddEventBusyEmployees when busy check finds conflicts',
      () async {
        when(
          () => appointments.findBusyEmployees(
            candidates: any(named: 'candidates'),
            start: any(named: 'start'),
            end: any(named: 'end'),
          ),
        ).thenAnswer((_) async => const [_employeeA]);

        final c = readNotifier();
        fillValid(c);

        final outcome = await c.submit(
          title: 'Leak fix',
          address: '999 Maple',
          notes: '',
          materialsNeeded: '',
        );

        expect(outcome, isA<AddEventBusyEmployees>());
        verifyNever(() => appointments.addAppointment(any()));
      },
    );

    test('a PERSONAL save never returns the busy outcome — the clash alert '
        'handles it after the write', () async {
      // Both would fire otherwise, giving two dialogs about the same clash
      // back to back.
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      ).thenAnswer((_) async => const [_employeeA]);

      final c = readNotifier();
      fillValid(c);
      c.setPersonal(value: true);

      final outcome = await c.submit(
        title: 'Dentist',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<AddEventSubmitted>());
      verifyNever(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      );
      verify(() => appointments.addAppointment(any())).called(1);
    });

    test(
      'waits for local photo handoff before reporting the created appointment',
      () async {
        final controller = readNotifier();
        fillValid(controller);
        controller.addImages([File('picked.jpg')]);
        final entered = Completer<void>();
        final handoff = Completer<void>();
        when(
          () => uploader.enqueuePhotos(
            appointmentId: any(named: 'appointmentId'),
            newImages: any(named: 'newImages'),
          ),
        ).thenAnswer((_) {
          entered.complete();
          return handoff.future;
        });
        var completed = false;
        final saving = controller
            .submit(
              title: 'Leak fix',
              address: '1 Main St',
              notes: '',
              materialsNeeded: '',
            )
            .then((outcome) {
              completed = true;
              return outcome;
            });
        await entered.future;
        expect(completed, isFalse);
        verify(() => appointments.addAppointment(any())).called(1);

        handoff.complete();

        expect(await saving, isA<AddEventSubmitted>());
      },
    );

    test('writes appointment and kicks off photo upload on success', () async {
      final c = readNotifier();
      fillValid(c);

      final outcome = await c.submit(
        title: '  Leak fix  ',
        address: ' 999 Maple ',
        notes: ' bring towels ',
        materialsNeeded: ' wrench ',
      );

      expect(outcome, isA<AddEventSubmitted>());
      final saved = (outcome as AddEventSubmitted).appointment;
      expect(saved.id, 'appt-1');
      expect(saved.title, 'Leak fix');
      expect(saved.address, '999 Maple');
      expect(saved.notes, 'bring towels');
      expect(saved.materialsNeeded, 'wrench');
      expect(saved.clientId, _aClient.id);
      expect(saved.employeeIds, [_employeeA.id]);
      expect(saved.status, 'pending');

      verify(() => appointments.addAppointment(any())).called(1);
      // No images were selected, so the uploader should never run.
      verifyNever(
        () => uploader.enqueuePhotos(
          appointmentId: any(named: 'appointmentId'),
          newImages: any(named: 'newImages'),
        ),
      );
    });

    test('a personal job saves with no client, all day', () async {
      final c = readNotifier()
        ..selectDate(DateTime(2026, 5, 10))
        ..selectClient(_aClient)
        ..setPersonal(value: true)
        ..toggleEmployee(_employeeA);

      // No times were picked, so the block runs the whole day.
      expect(readState().isAllDay, isTrue);
      expect(readState().selectedClient, isNull);

      final outcome = await c.submit(
        title: 'Dentist',
        // The address field stays on screen for a personal job, so what it
        // holds is saved rather than dropped.
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<AddEventSubmitted>());
      final saved = (outcome as AddEventSubmitted).appointment;
      expect(saved.isPersonal, isTrue);
      expect(saved.isAllDay, isTrue);
      expect(saved.clientId, isEmpty);
      expect(saved.clientName, isEmpty);
      expect(saved.address, '999 Maple');
      expect(saved.startTime, DateTime(2026, 5, 10));
      expect(saved.endTime, DateTime(2026, 5, 10, 23, 59));
      expect(saved.status, 'pending');
    });

    test('a personal job with times keeps them', () async {
      final c = readNotifier()
        ..selectDate(DateTime(2026, 5, 10))
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..setPersonal(value: true)
        ..toggleEmployee(_employeeA);

      // A time was already picked, so it does not silently become all-day.
      expect(readState().isAllDay, isFalse);

      final outcome = await c.submit(
        title: 'Dentist',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      final saved = (outcome as AddEventSubmitted).appointment;
      expect(saved.isAllDay, isFalse);
      expect(saved.startTime, DateTime(2026, 5, 10, 9));
    });

    test(
      'turning Personal on with no times picked still defaults to all-day',
      () {
        readNotifier().setPersonal(value: true);
        expect(readState().isAllDay, isTrue);
      },
    );

    test('turning Personal off KEEPS an explicitly set all-day', () {
      // Retired invariant: all-day used to be personal-only, so turning
      // Personal off cleared it.
      readNotifier()
        ..setPersonal(value: true)
        ..setAllDay(value: true)
        ..setPersonal(value: false);
      expect(readState().isAllDay, isTrue);
    });

    test('a day off saves as time off and never as a job', () async {
      final c = readNotifier()
        ..selectDate(DateTime(2026, 5, 10))
        ..setPersonal(value: true)
        ..setDayOff(value: true)
        ..toggleEmployee(_employeeA);

      final outcome = await c.submit(
        title: 'Vacation',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      final saved = (outcome as AddEventSubmitted).appointment;
      expect(saved.isDayOff, isTrue);
      expect(saved.isTimeOff, isTrue);
    });

    test(
      'ticking Day off forces all-day, so Save can never go inert',
      () async {
        // The form hides BOTH the all-day switch and the time rows behind
        // `isDayOff`, while the validator demands times whenever `!isAllDay`.
        final c = readNotifier()
          ..selectDate(DateTime(2026, 5, 10))
          ..setPersonal(value: true)
          ..setAllDay(value: false)
          ..setDayOff(value: true)
          ..toggleEmployee(_employeeA);

        expect(readState().isAllDay, isTrue);

        final outcome = await c.submit(
          title: 'Vacation',
          address: '',
          notes: '',
          materialsNeeded: '',
        );
        expect(outcome, isA<AddEventSubmitted>());
      },
    );

    test(
      'a day off picked after times is still all-day, never timed',
      () async {
        // The other half of the same hole: times chosen FIRST leave
        // `setPersonal` with nothing to default, so a timed day off used to be
        // storable — and `selectTravelCandidates` skips on `isAllDay` alone, so
        // it fired a "time to leave" push on somebody's day off.
        final c = readNotifier()
          ..selectDate(DateTime(2026, 5, 10))
          ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
          ..selectEndTime(const TimeOfDay(hour: 17, minute: 0))
          ..setPersonal(value: true)
          ..setDayOff(value: true)
          ..toggleEmployee(_employeeA);

        expect(readState().isAllDay, isTrue);

        final outcome = await c.submit(
          title: 'Vacation',
          address: '',
          notes: '',
          materialsNeeded: '',
        );
        final saved = (outcome as AddEventSubmitted).appointment;
        expect(saved.isAllDay, isTrue);
      },
    );

    test(
      'a day off drops a typed address rather than storing it unseen',
      () async {
        // The address field is dropped from the form on a day off, so a value
        // typed before the chip was ticked would be stored where no surface
        // renders it.
        final c = readNotifier()
          ..selectDate(DateTime(2026, 5, 10))
          ..setPersonal(value: true)
          ..setDayOff(value: true)
          ..toggleEmployee(_employeeA);

        final outcome = await c.submit(
          title: 'Vacation',
          address: '123 Rue Principale',
          notes: '',
          materialsNeeded: '',
        );
        expect((outcome as AddEventSubmitted).appointment.address, isEmpty);
      },
    );

    test('a double-tapped submit returns Busy, not Invalid', () async {
      // Both are no-ops at the call site, which is exactly why the difference
      // has to live in the type: a skipped write reported as `Invalid` is
      // indistinguishable from a form that failed validation.
      final gate = Completer<void>();
      when(
        () => appointments.addAppointment(any()),
      ).thenAnswer((_) => gate.future);

      final c = readNotifier()
        ..selectDate(DateTime(2026, 5, 10))
        ..setAllDay(value: true)
        ..selectClient(_aClient)
        ..toggleEmployee(_employeeA);

      final first = c.submit(
        title: 'Job',
        address: '1 Main',
        notes: '',
        materialsNeeded: '',
      );
      final second = await c.submit(
        title: 'Job',
        address: '1 Main',
        notes: '',
        materialsNeeded: '',
      );

      expect(second, isA<AddEventBusy>());
      gate.complete();
      await first;
      verify(() => appointments.addAppointment(any())).called(1);
    });

    test('turning Personal off clears the day-off flag', () {
      // The chip is hidden with the switch, so a surviving flag would be
      // unreachable — and would drop a real client job out of every count.
      readNotifier()
        ..setPersonal(value: true)
        ..setDayOff(value: true)
        ..setPersonal(value: false);
      expect(readState().isDayOff, isFalse);
    });

    test('turning a draft personal clears a chosen repeat', () async {
      readNotifier()
        ..selectRepeat(RepeatInterval.oneYear)
        ..setPersonal(value: true);
      expect(readState().repeat, RepeatInterval.none);
    });

    test('widening the span past a day clears a chosen repeat', () async {
      // The picker is hidden once the span exceeds a day, so a rule chosen
      // while the draft was single-day would otherwise stay in state: submit
      // books NO copies for a run yet stamps the rule on every day document,
      // producing a repeat that silently does nothing on records that then read
      // as both a run and a series.
      readNotifier()
        ..selectDate(DateTime(2026, 8, 3))
        ..selectRepeat(RepeatInterval.fourMonths)
        ..selectEndDate(DateTime(2026, 8, 5));
      expect(readState().repeat, RepeatInterval.none);
    });

    test('a single-day span keeps the chosen repeat', () async {
      readNotifier()
        ..selectDate(DateTime(2026, 8, 3))
        ..selectRepeat(RepeatInterval.fourMonths)
        ..selectEndDate(DateTime(2026, 8, 3));
      expect(readState().repeat, RepeatInterval.fourMonths);
    });

    test('moving the START date so the span widens also clears it', () async {
      // selectDate carries the touched end date along, so it can widen the span
      // just as selectEndDate can.
      readNotifier()
        ..selectDate(DateTime(2026, 8, 3))
        ..selectEndDate(DateTime(2026, 8, 3))
        ..selectRepeat(RepeatInterval.fourMonths);
      expect(readState().repeat, RepeatInterval.fourMonths);
      readNotifier().selectEndDate(DateTime(2026, 8, 6));
      expect(readState().repeat, RepeatInterval.none);
    });

    test('skips busy check on forceBusy and writes the appointment', () async {
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      ).thenAnswer((_) async => const [_employeeA]);

      final c = readNotifier();
      fillValid(c);

      final outcome = await c.submit(
        title: 'Leak fix',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
        forceBusy: true,
      );

      expect(outcome, isA<AddEventSubmitted>());
      verifyNever(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      );
      verify(() => appointments.addAppointment(any())).called(1);
    });

    test('books repeat occurrences atomically with the appointment', () async {
      var nextId = 0;
      when(appointments.newDocId).thenAnswer((_) => 'appt-${++nextId}');
      when(() => appointments.addAppointments(any())).thenAnswer((_) async {});

      final c = readNotifier();
      fillValid(c);
      c.selectRepeat(RepeatInterval.fourMonths);

      final outcome = await c.submit(
        title: 'Furnace check',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<AddEventSubmitted>());
      // A 60-month horizon at every 4 months works out to 15 future visits,
      // spread across five years.
      expect((outcome as AddEventSubmitted).futureBookings, 15);

      final captured = verify(
        () => appointments.addAppointments(captureAny()),
      ).captured.single;
      final series = (captured as List).cast<AppointmentRecord>();
      expect(series, hasLength(16));
      expect(series.map((a) => a.id).toSet(), hasLength(16));
      expect(series[1].startTime, DateTime(2026, 9, 10, 9));
      expect(series[3].startTime, DateTime(2027, 5, 10, 9));
      expect(series[3].endTime, DateTime(2027, 5, 10, 10));
      expect(series.last.startTime, DateTime(2031, 5, 10, 9));
      expect(series.every((a) => a.status == 'pending'), isTrue);
      // Every visit in the series stores the rule, like a real calendar.
      expect(
        series.every((a) => a.repeat == RepeatInterval.fourMonths),
        isTrue,
      );
      // …and shares the series key (the first visit's doc id).
      expect(series.every((a) => a.seriesId == 'appt-1'), isTrue);
      verifyNever(() => appointments.addAppointment(any()));
    });

    test('checks repeat copies and reports a future conflict', () async {
      var nextId = 0;
      when(appointments.newDocId).thenAnswer((_) => 'appt-${++nextId}');
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      ).thenAnswer((invocation) async {
        final start = invocation.namedArguments[#start] as DateTime;
        return start == DateTime(2026, 9, 10, 9)
            ? const [_employeeA]
            : const <EmployeeRecord>[];
      });

      final c = readNotifier();
      fillValid(c);
      c.selectRepeat(RepeatInterval.fourMonths);

      final outcome = await c.submit(
        title: 'Furnace check',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<AddEventBusyEmployees>());
      final busy = outcome as AddEventBusyEmployees;
      expect(busy.busyEmployees, const [_employeeA]);
      expect(busy.start, DateTime(2026, 9, 10, 9));
      expect(busy.end, DateTime(2026, 9, 10, 10));
      verifyNever(() => appointments.addAppointment(any()));
      verifyNever(() => appointments.addAppointments(any()));
    });

    test(
      'returns AddEventFailed and resets isSubmitting when repo throws',
      () async {
        when(
          () => appointments.addAppointment(any()),
        ).thenThrow(Exception('boom'));

        final c = readNotifier();
        fillValid(c);

        final outcome = await c.submit(
          title: 'Leak fix',
          address: '999 Maple',
          notes: '',
          materialsNeeded: '',
        );

        expect(outcome, isA<AddEventFailed>());
        expect(readState().isSubmitting, isFalse);
      },
    );

    test('a lease gone stale before the write returns Busy and frees '
        'isSubmitting', () async {
      var current = true;
      when(() => appointments.captureWriteOwner()).thenReturn(() => current);
      when(
        () => appointments.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
        ),
      ).thenAnswer((_) async {
        current = false;
        return const [];
      });

      final c = readNotifier();
      fillValid(c);
      final outcome = await c.submit(
        title: 'Leak fix',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<AddEventBusy>());
      expect(readState().isSubmitting, isFalse);
      verifyNever(() => appointments.addAppointment(any()));
    });

    test('a lease gone stale after the write returns Busy and frees '
        'isSubmitting', () async {
      var current = true;
      when(() => appointments.captureWriteOwner()).thenReturn(() => current);
      when(() => appointments.addAppointment(any())).thenAnswer((_) async {
        current = false;
      });

      final c = readNotifier();
      fillValid(c);
      final outcome = await c.submit(
        title: 'Leak fix',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
        forceBusy: true,
      );

      expect(outcome, isA<AddEventBusy>());
      expect(readState().isSubmitting, isFalse);
    });

    test(
      'offline fails fast without touching the repo or the busy flag',
      () async {
        final offline = ProviderContainer(
          overrides: [
            appointmentsRepositoryProvider.overrideWithValue(appointments),
            clientsRepositoryProvider.overrideWithValue(clients),
            appointmentImageUploadProvider.overrideWithValue(uploader),
            isOfflineProvider.overrideWithValue(true),
          ],
        );
        addTearDown(offline.dispose);
        final c = offline.read(addEventControllerProvider(null).notifier)
          ..selectDate(DateTime(2026, 5, 10))
          ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
          ..selectEndTime(const TimeOfDay(hour: 10, minute: 0))
          ..selectClient(_aClient)
          ..toggleEmployee(_employeeA);

        final outcome = await c.submit(
          title: 'Leak fix',
          address: '999 Maple',
          notes: '',
          materialsNeeded: '',
        );

        expect(outcome, isA<AddEventFailed>());
        expect((outcome as AddEventFailed).error, isA<SocketException>());
        verifyNever(() => appointments.addAppointment(any()));
        verifyNever(
          () => appointments.findBusyEmployees(
            candidates: any(named: 'candidates'),
            start: any(named: 'start'),
            end: any(named: 'end'),
          ),
        );
        expect(
          offline.read(addEventControllerProvider(null)).isSubmitting,
          isFalse,
        );
      },
    );
  });

  group('multi-day runs', () {
    test('a 3-day job writes three linked one-day documents', () async {
      var nextId = 0;
      when(appointments.newDocId).thenAnswer((_) => 'appt-${++nextId}');
      when(() => appointments.addAppointments(any())).thenAnswer((_) async {});

      final c = readNotifier();
      fillValid(c);
      c.selectEndDate(DateTime(2026, 5, 12));

      final outcome = await c.submit(
        title: 'Repipe',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
      );

      expect(outcome, isA<AddEventSubmitted>());
      // A run's later days are NOT repeat occurrences: `futureBookings` counts
      // repeat copies only, and the run's length is reported separately.
      expect((outcome as AddEventSubmitted).futureBookings, 0);
      expect(outcome.runDays, 3);

      final captured = verify(
        () => appointments.addAppointments(captureAny()),
      ).captured.single;
      final run = (captured as List).cast<AppointmentRecord>();
      expect(run, hasLength(3));
      expect(run.map((a) => a.id).toSet(), hasLength(3));

      final runId = run.first.id;
      for (var i = 0; i < 3; i++) {
        expect(run[i].seriesId, runId, reason: 'every day shares the run id');
        expect(run[i].dayIndex, i + 1);
        expect(run[i].dayCount, 3);
        expect(run[i].startTime, DateTime(2026, 5, 10 + i, 9));
        expect(run[i].endTime, DateTime(2026, 5, 10 + i, 10));
        expect(run[i].status, 'pending');
      }
    });

    test('a one-day job still writes a single unlinked document', () async {
      final c = readNotifier();
      fillValid(c);

      await c.submit(
        title: 'Leak',
        address: '999 Maple',
        notes: '',
        materialsNeeded: '',
      );

      final captured =
          verify(
                () => appointments.addAppointment(captureAny()),
              ).captured.single
              as AppointmentRecord;
      expect(captured.seriesId, '');
      expect(captured.dayIndex, 0);
      expect(captured.dayCount, 0);
    });

    test('a multi-day PERSONAL block stays one wide document', () async {
      // Times first: setPersonal defaults an as-yet-untimed block to all-day.
      final c = readNotifier()
        ..selectDate(DateTime(2026, 5, 10))
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 10, minute: 0))
        ..setPersonal(value: true)
        ..toggleEmployee(_employeeA)
        ..selectEndDate(DateTime(2026, 5, 14));

      await c.submit(
        title: 'Vacation',
        address: '',
        notes: '',
        materialsNeeded: '',
      );

      final captured =
          verify(
                () => appointments.addAppointment(captureAny()),
              ).captured.single
              as AppointmentRecord;
      expect(captured.startTime, DateTime(2026, 5, 10, 9));
      expect(captured.endTime, DateTime(2026, 5, 14, 10));
      expect(captured.dayCount, 0);
    });
  });

  group('setDurationMinutes', () {
    test('a seeded length lands the end after a later-picked start', () {
      readNotifier()
        ..setDurationMinutes(90)
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0));
      expect(
        readState().selectedEndTime,
        const TimeOfDay(hour: 10, minute: 30),
      );
    });

    test('clamps inside the day', () {
      readNotifier()
        ..setDurationMinutes(90)
        ..selectStartTime(const TimeOfDay(hour: 23, minute: 0));
      expect(
        readState().selectedEndTime,
        const TimeOfDay(hour: 23, minute: 59),
      );
    });

    test('re-seeds an end already derived from a picked start', () {
      readNotifier()
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..setDurationMinutes(120);
      expect(readState().selectedEndTime, const TimeOfDay(hour: 11, minute: 0));
    });

    test('the seeded end keeps following a later start change', () {
      readNotifier()
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..setDurationMinutes(30)
        ..selectStartTime(const TimeOfDay(hour: 11, minute: 0));
      expect(
        readState().selectedEndTime,
        const TimeOfDay(hour: 11, minute: 30),
      );
    });

    test('seeding over a manual end pick re-owns the end', () {
      readNotifier()
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 14, minute: 0))
        ..setDurationMinutes(30)
        ..selectStartTime(const TimeOfDay(hour: 11, minute: 0));
      expect(
        readState().selectedEndTime,
        const TimeOfDay(hour: 11, minute: 30),
      );
    });

    test('a manual end pick after the seed still wins', () {
      readNotifier()
        ..setDurationMinutes(30)
        ..selectStartTime(const TimeOfDay(hour: 9, minute: 0))
        ..selectEndTime(const TimeOfDay(hour: 14, minute: 0))
        ..selectStartTime(const TimeOfDay(hour: 11, minute: 0));
      expect(readState().selectedEndTime, const TimeOfDay(hour: 14, minute: 0));
    });
  });

  group('applyPrefill', () {
    test('seeds the client, the address mode and the job length', () async {
      await readNotifier().applyPrefill(
        const AppointmentPrefill(
          client: _aClient,
          useCustomAddress: true,
          durationMinutes: 90,
        ),
      );
      final state = readState();
      expect(state.selectedClient, _aClient);
      expect(state.useCustomAddress, isTrue);
      expect(state.durationMinutes, 90);
    });

    test(
      'a client-only prefill leaves the address mode to selectClient',
      () async {
        await readNotifier().applyPrefill(
          const AppointmentPrefill(client: _aClient),
        );
        expect(readState().useCustomAddress, isFalse);
      },
    );

    test(
      'a client with no address is custom whatever the prefill says',
      () async {
        await readNotifier().applyPrefill(
          AppointmentPrefill(client: _aClient.copyWith(address: '')),
        );
        expect(readState().useCustomAddress, isTrue);
      },
    );

    test('carries only the crew still assignable', () async {
      // e3 is a dispatcher and e9 is no longer on the roster.
      await readNotifier().applyPrefill(
        const AppointmentPrefill(employeeIds: ['e1', 'e3', 'e9']),
      );
      expect(readState().selectedEmployees, const [_employeeA]);
    });

    test('a book-again write carries nothing of the source visit', () async {
      // Every field that belongs to the visit itself set non-default; the
      // written duplicate must equal a bare record built from the carried
      // fields plus the newly picked when.
      final source = AppointmentRecord(
        id: 'appt-old',
        title: 'Water heater',
        startTime: DateTime(2026, 5, 10, 9),
        endTime: DateTime(2026, 5, 10, 10, 30),
        clientId: 'c1',
        clientName: 'Jane Doe',
        clientPhone: '555-0001',
        employeeIds: const ['e1', 'e2', 'e9'],
        employeeNames: const ['Alex', 'Bea', 'Gone'],
        address: '99 Other Rd',
        notes: 'Gate code 4821',
        fieldNotes: 'Replaced the anode rod',
        materialsNeeded: 'anode rod',
        status: 'done',
        repeat: RepeatInterval.sixMonths,
        seriesId: 'appt-old',
        dayIndex: 2,
        dayCount: 3,
        createdAt: DateTime(2026, 5),
        updatedAt: DateTime(2026, 5, 10, 12),
        pictureCount: 3,
        startedAt: DateTime(2026, 5, 10, 9, 5),
        completedAt: DateTime(2026, 5, 10, 10, 40),
      );
      final prefill = AppointmentPrefill.bookAgain(source, client: _aClient);
      final c = readNotifier();
      await c.applyPrefill(prefill);
      c
        ..selectDate(DateTime(2026, 6))
        ..selectStartTime(const TimeOfDay(hour: 13, minute: 0));

      // The sheet hands its text fields back exactly as seeded.
      final outcome = await c.submit(
        title: prefill.title,
        address: prefill.address,
        notes: prefill.notes,
        materialsNeeded: prefill.materialsNeeded,
      );

      expect(outcome, isA<AddEventSubmitted>());
      final written =
          verify(
                () => appointments.addAppointment(captureAny()),
              ).captured.single
              as AppointmentRecord;
      expect(
        written,
        AppointmentRecord(
          id: 'appt-1',
          title: 'Water heater',
          startTime: DateTime(2026, 6, 1, 13),
          endTime: DateTime(2026, 6, 1, 14, 30),
          clientId: 'c1',
          clientName: _aClient.displayName,
          clientPhone: '555-0001',
          employeeIds: const ['e1', 'e2'],
          employeeNames: const ['Alex', 'Bea'],
          address: '99 Other Rd',
          notes: 'Gate code 4821',
          materialsNeeded: 'anode rod',
        ),
      );
    });
  });
}
