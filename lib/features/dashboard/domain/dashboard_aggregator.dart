import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_period.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Pure reducer functions over the dashboard's appointment range, keyed on
/// `now` so tests can control the clock.
class DashboardAggregator {
  DashboardAggregator._();

  static const int weekCount = 8;
  static const Duration pendingSoonWindow = Duration(hours: 48);
  static const int upcomingLimit = 5;

  /// Midnight on the Monday of [day]'s week (ISO week start).
  static DateTime mondayOf(DateTime day) =>
      DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

  /// The query range spans 8 ISO weeks back through next Monday, extended
  /// by 3 days to cover the pending window.
  static AppointmentDateRange rangeAround(DateTime now) => AppointmentDateRange(
    start: _windowStart(now),
    end: liveRangeAround(now).end,
  );

  /// The part of [rangeAround] that can still change while the screen is up:
  /// the current ISO week through next Monday (or the 3-day pending horizon,
  /// whichever is later).
  ///
  /// **This is the half that gets a live listener.** The other seven weeks are
  /// closed history — [historyRangeAround] reads them once. Splitting drops the
  /// live document set by roughly 85% and takes the 3000-doc stream cap off the
  /// trend charts, which above ~14 jobs/day were being computed over a prefix
  /// of the window with nothing on screen saying so.
  static AppointmentDateRange liveRangeAround(DateTime now) {
    final monday = mondayOf(now);
    final nextMonday = DateTime(monday.year, monday.month, monday.day + 7);
    final pendingHorizon = DateTime(now.year, now.month, now.day + 3);
    return AppointmentDateRange(
      start: monday,
      end: nextMonday.isAfter(pendingHorizon) ? nextMonday : pendingHorizon,
    );
  }

  /// The settled weeks behind [liveRangeAround] — read once, never watched.
  ///
  /// Ends exactly where the live range starts. The two results overlap anyway,
  /// because each query reaches back to its own `fetchStart` to catch a run
  /// already under way, so the caller must merge by doc id rather than
  /// concatenate.
  static AppointmentDateRange historyRangeAround(DateTime now) =>
      AppointmentDateRange(start: _windowStart(now), end: mondayOf(now));

  static DateTime _windowStart(DateTime now) {
    final monday = mondayOf(now);
    return DateTime(
      monday.year,
      monday.month,
      monday.day - 7 * (weekCount - 1),
    );
  }

  /// Merges the live half with the one-shot history half, de-duplicating by
  /// doc id.
  ///
  /// The two queries deliberately overlap — each reaches back to its own
  /// `fetchStart` so a run already under way is still fetched — so a plain
  /// concatenation would double-count roughly a fortnight of jobs in every
  /// chart. [live] wins any collision: it is the half backed by a listener, so
  /// it is the half that can be newer.
  static List<AppointmentRecord> mergeById(
    List<AppointmentRecord> live,
    List<AppointmentRecord> history,
  ) {
    final merged = <AppointmentRecord>[];
    final seen = <String>{};
    // Live first, so it wins any collision.
    for (final a in [...live, ...history]) {
      final id = a.id;
      // Nothing read from Firestore lacks a doc id, but a record that somehow
      // does cannot be de-duplicated — and keeping a possible double-count
      // beats dropping real work out of the Attention list.
      if (id == null || id.isEmpty || seen.add(id)) merged.add(a);
    }
    return merged;
  }

  /// Delegates to [AppointmentRecord.displayStatusAt], which owns the ladder —
  /// this used to be a hand-copied mirror and had already drifted (it was
  /// missing the isPersonal carve-out, so the dashboard reported a personal
  /// block as overdue while its card said Scheduled). Use statusCountKey to key
  /// off the result; calling `.raw` directly on overdue would throw.
  static String displayStatusAt(AppointmentRecord appointment, DateTime now) =>
      appointment.displayStatusAt(now);

