import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// Schema version; bump only alongside Swift `ScheduleSnapshot` decoder.
const scheduleSnapshotVersion = 4;

/// Days carried beyond today — the shared mirror window, never its own number.
const scheduleSnapshotLookaheadDays = mirrorLookaheadDays;

/// Defensive per-day cap — Siri reads at most one day out loud.
const scheduleSnapshotPerDayCap = 30;

/// Only the fields the intents speak; the App Group is readable while locked.
Map<String, dynamic> _appointment(
  AppointmentDaySlice slice,
  String viewerDocId, {
  required bool includeCrew,
  required Map<String, int> crewColors,
}) {
  final a = slice.appointment;
  // Another person's personal-block address is withheld from an admin.
  final isOthersPersonalJob =
      a.isPersonal && !a.employeeIds.contains(viewerDocId);
  return {
    'id': a.id,
    // THIS day's window, so day 2 of a run isn't answered with day 1's.
    'startMillis': slice.windowStart.millisecondsSinceEpoch,
    'endMillis': slice.windowEnd.millisecondsSinceEpoch,
    'clientName': a.clientName,
    // A personal job has no client, so Siri names it by title.
    'title': a.title,
    'address': isOthersPersonalJob ? '' : a.address,
    'status': AppointmentStatus.storedRaw(a.status),
    // An all-day block is spoken as "all day", not its stored span.
    'isAllDay': a.isAllDay,
    // The flags `displayStatusAt` branches on, so the car mirrors the ladder.
    if (a.isPersonal) 'isPersonal': true,
    if (a.isDayOff) 'isDayOff': true,
    if (includeCrew) 'crew': _crew(a, crewColors),
    if (slice.isMultiDay) 'dayIndex': slice.dayIndex,
    if (slice.isMultiDay) 'dayCount': slice.dayCount,
    // A window crossing midnight counts NIGHTS, so Siri says "night 2 of 3".
    if (slice.isMultiDay) 'isOvernight': slice.isOvernight,
  };
}

/// This job's assignees as `{'n': name, 'c': storedArgb}`, paired by index.
List<Map<String, dynamic>> _crew(
  AppointmentRecord a,
  Map<String, int> crewColors,
) => [
  for (var i = 0; i < a.employeeIds.length; i++)
    {
      'n': assigneeNameAt(a.employeeNames, i) ?? '',
      'c': ?crewColors[a.employeeIds[i]],
    },
];

String _dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Serializes the schedule the Siri App Intents extension answers from.
Map<String, dynamic> buildScheduleSnapshot({
  required List<AppointmentRecord> appointments,
  required String role,
  required DateTime now,
  String viewerDocId = '',
  String viewerName = '',
  Map<String, int> crewColors = const {},
}) {
  final includeCrew = role == 'admin';
  final startOfToday = now.dateOnly;
  // Keyed by day so the loop can call `sliceFor` without parsing `_dayKey`.
  final buckets = <DateTime, List<AppointmentDaySlice>>{
    for (var i = 0; i <= scheduleSnapshotLookaheadDays; i++)
      DateTime(startOfToday.year, startOfToday.month, startOfToday.day + i):
          <AppointmentDaySlice>[],
  };

  var viewerCrewName = '';
  for (final a in appointments) {
    if (a.id == null || a.id!.isEmpty) continue;
    if (isCancelledStatusRaw(a.status)) continue;
    if (includeCrew && viewerCrewName.isEmpty && viewerDocId.isNotEmpty) {
      final index = a.employeeIds.indexOf(viewerDocId);
      viewerCrewName = assigneeNameAt(a.employeeNames, index) ?? '';
    }
    // Bucketed on every day a run WORKS, not just its first.
    for (final day in buckets.keys) {
      final slice = sliceFor(a, day);
      if (slice != null) buckets[day]!.add(slice);
    }
  }

  final viewer = viewerCrewName.isNotEmpty ? viewerCrewName : viewerName;
  return {
    'version': scheduleSnapshotVersion,
    'generatedAt': now.millisecondsSinceEpoch,
    'role': role,
    if (includeCrew && viewer.isNotEmpty) 'viewer': viewer,
    'days': [
      for (final entry in buckets.entries)
        {
          'date': _dayKey(entry.key),
          'appointments': [
            for (final slice
                in (entry.value
                      ..sort((x, y) => x.windowStart.compareTo(y.windowStart)))
                    .take(scheduleSnapshotPerDayCap))
              _appointment(
                slice,
                viewerDocId,
                includeCrew: includeCrew,
                crewColors: crewColors,
              ),
          ],
        },
    ],
  };
}
