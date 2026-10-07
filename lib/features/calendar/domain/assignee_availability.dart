import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// Assignee clash details shown by the picker.
class AssigneeAvailability {
  const AssigneeAvailability({
    this.clashes = const {},
    this.alreadyAssignedIds = const {},
  });

  /// No date picked yet, or the lookup hasn't settled: nothing is dimmed.
  static const none = AssigneeAvailability();

  /// One blocking appointment per employee id.
  final Map<String, AppointmentRecord> clashes;

  /// Stored assignees that remain tappable even when clashing.
  final Set<String> alreadyAssignedIds;
}

/// Returns appointments that block a proposed [start]-[end] job window.
List<AppointmentRecord> clashingAppointments({
  required Iterable<AppointmentRecord> appointments,
  required DateTime start,
  required DateTime end,
  String? excludeAppointmentId,
  bool clientJobsOnly = false,
  Set<String> windowUnknownIds = const {},
}) {
  return [
    for (final a in appointments)
      if (a.id != excludeAppointmentId &&
          !isTerminalStatusRaw(a.status) &&
          !(clientJobsOnly && a.isPersonal) &&
          (windowUnknownIds.contains(a.id) ||
              dailyWindowsOverlap(
                aStart: a.startTime,
                aEnd: a.endTime,
                bStart: start,
                bEnd: end,
              )))
        a,
  ];
}

/// Returns one preferred clash per assignee.
Map<String, AppointmentRecord> clashesByAssignee({
  required Iterable<AppointmentRecord> clashes,
  required Iterable<String> employeeIds,
}) {
  final wanted = employeeIds.toSet();
  final byAssignee = <String, AppointmentRecord>{};
  for (final appointment in clashes) {
    for (final id in appointment.employeeIds) {
      if (!wanted.contains(id)) continue;
      final existing = byAssignee[id];
      if (existing != null && !_supersedes(appointment, existing)) continue;
      byAssignee[id] = appointment;
    }
  }
  return byAssignee;
}

bool _supersedes(AppointmentRecord candidate, AppointmentRecord existing) {
  if (candidate.isTimeOff != existing.isTimeOff) return candidate.isTimeOff;
  return candidate.startTime.isBefore(existing.startTime);
}
