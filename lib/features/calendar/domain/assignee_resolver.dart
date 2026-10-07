import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Returns active staff the picker may offer, including active stored assignees.
List<EmployeeRecord> offerableAssignees({
  required List<EmployeeRecord> active,
  required Iterable<String> alreadyAssignedIds,
}) {
  final assignedIds = alreadyAssignedIds.toSet();
  return [
    for (final e in active)
      if (e.isAssignable || assignedIds.contains(e.id)) e,
  ];
}

/// Returns the denormalized assignee name at [index], if present.
String? assigneeNameAt(List<String> employeeNames, int index) =>
    index >= 0 && index < employeeNames.length ? employeeNames[index] : null;

/// Merges the picker's selection with any original assignees the picker
/// couldn't show, so they don't get silently unassigned.
({List<String> ids, List<String> names}) mergeRetainedAssignees({
  required List<String> originalIds,
  required List<String> originalNames,
  required List<String> selectedIds,
  required List<String> selectedNames,
  required Set<String> activeIds,
}) {
  final retainedIds = <String>[];
  final retainedNames = <String>[];
  for (var i = 0; i < originalIds.length; i++) {
    final origId = originalIds[i];
    if (!activeIds.contains(origId) && !selectedIds.contains(origId)) {
      retainedIds.add(origId);
      retainedNames.add(assigneeNameAt(originalNames, i) ?? '');
    }
  }
  return (
    ids: [...selectedIds, ...retainedIds],
    names: [...selectedNames, ...retainedNames],
  );
}

/// [job] with [removeId] swapped out for [addId]/[addName].
///
/// Takes the replacement as an id and a name rather than an `EmployeeRecord`
/// because the time-off clash alert runs it BACKWARDS for Undo — putting the
/// person who is off back in place of whoever took the job — and that dialog
/// only ever holds the person's name, never a roster record for them.
///
/// `employeeIds` and `employeeNames` are paired POSITIONALLY, so both lists are
/// rebuilt in one pass — writing the id and appending the name would silently
/// re-pair every assignee after the one replaced.
AppointmentRecord replaceAssignee(
  AppointmentRecord job, {
  required String removeId,
  required String addId,
  required String addName,
}) {
  // This re-serializes the WHOLE record, so a legacy `confirmed`/unknown
  // status would be written back verbatim and rejected by the rules as an
  // opaque permission-denied on an ordinary-looking swap.
  final status = AppointmentStatus.storedRaw(job.status);
  final ids = <String>[];
  final names = <String>[];
  for (var i = 0; i < job.employeeIds.length; i++) {
    final isTarget = job.employeeIds[i] == removeId;
    ids.add(isTarget ? addId : job.employeeIds[i]);
    names.add(
      isTarget ? addName : (assigneeNameAt(job.employeeNames, i) ?? ''),
    );
  }
  return job.copyWith(employeeIds: ids, employeeNames: names, status: status);
}

/// How the picker must treat one offered assignee on the chosen date.
enum AssigneeOfferState {
  /// No clash — an ordinary tappable chip.
  free,

  /// On another job, not this one: tappable; Save asks before double booking.
  booked,

  /// Off that day, and not on the job: dimmed, not tappable.
  unavailable,

  /// A clash, but already assigned and still tappable.
  onTheJob,
}

/// Returns how the picker offers [employeeId], given each assignee's [clashes].
AssigneeOfferState assigneeOfferState({
  required String employeeId,
  required Map<String, AppointmentRecord> clashes,
  required Set<String> selectedIds,
  required Set<String> alreadyAssignedIds,
}) {
  final clash = clashes[employeeId];
  if (clash == null) return AssigneeOfferState.free;
  if (selectedIds.contains(employeeId) ||
      alreadyAssignedIds.contains(employeeId)) {
    return AssigneeOfferState.onTheJob;
  }
  return clash.isTimeOff
      ? AssigneeOfferState.unavailable
      : AssigneeOfferState.booked;
}

/// Short display name, disambiguated by last initial when first names repeat.
String shortAssigneeName(String name, {required Map<String, int> among}) {
  final parts = name.trim().split(_nameGap);
  final first = parts.first;
  if (parts.length < 2 || first.isEmpty) return name.trim();
  final sharers = among[first.toLowerCase()] ?? 0;
  return sharers > 1 ? '$first ${parts.last[0]}.' : first;
}

/// Tallies lowercased first names for [shortAssigneeName].
Map<String, int> firstNameTally(Iterable<String> names) {
  final tally = <String, int>{};
  for (final name in names) {
    final first = name.trim().split(_nameGap).first.toLowerCase();
    if (first.isEmpty) continue;
    tally[first] = (tally[first] ?? 0) + 1;
  }
  return tally;
}

/// Shared whitespace splitter for assignee-name helpers.
final _nameGap = RegExp(r'\s+');
