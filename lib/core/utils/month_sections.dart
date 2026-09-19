import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// A contiguous run of list rows that fall in the same calendar month.
///
/// A window into the flat list rather than a copy of it: `start` is the index
/// of the section's first row in that list, which is what lets the list keep
/// ONE global index. The feature tour wraps row 0 and the pager prefetches near
/// the end, and both ask about the whole list, not about a section of it.
typedef MonthSection = ({DateTime month, int start, int length});

/// Splits [rows] into month sections, in the order they already appear.
///
/// Never re-sorts. History is served newest-first by the query and a search
/// result set keeps whatever order the repository returned, so a section is a
/// contiguous RUN and not a bucket — a month the list somehow re-entered later
/// would open a second section rather than silently reordering the rows above
/// it.
List<MonthSection> monthSectionsOf(List<AppointmentRecord> rows) {
  final sections = <MonthSection>[];
  var start = 0;
  for (var i = 1; i <= rows.length; i++) {
    final ends = i == rows.length || !_sameMonth(rows[i], rows[start]);
    if (!ends) continue;
    sections.add((
      month: _monthOf(rows[start].startTime),
      start: start,
      length: i - start,
    ));
    start = i;
  }
  return sections;
}

bool _sameMonth(AppointmentRecord a, AppointmentRecord b) =>
    a.startTime.year == b.startTime.year &&
    a.startTime.month == b.startTime.month;

DateTime _monthOf(DateTime date) => DateTime(date.year, date.month);
