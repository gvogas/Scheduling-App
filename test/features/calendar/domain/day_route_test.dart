import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/domain/day_route.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

final _day = DateTime(2026, 10, 14);

AppointmentRecord _job(
  String id, {
  required List<String> employeeIds,
  List<String> employeeNames = const [],
  int hour = 9,
}) => AppointmentRecord(
  id: id,
  title: id,
  startTime: DateTime(2026, 10, 14, hour),
  endTime: DateTime(2026, 10, 14, hour + 1),
  employeeIds: employeeIds,
  employeeNames: employeeNames,
);

DayRoute _build(
  List<AppointmentRecord> source, {
  Map<String, String> nameMap = const {},
  bool isAdmin = true,
  String selectedEmployeeId = '',
}) => buildDayRoute(
  source: source,
  nameMap: nameMap,
  day: _day,
  isAdmin: isAdmin,
  ownEmployeeId: 'me',
  selectedEmployeeId: selectedEmployeeId,
);

void main() {
  test('a pick with no work today falls back to the first assignee', () {
    final route = _build(
      [
        _job('a', employeeIds: const ['e2']),
        _job('b', employeeIds: const ['e1'], hour: 11),
      ],
      nameMap: const {'e1': 'Ann', 'e2': 'Zoe'},
      selectedEmployeeId: 'gone',
    );

    expect(route.employeeId, 'e1');
    expect([for (final s in route.jobs) s.appointment.id], ['b']);
  });

  test('a pick that still has work is kept', () {
    final route = _build(
      [
        _job('a', employeeIds: const ['e1']),
        _job('b', employeeIds: const ['e2']),
      ],
      nameMap: const {'e1': 'Ann', 'e2': 'Zoe'},
      selectedEmployeeId: 'e2',
    );

    expect(route.employeeId, 'e2');
  });

  test('a name off the roster falls back to the job, then the raw id', () {
    final route = _build([
      _job(
        'a',
        employeeIds: const ['e1', 'e2'],
        employeeNames: const ['Former Crew'],
      ),
    ]);

    expect(route.assigneeEntries, [
      isA<MapEntry<String, String>>()
          .having((e) => e.key, 'key', 'e2')
          .having((e) => e.value, 'value', 'e2'),
      isA<MapEntry<String, String>>()
          .having((e) => e.key, 'key', 'e1')
          .having((e) => e.value, 'value', 'Former Crew'),
    ]);
  });

  test('a technician gets their own id and no picker entries', () {
    final route = _build(
      [
        _job('a', employeeIds: const ['me']),
      ],
      isAdmin: false,
      selectedEmployeeId: 'e9',
    );

    expect(route.employeeId, 'me');
    expect(route.assigneeEntries, isEmpty);
  });
}
