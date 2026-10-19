import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

typedef AppointmentConflictHit = ({
  List<EmployeeRecord> busyEmployees,
  DateTime start,
  DateTime end,
});

/// Finds the first planned booking window whose assignees already have work.
Future<AppointmentConflictHit?> findFirstAppointmentConflict({
  required AppointmentsRepository repo,
  required List<EmployeeRecord> candidates,
  required Iterable<AppointmentRecord> bookings,
  Set<String> excludeAppointmentIds = const {},
  bool excludeOwnBookingIds = false,
}) async {
  if (candidates.isEmpty) return null;

  // Checked in parallel, then read back in order. A run books one document per
  // day and a repeat rule up to fifteen copies, so awaiting each in turn made
  // one Save cost that many sequential round-trips; the reported window still
  // has to be the FIRST clashing one, which the ordered read back preserves.
  final planned = bookings.toList();
  final batch = planned.length < 2
      ? null
      : repo.findBusyEmployeeIdsForBookings(
          employeeIds: candidates.map((employee) => employee.id).toList(),
          bookings: planned,
          excludeAppointmentIds: excludeAppointmentIds,
          excludeOwnBookingIds: excludeOwnBookingIds,
        );
  final busyPerBooking = batch == null
      ? await Future.wait([
          for (final booking in planned)
            _findBusyEmployees(
              repo: repo,
              candidates: candidates,
              start: booking.startTime,
              end: booking.endTime,
              excludeAppointmentIds: {
                ...excludeAppointmentIds,
                if (excludeOwnBookingIds) ?booking.id,
              },
            ),
        ])
      : [
          for (final ids in await batch)
            candidates.where((employee) => ids.contains(employee.id)).toList(),
        ];
  if (busyPerBooking.length != planned.length) {
    throw const FormatException('Incomplete conflict batch response');
  }
  for (var i = 0; i < planned.length; i++) {
    final busy = busyPerBooking[i];
    if (busy.isEmpty) continue;
    return (
      busyEmployees: busy,
      start: planned[i].startTime,
      end: planned[i].endTime,
    );
  }
  return null;
}

Future<List<EmployeeRecord>> _findBusyEmployees({
  required AppointmentsRepository repo,
  required List<EmployeeRecord> candidates,
  required DateTime start,
  required DateTime end,
  required Set<String> excludeAppointmentIds,
}) {
  if (excludeAppointmentIds.isEmpty) {
    return repo.findBusyEmployees(
      candidates: candidates,
      start: start,
      end: end,
    );
  }
  if (excludeAppointmentIds.length == 1) {
    return repo.findBusyEmployees(
      candidates: candidates,
      start: start,
      end: end,
      excludeAppointmentId: excludeAppointmentIds.single,
    );
  }
  return _findBusyEmployeesWithExclusions(
    repo: repo,
    candidates: candidates,
    start: start,
    end: end,
    excludeAppointmentIds: excludeAppointmentIds,
  );
}

Future<List<EmployeeRecord>> _findBusyEmployeesWithExclusions({
  required AppointmentsRepository repo,
  required List<EmployeeRecord> candidates,
  required DateTime start,
  required DateTime end,
  required Set<String> excludeAppointmentIds,
}) async {
  final candidateIds = {for (final employee in candidates) employee.id};
  final clashes = await repo.findClashingAppointments(
    employeeIds: candidateIds.toList(),
    start: start,
    end: end,
  );
  final busyIds = <String>{};
  for (final clash in clashes) {
    final id = clash.id;
    if (id != null && excludeAppointmentIds.contains(id)) continue;
    busyIds.addAll(clash.employeeIds.where(candidateIds.contains));
  }
  return [
    for (final employee in candidates)
      if (busyIds.contains(employee.id)) employee,
  ];
}
