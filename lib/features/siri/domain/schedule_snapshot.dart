import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// Schema version; bump only alongside Swift `ScheduleSnapshot` decoder.
/// v2 added `title` and `isAllDay` for personal jobs, which carry no client
/// and may span the whole day. v3 adds `dayIndex`/`dayCount`/`isOvernight`, and
/// buckets a multi-day job on every day it runs rather than only its first.
/// v4 adds `crew` on an ADMIN's appointments, whose snapshot is business-wide
/// and whose CarPlay rows are otherwise indistinguishable, the top-level
/// `viewer` that lets the car ring the ones the admin is on, and the
/// `isPersonal`/`isDayOff` flags `displayStatusAt` branches on.
const scheduleSnapshotVersion = 4;

/// Days carried beyond today; Phase-2 date queries ("what's my schedule
/// Friday?") resolve against these buckets, and anything further out gets
/// "I only have your schedule for the next 7 days."
///
/// The length of the window that supplies them
/// ([AppointmentDateRange.forMirrors]), not an independent number — the home
/// widget shares that window, so a second value here would fork its listener.
const scheduleSnapshotLookaheadDays = mirrorLookaheadDays;

/// Defensive per-day cap — Siri reads at most one day out loud.
const scheduleSnapshotPerDayCap = 30;

/// Only the fields the Siri intents speak, plus `id` for Phase-4 actions.
/// Notes, phone, and pictures are excluded, since the App Group is readable
/// even while the device is locked.
///
/// [slice] scopes the record to ONE of the days it runs. The counter fields are
/// omitted for a single-day job, so a decoder reading them as optional parses a
/// payload that predates multi-day support unchanged.
///
/// [viewerDocId] is the signed-in person's users-doc id, and it gates ONE field:
/// a personal job's address. See [buildScheduleSnapshot].
Map<String, dynamic> _appointment(
  AppointmentDaySlice slice,
  String viewerDocId, {
  required bool includeCrew,
  required Map<String, int> crewColors,
}) {
  final a = slice.appointment;
  // A personal block is somebody's private appointment — a clinic, a school.
  // Since 2026-08-11 those carry a real address, and an ADMIN's snapshot holds
  // the whole business, so this payload would put every employee's private
  // location on the admin's device, readable while it is locked. The viewer's
  // OWN personal jobs keep their address: it is their data, and directions to
  // it is the point of the field. Client visits are unaffected — an address is
  // what the crew is being sent to.
  final isOthersPersonalJob =
      a.isPersonal && !a.employeeIds.contains(viewerDocId);
  return {
    'id': a.id,
    // THIS day's window — a multi-day run works the same hours each day, and
    // Siri answering with the run's first morning would be wrong on day 2.
    'startMillis': slice.windowStart.millisecondsSinceEpoch,
    'endMillis': slice.windowEnd.millisecondsSinceEpoch,
    'clientName': a.clientName,
    // A personal job has no client, so Siri names it by title instead — the
    // same fallback the widget and the push text already use.
    'title': a.title,
    'address': isOthersPersonalJob ? '' : a.address,
    'status': AppointmentStatus.storedRaw(a.status),
    // An all-day block stores a real midnight–23:59 span; Siri says "all day"
    // rather than reading those two clock times out.
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

/// This job's assignees as `{'n': name, 'c': storedArgb}`.
///
/// `employeeIds` and `employeeNames` are paired POSITIONALLY, so each name is
/// resolved by INDEX against the RAW ids — a filtered id list shifts the two
/// out of step and names the wrong person. `c` is the STORED light-theme ARGB
/// that `crewColorOf` reads, never a lifted value: the car does its own lift.
/// It is omitted when the roster has no colour for that id.
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
/// Pure and unit-testable — carries one bucket per day, and excludes
/// cancelled visits and id-less records, since Phase-4 write actions resolve by id.
///
/// [viewerDocId] is whose device this is. An employee only ever receives their
/// own appointments, so it changes nothing for them; for an admin, whose
/// snapshot is business-wide, it withholds the ADDRESS of other people's
/// personal blocks — the one field in this payload that describes a third
/// party's private whereabouts. Pass `''` and every personal address is
/// withheld, which is the safe direction.
///
/// [crewColors] maps a users-doc id to that employee's STORED colour and feeds
/// the `crew` field, which is emitted for an ADMIN only — an employee's jobs
/// are all theirs, so it would be noise on the row and would put colleagues'
/// names in a container that stays readable while the phone is locked.
///
/// [viewerName] is the roster's `users.name` for the viewer and backs the
/// top-level `viewer` field, emitted for an ADMIN only for the same reasons.
/// The car matches it against `crew` names to ring the viewer's own jobs, and
/// `crew` carries the DENORMALIZED `employeeNames` stamped at booking, which a
/// later rename never rewrites — so a name found on the viewer's own job in
/// this window WINS over the roster one, and the roster is only the fallback
/// for a viewer with no job here (where nothing could ring anyway).
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
  // Keyed by day rather than by its formatted string, so the bucketing loop
  // below can ask `sliceFor` directly instead of parsing `_dayKey` back — that
  // helper stays one-directional.
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
    // A run is bucketed on every day it WORKS, not just the day it began —
    // otherwise Siri says "nothing today" on day 2 of a five-day job.
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
