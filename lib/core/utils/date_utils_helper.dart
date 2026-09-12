import 'package:intl/intl.dart';

abstract final class DateUtilsHelper {
  // Cached per locale since DateFormat parses locale symbols on construction.
  static final Map<String, DateFormat> _timeFormats = {};
  static final Map<String, DateFormat> _dateFormats = {};
  static final Map<String, DateFormat> _dayHeaderFormats = {};
  static final Map<String, DateFormat> _dayHeaderShortFormats = {};
  static final Map<String, DateFormat> _whenLineFormats = {};
  static final Map<String, DateFormat> _dayMonthFormats = {};

  static String get _locale => Intl.defaultLocale ?? 'en_CA';

  static String formatTime(DateTime date) {
    final format = _timeFormats.putIfAbsent(
      _locale,
      () => DateFormat.jm(_locale),
    );
    return format.format(date);
  }

  static String formatDate(DateTime date) {
    final format = _dateFormats.putIfAbsent(
      _locale,
      () => DateFormat.yMMMd(_locale),
    );
    return format.format(date);
  }

  /// "Tuesday, June 23" day header — the history day groups, the calendar
  /// agenda, the dashboard hero and the day route all render it.
  ///
  /// The locale SKELETON, not a hardcoded `'EEEE, MMMM d'` pattern: a fixed
  /// pattern forces English word order onto every locale, so French read
  /// "mercredi, août 5" instead of "mercredi 5 août". English is unaffected.
  static String formatDayHeader(DateTime date) {
    final format = _dayHeaderFormats.putIfAbsent(
      _locale,
      () => DateFormat.MMMMEEEEd(_locale),
    );
    return format.format(date);
  }

  /// The same day, abbreviated — `Fri, Sep 11`. For a header that has to fit
  /// the date beside other controls; a skeleton again, so the word order stays
  /// the locale's.
  static String formatDayHeaderShort(DateTime date) {
    final format = _dayHeaderShortFormats.putIfAbsent(
      _locale,
      () => DateFormat.MMMEd(_locale),
    );
    return format.format(date);
  }

  /// A run of days as `26 Aug` or `26 – 28 Aug` — the figure beside a day-off
  /// line in the assignee picker.
  ///
  /// Deliberately dateless of any clock: an absence has none, and its stored
  /// instants are a midnight → 23:59 convention that would read as a
  /// suspiciously precise workday. [last] names the last day the absence
  /// covers, so resolve it through `lastWorkDayOf` rather than reading
  /// `endTime.dateOnly`.
  static String formatDayRange(DateTime first, DateTime last) {
    final format = _dayMonthFormats.putIfAbsent(
      _locale,
      () => DateFormat('d MMM', _locale),
    );
    final from = format.format(first);
    if (!last.dateOnly.isAfter(first.dateOnly)) return from;
    return '$from – ${format.format(last)}';
  }

  /// The detail sheet's mono when-line: `TUE 4 AUG · 10:30 – 12:00`.
  /// Uppercased for the mono ramp; the locale supplies the day and month names.
  ///
  /// An all-day block passes its localized label as [allDayLabel] and gets
  /// `TUE 4 AUG · ALL DAY` — its stored instants are a real midnight → 23:59
  /// span, which would otherwise read as a suspiciously precise workday.
  ///
  /// A run spanning several days passes the last day the crew starts work as
  /// [lastDay] and gets `TUE 4 AUG – SAT 8 AUG · 9:00 AM – 5:00 PM`. The times
  /// are a DAILY window, so they describe each of those days rather than one
  /// unbroken stretch. Without the range the sheet showed day 1's date alone,
  /// which on an overnight run was indistinguishable from a single night
  /// shift. Resolve [lastDay] through `lastWorkDayOf` — never by reading
  /// `endTime.dateOnly`, which names the morning an overnight run finishes.
  static String formatWhenLine(
    DateTime start,
    DateTime end, {
    String? allDayLabel,
    DateTime? lastDay,
  }) {
    final format = _whenLineFormats.putIfAbsent(
      _locale,
      () => DateFormat('EEE d MMM', _locale),
    );
    var day = format.format(start).toUpperCase();
    if (lastDay != null && lastDay.dateOnly.isAfter(start.dateOnly)) {
      day = '$day – ${format.format(lastDay).toUpperCase()}';
    }
    if (allDayLabel != null) return '$day · ${allDayLabel.toUpperCase()}';
    return '$day · ${formatTime(start)} – ${formatTime(end)}';
  }
}

extension DateOnly on DateTime {
  /// Midnight of this date in the same zone, centralizing the day-floor.
  DateTime get dateOnly => DateTime(year, month, day);
}

/// Calendar days from [from] to [to]. Normalized through UTC so the two
/// DST-shift days can't make a whole-day difference come back as 23 or 25
/// hours and round to the wrong integer.
///
/// Deliberately has no regression test: this suite runs in UTC, where a
/// naive local-time subtraction passes the exact same cases the UTC
/// normalization is meant to fix, so a "missing" test here would be a false
/// green, not real coverage — don't add one on a UTC runner and call it
/// pinned.
int calendarDaysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// [day] plus [days] calendar days — a calendar-safe alternative to
/// `add(Duration(days: days))`, which can land off real midnight across a
/// DST shift.
DateTime addCalendarDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);
