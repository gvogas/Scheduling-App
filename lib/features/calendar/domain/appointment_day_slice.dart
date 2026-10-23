import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// Maximum appointment span, mirrored in functions and Firestore rules.
const int maxAppointmentSpanDays = 14;

/// One appointment as it appears on one day of its span.
@immutable
class AppointmentDaySlice {
  const AppointmentDaySlice({
    required this.appointment,
    required this.dayIndex,
    required this.dayCount,
    required this.windowStart,
    required this.windowEnd,
  });

  final AppointmentRecord appointment;

  /// 1-based position in the run.
  final int dayIndex;
  final int dayCount;

  /// This day's concrete window, possibly ending the next calendar day.
  final DateTime windowStart;
  final DateTime windowEnd;

  bool get isMultiDay => dayCount > 1;

  /// The window crosses midnight, so the run counts NIGHTS, not days.
  bool get isOvernight => windowEnd.dateOnly.isAfter(windowStart.dateOnly);
}

/// True when a daily window crosses midnight or covers 24 hours.
bool _isOvernightWindow(DateTime start, DateTime end) {
  final startMinutes = start.hour * 60 + start.minute;
  final endMinutes = end.hour * 60 + end.minute;
  return endMinutes <= startMinutes;
}

/// Last day the crew starts work for a raw daily window.
DateTime lastWorkDayOfWindow(DateTime start, DateTime end) =>
    _isOvernightWindow(start, end)
    ? addCalendarDays(end.dateOnly, -1)
    : end.dateOnly;

/// Last day the crew starts work for an appointment.
DateTime lastWorkDayOf(AppointmentRecord appointment) =>
    lastWorkDayOfWindow(appointment.startTime, appointment.endTime);

/// Raw day or night count for a daily window.
int _dayCountOfWindow(DateTime start, DateTime end) =>
    calendarDaysBetween(start.dateOnly, lastWorkDayOfWindow(start, end)) + 1;

/// Clamped day count used by all day-scoping helpers.
int _clampedDayCount(DateTime start, DateTime end) =>
    math.min(_dayCountOfWindow(start, end), maxAppointmentSpanDays);

/// The concrete window a daily [start]–[end] pair occupies on [day].
({DateTime start, DateTime end}) _windowOn(
  DateTime day,
  DateTime start,
  DateTime end,
) {
  final overnight = _isOvernightWindow(start, end);
  return (
    start: DateTime(day.year, day.month, day.day, start.hour, start.minute),
    end: DateTime(
      day.year,
      day.month,
      day.day + (overnight ? 1 : 0),
      end.hour,
      end.minute,
    ),
  );
}

/// True when [appointment]'s daily window runs on [day].
bool runsOn(AppointmentRecord appointment, DateTime day) =>
    _dayIndexOn(appointment, day) != null;

/// True when [appointment] is countable work.
bool countsAsWork(AppointmentRecord appointment) =>
    !isCancelledStatusRaw(appointment.status) && !appointment.isTimeOff;

/// True when [appointment] counts as load on [day].
bool countsAsLoadOn(AppointmentRecord appointment, DateTime day) =>
    countsAsWork(appointment) && runsOn(appointment, day);

/// True when [appointment] runs on at least one day in `[start, end)`.
bool runsInRange(AppointmentRecord appointment, DateTime start, DateTime end) {
  final count = _clampedDayCount(appointment.startTime, appointment.endTime);
  // Corrupt records with no valid day do not run.
  if (count < 1) return false;
  final firstDay = appointment.startTime.dateOnly;
  final lastDay = addCalendarDays(firstDay, count - 1);
  return firstDay.isBefore(end) && !lastDay.isBefore(start.dateOnly);
}

/// Returns [appointment]'s slice for [day], or null when it does not run.
AppointmentDaySlice? sliceFor(AppointmentRecord appointment, DateTime day) {
  final index = _dayIndexOn(appointment, day);
  if (index == null) return null;
  final label = _storedRunLabel(appointment) ?? index;
  return _sliceAt(
    appointment,
    day: day.dateOnly,
    index: label.dayIndex,
    count: label.dayCount,
  );
}

/// Returns a coherent stored split-day label, or null to derive it.
({int dayIndex, int dayCount})? _storedRunLabel(AppointmentRecord a) {
  if (a.dayCount < 2 || a.dayCount > maxAppointmentSpanDays) return null;
  if (a.dayIndex < 1 || a.dayIndex > a.dayCount) return null;
  if (_clampedDayCount(a.startTime, a.endTime) != 1) return null;
  return (dayIndex: a.dayIndex, dayCount: a.dayCount);
}

