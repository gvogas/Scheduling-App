import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

/// The list's own tally — `cancelled` is a SUBSET of `total`, never an
/// addition, the same shape as the calendar agenda's `4 JOBS · 1 DONE`.
typedef HistoryTally = ({int total, int cancelled});

/// True when [index] opens a new day, which is when the date rail carries a
/// date instead of leaving its column empty.
///
/// Repeating the date beside every row of a busy day is noise; the rail still
/// reserves its width, so the cards stay aligned.
bool startsDay(List<AppointmentRecord> rows, int index) {
  if (index == 0) return true;
  return rows[index - 1].startTime.dateOnly != rows[index].startTime.dateOnly;
}

/// Counts the rows on screen and how many of them were called off.
///
/// Deliberately over the RENDERED rows: History is paginated, so this is
/// honest about the list you are looking at. A per-month count could only ever
/// report what had loaded, which is a figure that climbs while you read it —
/// which is why there are none.
HistoryTally tallyOf(List<AppointmentRecord> rows) => (
  total: rows.length,
  cancelled: rows.where((a) => isCancelledStatusRaw(a.status)).length,
);

/// The two statuses History actually holds — the `terminalStatusRawValues` set
/// — offered as quick-filter chips. Anything richer would need a field the
/// record does not carry.
enum HistoryStatusFilter {
  complete,
  cancelled;

  bool matches(AppointmentRecord appointment) => switch (this) {
    complete => isCompletedStatusRaw(appointment.status),
    cancelled => isCancelledStatusRaw(appointment.status),
  };
}
