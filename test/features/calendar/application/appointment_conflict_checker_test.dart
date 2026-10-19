import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/application/appointment_conflict_checker.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

class _MockRepo extends Mock implements AppointmentsRepository {}

EmployeeRecord _emp(String id) => EmployeeRecord(id: id, firstName: id);

AppointmentRecord _appt({
  required String id,
  required DateTime start,
  List<String> employeeIds = const [],
}) => AppointmentRecord(
  id: id,
  startTime: start,
  endTime: start.add(const Duration(hours: 1)),
  employeeIds: employeeIds,
);

void main() {
  setUpAll(() {
    registerFallbackValue(<EmployeeRecord>[]);
    registerFallbackValue(<String>[]);
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(<AppointmentRecord>[]);
    registerFallbackValue(<String>{});
  });

  late _MockRepo repo;
  final marc = _emp('marc');
  final nadia = _emp('nadia');
  final day1 = DateTime(2026, 8, 3, 9);
  final day2 = DateTime(2026, 8, 4, 9);
  final day3 = DateTime(2026, 8, 5, 9);

  setUp(() {
    repo = _MockRepo();
  });

  void stubBusy(List<EmployeeRecord> Function(DateTime start) answer) {
    when(
      () => repo.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).thenAnswer((i) async => answer(i.namedArguments[#start] as DateTime));
  }

  void stubClashes(List<AppointmentRecord> clashes) {
    when(
      () => repo.findClashingAppointments(
        employeeIds: any(named: 'employeeIds'),
        start: any(named: 'start'),
        end: any(named: 'end'),
      ),
    ).thenAnswer((_) async => clashes);
  }

  test(
    'batch results retain first-conflict order and avoid per-booking calls',
    () async {
      when(
        () => repo.findBusyEmployeeIdsForBookings(
          employeeIds: any(named: 'employeeIds'),
          bookings: any(named: 'bookings'),
          excludeAppointmentIds: any(named: 'excludeAppointmentIds'),
          excludeOwnBookingIds: any(named: 'excludeOwnBookingIds'),
        ),
      ).thenAnswer(
        (_) async => [
          <String>{},
          {'nadia'},
          {'marc'},
        ],
      );
      final result = await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc, nadia],
        bookings: [
          _appt(id: 'one', start: day1),
          _appt(id: 'two', start: day2),
          _appt(id: 'three', start: day3),
        ],
      );
      expect(result!.start, day2);
      expect(result.busyEmployees, [nadia]);
      verifyNever(
        () => repo.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: any(named: 'excludeAppointmentId'),
        ),
      );
    },
  );

  test('no candidates never touches the repository', () async {
    final hit = await findFirstAppointmentConflict(
      repo: repo,
      candidates: const [],
      bookings: [_appt(id: 'a', start: day1)],
    );
    expect(hit, isNull);
    verifyNever(
      () => repo.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    );
  });

  test(
    'reports the FIRST clashing window, not whichever answered first',
    () async {
      // Every booking is checked in parallel now, so the ordered read-back is
      // the only thing keeping "first" meaningful.
      stubBusy((start) => start == day1 ? const [] : [marc]);
      final hit = await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc, nadia],
        bookings: [
          _appt(id: 'a', start: day1),
          _appt(id: 'b', start: day2),
          _appt(id: 'c', start: day3),
        ],
      );
      expect(hit, isNotNull);
      expect(hit!.start, day2);
      expect(hit.busyEmployees, [marc]);
    },
  );

  test('checks every booking of a run', () async {
    stubBusy((_) => const []);
    final hit = await findFirstAppointmentConflict(
      repo: repo,
      candidates: [marc],
      bookings: [
        _appt(id: 'a', start: day1),
        _appt(id: 'b', start: day2),
        _appt(id: 'c', start: day3),
      ],
    );
    expect(hit, isNull);
    verify(
      () => repo.findBusyEmployees(
        candidates: any(named: 'candidates'),
        start: any(named: 'start'),
        end: any(named: 'end'),
        excludeAppointmentId: any(named: 'excludeAppointmentId'),
      ),
    ).called(3);
  });

  test(
    'one exclusion routes to findBusyEmployees with excludeAppointmentId',
    () async {
      stubBusy((_) => const []);
      await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc],
        bookings: [_appt(id: 'own', start: day1)],
        excludeOwnBookingIds: true,
      );
      verify(
        () => repo.findBusyEmployees(
          candidates: any(named: 'candidates'),
          start: any(named: 'start'),
          end: any(named: 'end'),
          excludeAppointmentId: 'own',
        ),
      ).called(1);
    },
  );

  group('two or more exclusions', () {
    // Reached only from a series rewrite with 2+ future siblings. The
    // occurrences about to be DELETED must not report their own assignees as
    // busy, or a legitimate rewrite becomes unreachable.
    test('drops clashes whose id is in the exclusion set', () async {
      stubClashes([
        _appt(id: 'doomed1', start: day1, employeeIds: const ['marc']),
        _appt(id: 'doomed2', start: day1, employeeIds: const ['nadia']),
      ]);
      final hit = await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc, nadia],
        bookings: [_appt(id: 'own', start: day1)],
        excludeAppointmentIds: const {'doomed1', 'doomed2'},
      );
      expect(hit, isNull);
    });

    test('a clash outside the exclusion set still surfaces', () async {
      stubClashes([
        _appt(id: 'doomed1', start: day1, employeeIds: const ['marc']),
        _appt(id: 'other', start: day1, employeeIds: const ['nadia']),
      ]);
      final hit = await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc, nadia],
        bookings: [_appt(id: 'own', start: day1)],
        excludeAppointmentIds: const {'doomed1', 'doomed2'},
      );
      expect(hit, isNotNull);
      expect(hit!.busyEmployees, [nadia]);
    });

    test('a clash with a null id is KEPT - it cannot be excluded', () async {
      stubClashes([
        AppointmentRecord(
          startTime: day1,
          endTime: day1.add(const Duration(hours: 1)),
          employeeIds: const ['marc'],
        ),
      ]);
      final hit = await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc],
        bookings: [_appt(id: 'own', start: day1)],
        excludeAppointmentIds: const {'doomed1', 'doomed2'},
      );
      expect(hit, isNotNull);
      expect(hit!.busyEmployees, [marc]);
    });

    test(
      'only candidates are reported busy, never a stranger on the clash',
      () async {
        stubClashes([
          _appt(
            id: 'other',
            start: day1,
            employeeIds: const ['marc', 'someone-else'],
          ),
        ]);
        final hit = await findFirstAppointmentConflict(
          repo: repo,
          candidates: [marc],
          bookings: [_appt(id: 'own', start: day1)],
          excludeAppointmentIds: const {'a', 'b'},
        );
        expect(hit!.busyEmployees, [marc]);
      },
    );

    test('the own-booking id joins the exclusion set', () async {
      stubClashes([
        _appt(id: 'own', start: day1, employeeIds: const ['marc']),
      ]);
      final hit = await findFirstAppointmentConflict(
        repo: repo,
        candidates: [marc],
        bookings: [_appt(id: 'own', start: day1)],
        // One named exclusion + the own id = the two-exclusion branch.
        excludeAppointmentIds: const {'doomed1'},
        excludeOwnBookingIds: true,
      );
      expect(hit, isNull);
    });
  });
}