/// Returns [day]'s 1-based run position, or null when it does not run.
({int dayIndex, int dayCount})? _dayIndexOn(
  AppointmentRecord appointment,
  DateTime day,
) {
  final count = _clampedDayCount(appointment.startTime, appointment.endTime);
  if (count < 1) return null;
  final index = calendarDaysBetween(appointment.startTime.dateOnly, day) + 1;
  if (index < 1 || index > count) return null;
  return (dayIndex: index, dayCount: count);
}

AppointmentDaySlice _sliceAt(
  AppointmentRecord appointment, {
  required DateTime day,
  required int index,
  required int count,
}) {
  final window = _windowOn(day, appointment.startTime, appointment.endTime);
  return AppointmentDaySlice(
    appointment: appointment,
    dayIndex: index,
    dayCount: count,
    windowStart: window.start,
    windowEnd: window.end,
  );
}

/// True when two daily windows overlap on any day they both run.
bool dailyWindowsOverlap({
  required DateTime aStart,
  required DateTime aEnd,
  required DateTime bStart,
  required DateTime bEnd,
}) {
  // Compare every clamped window pair to catch overnight overlaps.
  final bWindows = _windowsOf(bStart, bEnd);
  return _windowsOf(aStart, aEnd).any(
    (a) => bWindows.any(
      (b) => a.start.isBefore(b.end) && b.start.isBefore(a.end),
    ),
  );
}

/// Concrete work windows for a daily [start]-[end] pair.
///
/// Shares [expandRunWindows]' loop rather than repeating it: the windows a run
/// is BOOKED with and the windows it is CHECKED against for clashes must be
/// the same arithmetic, and this file is the one owner of day scoping. The
/// only difference is the incoherent-pair answer — nothing to check, versus
/// one window to book.
List<({DateTime start, DateTime end})> _windowsOf(
  DateTime start,
  DateTime end,
) => _clampedDayCount(start, end) < 1 ? const [] : expandRunWindows(start, end);

/// Buckets appointment day slices by work day, clipped to [range].
Map<DateTime, List<AppointmentDaySlice>> expandToDays(
  Iterable<AppointmentRecord> records,
  AppointmentDateRange range, {
  void Function(AppointmentRecord appointment, int actualDays)? onSpanClamped,
}) {
  final slicesByDay = <DateTime, List<AppointmentDaySlice>>{};
  for (final appointment in records) {
    final rawCount = _dayCountOfWindow(
      appointment.startTime,
      appointment.endTime,
    );
    if (rawCount < 1) continue;
    // Clamp oversized spans and report the original count.
    final count = rawCount > maxAppointmentSpanDays
        ? maxAppointmentSpanDays
        : rawCount;
    if (count != rawCount) onSpanClamped?.call(appointment, rawCount);

    final startDate = appointment.startTime.dateOnly;
    // A split run day carries its own position, the same substitution
    // `sliceFor` makes. Only the emitted label is substituted — the range
    // test above stays derived from the record's own one-day window.
    final stored = _storedRunLabel(appointment);
    for (var i = 0; i < count; i++) {
      final day = addCalendarDays(startDate, i);
      if (day.isBefore(range.start) || !day.isBefore(range.end)) continue;
      // Use the clamped count so `dayIndex == dayCount` stays reachable.
      (slicesByDay[day] ??= <AppointmentDaySlice>[]).add(
        _sliceAt(
          appointment,
          day: day,
          index: stored?.dayIndex ?? i + 1,
          count: stored?.dayCount ?? count,
        ),
      );
    }
  }
  for (final slices in slicesByDay.values) {
    slices.sort(_agendaOrder);
  }
  return slicesByDay;
}

/// Sorts open work first, then all-day before timed, then by window start.
int _agendaOrder(AppointmentDaySlice a, AppointmentDaySlice b) {
  final aClosed = a.appointment.isClosed;
  final bClosed = b.appointment.isClosed;
  if (aClosed != bClosed) return aClosed ? 1 : -1;
  final aAllDay = a.appointment.isAllDay;
  final bAllDay = b.appointment.isAllDay;
  if (aAllDay != bAllDay) return aAllDay ? -1 : 1;
  return a.windowStart.compareTo(b.windowStart);
}

/// Splits a booked daily window into one local-time window per work day.
List<({DateTime start, DateTime end})> expandRunWindows(
  DateTime start,
  DateTime end,
) {
  final count = _clampedDayCount(start, end);
  final days = count < 1 ? 1 : count;
  final firstDay = start.dateOnly;
  return [
    for (var i = 0; i < days; i++)
      _windowOn(addCalendarDays(firstDay, i), start, end),
  ];
}