  /// Stable key for statusCounts. 'overdue' has no stored raw value, so we
  /// just key it on the literal string 'overdue'.
  static String statusCountKey(AppointmentStatus status) =>
      status == AppointmentStatus.overdue ? 'overdue' : status.raw;

  static TodayOps computeTodayOps(
    List<AppointmentRecord> appointments,
    DateTime now,
  ) {
    final dayStart = now.dateOnly;
    final counts = <String, int>{};
    var unassigned = 0;
    final upcoming = <AppointmentDaySlice>[];
    for (final a in appointments) {
      // Re-scoped through the slice owner: the range stream is a superset,
      // and testing `startTime` alone hid days 2+ of a multi-day run.
      final slice = sliceFor(a, dayStart);
      if (slice == null) continue;
      final display = statusCountKey(
        AppointmentStatus.fromRaw(displayStatusAt(a, now)),
      );
      counts[display] = (counts[display] ?? 0) + 1;
      if (a.employeeIds.isEmpty && !_isCancelled(a)) unassigned++;
      // THIS day's window, not the run's first morning — day 3 of a 14:00
      // job is still ahead of a 09:00 reader, and sorting on the stored
      // instant would float it above jobs that genuinely start earlier today.
      if (slice.windowStart.isAfter(now) && !_isTerminal(a)) {
        upcoming.add(slice);
      }
    }
    upcoming.sort((x, y) => x.windowStart.compareTo(y.windowStart));
    return TodayOps(
      statusCounts: counts,
      unassignedCount: unassigned,
      upcoming: upcoming.take(upcomingLimit).toList(),
    );
  }

