import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/calendar_failure.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

typedef AppointmentConflictHit = ({
  List<EmployeeRecord> busyEmployees,
  DateTime start,
  DateTime end,
});

/// The save's busy refusal as the hit the double-booking dialog renders.
///
/// Ids resolve against [candidates] first, then positionally against the
/// records being written — a retained assignee the picker can't show is still
/// named rather than dropped.
AppointmentConflictHit conflictHitOf(
  CalendarFailureEmployeesBusy busy, {
  required List<EmployeeRecord> candidates,
  Iterable<AppointmentRecord> bookings = const [],
}) {
  final byId = {for (final employee in candidates) employee.id: employee};
  for (final record in bookings) {
    for (var i = 0; i < record.employeeIds.length; i++) {
      final id = record.employeeIds[i];
      byId.putIfAbsent(
        id,
        () => EmployeeRecord(
          id: id,
          name: assigneeNameAt(record.employeeNames, i) ?? '',
        ),
      );
    }
  }
  return (
    busyEmployees: [for (final id in busy.busyEmployeeIds) ?byId[id]],
    start: busy.start,
    end: busy.end,
  );
}
