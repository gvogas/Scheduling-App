import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/application/appointment_conflict_checker.dart';
import 'package:scheduling/features/calendar/domain/calendar_failure.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

void main() {
  final start = DateTime(2026, 8, 3, 9);
  final end = DateTime(2026, 8, 3, 10);
  const marc = EmployeeRecord(id: 'marc', name: 'Marc Picker');
  const nadia = EmployeeRecord(id: 'nadia', name: 'Nadia Picker');

  CalendarFailureEmployeesBusy busy(List<String> ids) =>
      CalendarFailureEmployeesBusy(busyEmployeeIds: ids, start: start, end: end);

  test('resolves busy ids against the candidates first', () {
    final hit = conflictHitOf(
      busy(const ['nadia']),
      candidates: const [marc, nadia],
      bookings: [
        AppointmentRecord(
          startTime: start,
          endTime: end,
          employeeIds: const ['nadia'],
          employeeNames: const ['Nadia Stored'],
        ),
      ],
    );
    expect(hit.busyEmployees, const [nadia]);
    expect((hit.start, hit.end), (start, end));
  });

  test('falls back to the booking positionally for a retained assignee', () {
    final hit = conflictHitOf(
      busy(const ['retained']),
      candidates: const [marc],
      bookings: [
        AppointmentRecord(
          startTime: start,
          endTime: end,
          employeeIds: const ['marc', 'retained'],
          employeeNames: const ['Marc', 'Retained Person'],
        ),
      ],
    );
    expect(hit.busyEmployees.map((e) => (e.id, e.name)), [
      ('retained', 'Retained Person'),
    ]);
  });

  test('drops an id neither the candidates nor the bookings know', () {
    final hit = conflictHitOf(busy(const ['stranger']), candidates: const [marc]);
    expect(hit.busyEmployees, isEmpty);
  });
}