  /// Counts jobs per employee for today and for this ISO week. Cancelled
  /// visits are excluded, and a multi-assignee visit counts once for each
  /// assignee. [employees] should be the active, crew-only list from
  /// `assignableEmployeesProvider`.
  static List<EmployeeWorkload> computeWorkload(
    List<AppointmentRecord> appointments,
    List<EmployeeRecord> employees,
    DateTime now,
  ) {
    final dayStart = now.dateOnly;
    final weekStart = mondayOf(now);
    final weekEnd = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day + 7,
    );
    final today = <String, int>{};
    final week = <String, int>{};
    for (final a in appointments) {
      if (_isCancelled(a)) continue;
      // Overlap, not "starts this week": a run booked last Friday is still
      // this week's load on the Monday the crew is on it.
      if (!runsInRange(a, weekStart, weekEnd)) continue;
      final inDay = runsOn(a, dayStart);
      for (final id in a.employeeIds) {
        week[id] = (week[id] ?? 0) + 1;
        if (inDay) today[id] = (today[id] ?? 0) + 1;
      }
    }
    return [
      for (final e in employees)
        EmployeeWorkload(
          employee: e,
          todayCount: today[e.id] ?? 0,
          weekCount: week[e.id] ?? 0,
        ),
    ];
  }

  /// The 8 Monday-midnight week starts, oldest first, ending with the
  /// current week.
  static List<DateTime> weekStartsFor(DateTime now) {
    final monday = mondayOf(now);
    return [
      for (var i = weekCount - 1; i >= 0; i--)
        DateTime(monday.year, monday.month, monday.day - 7 * i),
    ];
  }

  static List<WeekBucket> computeWeekBuckets(
    List<AppointmentRecord> appointments,
    List<DateTime> clientCreatedDates,
    DateTime now,
  ) {
    final weekStarts = weekStartsFor(now);
    final horizon = _weekAfter(weekStarts.last);
    final completed = List<int>.filled(weekCount, 0);
    final cancelled = List<int>.filled(weekCount, 0);
    final newClients = List<int>.filled(weekCount, 0);
    for (final a in appointments) {
      final i = _bucketIndex(weekStarts, horizon, a.startTime);
      if (i < 0) continue;
      final status = AppointmentStatus.fromRaw(a.status);
      if (status.isDone) completed[i]++;
      if (status.isCancelled) cancelled[i]++;
    }
    for (final date in clientCreatedDates) {
      final i = _bucketIndex(weekStarts, horizon, date);
      if (i >= 0) newClients[i]++;
    }
    return [
      for (var i = 0; i < weekCount; i++)
        WeekBucket(
          weekStart: weekStarts[i],
          completed: completed[i],
          cancelled: cancelled[i],
          newClients: newClients[i],
        ),
    ];
  }

  /// Jobs booked on each day of the current ISO week, against the roster's
  /// capacity for that day.
  ///
  /// **Monday–Sunday of this week, not the next 7 days**, and that is a data
  /// constraint rather than a preference: `liveRangeAround` runs from this
  /// week's Monday to next Monday, so a rolling 7-day window would run off the
  /// end of the fetched range on most weekdays and paint the missing days as
  /// zero — the same silent under-count a whole-month period would have had.
  ///
  /// Counted through [runsOn], so a multi-day run is booked on every day it
  /// works. Cancelled visits are excluded from both sides.
  static List<DayLoad> computeDailyLoad(
    List<AppointmentRecord> appointments,
    List<EmployeeRecord> employees,
    DateTime now,
  ) {
    final monday = mondayOf(now);
    // ONE `expandToDays` pass, not a `runsOn` probe per (job, day).
    final byDay = expandToDays(
      [
        for (final a in appointments)
          if (!_isCancelled(a)) a,
      ],
      AppointmentDateRange(
        start: monday,
        end: addCalendarDays(monday, DateTime.daysPerWeek),
      ),
    );
    return [
      for (var i = 0; i < DateTime.daysPerWeek; i++)
        _dayLoadOn(addCalendarDays(monday, i), byDay, employees),
    ];
  }

  static DayLoad _dayLoadOn(
    DateTime day,
    Map<DateTime, List<AppointmentDaySlice>> slicesByDay,
    List<EmployeeRecord> employees,
  ) {
    final count = slicesByDay[day]?.length ?? 0;
    final weekdayIndex = sundayIndexOf(day);
    var capacity = 0;
    for (final e in employees) {
      if (weekdayIndex < e.workingDays.length && e.workingDays[weekdayIndex]) {
        capacity += e.maxJobsPerDay;
      }
    }
    return DayLoad(day: day, count: count, capacity: capacity);
  }

  /// The summary numbers for the selected period.
  ///
  /// Takes a resolved [DashboardWindow], never a `DashboardPeriod` — the
  /// window rule has one owner (`DashboardPeriod.windowFor`) and switching on
  /// the period in here would be a second.
  ///
  /// Scoped through [runsInRange], not `startTime`: the merged list reaches
  /// back to each query's `fetchStart`, so a raw instant test would read a
  /// fortnight of past work as in-window, and would drop a run that began
  /// before the period but is still being worked inside it.
  ///
  /// **"Completed in this period" means a job that RUNS in the period and is
  /// stored `done`** — there is no completion timestamp on the record, so this
  /// is the honest available reading, not an approximation of one.
  static PeriodSummary computePeriodSummary({
    required List<AppointmentRecord> appointments,
    required List<DateTime> clientCreatedDates,
    required DashboardWindow window,
  }) {
    var booked = 0;
    var completed = 0;
    var cancelled = 0;
    for (final a in appointments) {
      if (!runsInRange(a, window.start, window.end)) continue;
      final status = AppointmentStatus.fromRaw(a.status);
      if (status.isCancelled) {
        cancelled++;
        continue;
      }
      // Cancelled work was never booked business — it is counted on its own.
      booked++;
      if (status.isDone) completed++;
    }
    var newClients = 0;
    for (final date in clientCreatedDates) {
      if (!date.isBefore(window.start) && date.isBefore(window.end)) {
        newClients++;
      }
    }
    return PeriodSummary(
      booked: booked,
      completed: completed,
      cancelled: cancelled,
      newClients: newClients,
    );
  }

  /// Finds the busiest weekday over the window, excluding cancelled visits.
  /// Ties go to the earliest weekday, and this returns null when nothing
  /// counts.
  static BusiestWeekday? computeBusiestWeekday(
    List<AppointmentRecord> appointments,
    DateTime now,
  ) {
    final weekStarts = weekStartsFor(now);
    final horizon = _weekAfter(weekStarts.last);
    final counts = List<int>.filled(DateTime.daysPerWeek + 1, 0);
    for (final a in appointments) {
      if (_isCancelled(a)) continue;
      if (_bucketIndex(weekStarts, horizon, a.startTime) < 0) continue;
      counts[a.startTime.weekday]++;
    }
    var bestDay = 0;
    var bestCount = 0;
    for (var day = DateTime.monday; day <= DateTime.sunday; day++) {
      if (counts[day] > bestCount) {
        bestDay = day;
        bestCount = counts[day];
      }
    }
    if (bestCount == 0) return null;
    return BusiestWeekday(weekday: bestDay, count: bestCount);
  }

  /// Deliberately the ONE reducer here with no range predicate.
  ///
  /// The list starts at `fetchStart` (14 days before the range), so Attention
  /// draws on ~10 weeks where the trend sections use 8. That is intended: a job
  /// that went overdue nine weeks ago still needs an admin to close it, and
  /// clipping to the chart window would silently drop the oldest — and most
  /// neglected — work from the one list whose entire job is to surface it.
  /// Both branches are already time-bounded on their own terms (`pendingSoon`
  /// by the soon-window, `overdueOpen` by `displayStatusAt`), so an unbounded
  /// scan can't pull in anything that isn't genuinely actionable.
  static AttentionFlags computeAttentionFlags(
    List<AppointmentRecord> appointments,
    DateTime now,
  ) {
    final soonCutoff = now.add(pendingSoonWindow);
    final pendingSoon = <AppointmentRecord>[];
    final overdueOpen = <AppointmentRecord>[];
    for (final a in appointments) {
      if (AppointmentStatus.fromRaw(a.status) == AppointmentStatus.pending &&
          a.startTime.isAfter(now) &&
          !a.startTime.isAfter(soonCutoff)) {
        pendingSoon.add(a);
      }
      if (displayStatusAt(a, now) == 'overdue') {
        overdueOpen.add(a);
      }
    }
    pendingSoon.sort((x, y) => x.startTime.compareTo(y.startTime));
    overdueOpen.sort((x, y) => x.startTime.compareTo(y.startTime));
    return AttentionFlags(pendingSoon: pendingSoon, overdueOpen: overdueOpen);
  }

  static DashboardStats computeStats({
    required List<AppointmentRecord> appointments,
    required List<EmployeeRecord> employees,
    required List<DateTime> clientCreatedDates,
    required DateTime now,
  }) => DashboardStats(
    todayOps: computeTodayOps(appointments, now),
    workload: computeWorkload(appointments, employees, now),
    dailyLoad: computeDailyLoad(appointments, employees, now),
    weekBuckets: computeWeekBuckets(appointments, clientCreatedDates, now),
    busiestWeekday: computeBusiestWeekday(appointments, now),
    flags: computeAttentionFlags(appointments, now),
  );

  static bool _isCancelled(AppointmentRecord a) =>
      isCancelledStatusRaw(a.status);

  static bool _isTerminal(AppointmentRecord a) =>
      isTerminalStatusRaw(a.status);

  static DateTime _weekAfter(DateTime weekStart) =>
      DateTime(weekStart.year, weekStart.month, weekStart.day + 7);

  /// Index of the week bucket containing [t], or -1 outside the window.
  static int _bucketIndex(
    List<DateTime> weekStarts,
    DateTime horizon,
    DateTime t,
  ) {
    if (!t.isBefore(horizon)) return -1;
    for (var i = weekStarts.length - 1; i >= 0; i--) {
      if (!t.isBefore(weekStarts[i])) return i;
    }
    return -1;
  }
}
