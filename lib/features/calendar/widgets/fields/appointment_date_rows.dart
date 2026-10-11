import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/widgets/fields/inline_month_calendar.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';

/// Which date row's calendar is open. Null is "neither" — only ONE can be
/// open, which is why the two rows are one widget: two months stacked inside a
/// form panel is not a thing anyone wants to scroll past.
enum _OpenRow { start, end }

/// The appointment form's start and end date rows, each dropping the whole
/// month down beneath them when tapped (owner call, 2026-08-14 — it was a
/// Cupertino date WHEEL in a modal sheet, which shows three days at a time and
/// hides the form behind it).
///
/// A job that runs one day just has the same date in both rows — two dates
/// can't disagree about the run the way a stored multi-day flag could.
class AppointmentDateRows extends StatefulWidget {
  const AppointmentDateRows({
    required this.startValue,
    required this.endValue,
    required this.startDate,
    required this.endDate,
    required this.firstDate,
    required this.lastDate,
    required this.onStartDateSelected,
    required this.onEndDateSelected,
    super.key,
    this.startError,
    this.endError,
    this.endTrailingLabel,
    this.showEndDate = true,
  });

  /// The formatted text each row renders — the form's controllers stay the one
  /// owner of that string, so this widget never formats a date itself.
  final String startValue;
  final String endValue;

  /// The dates behind those strings, for the calendar's selection and the
  /// month it opens on. Null while the field is still empty (add flow).
  final DateTime? startDate;
  final DateTime? endDate;

  /// Inclusive bounds for the START date. The END date additionally can never
  /// precede the start — an end before its start is unbookable, so it isn't
  /// offered.
  final DateTime firstDate;
  final DateTime lastDate;

  final String? startError;
  final String? endError;

  /// Muted run length beside the end date ("5 days"), or null on a one-day job.
  final String? endTrailingLabel;

  /// Whether the END date row is offered at all.
  ///
  /// False on a member of a multi-day RUN: each day is its own appointment, so
  /// there is no end date to move — the run's length is fixed at booking (owner
  /// call 2026-08-27). Shortening a run is cancelling its tail through the
  /// scope dialog; extending it is a second booking.
  final bool showEndDate;

  final ValueChanged<DateTime> onStartDateSelected;
  final ValueChanged<DateTime> onEndDateSelected;

  @override
  State<AppointmentDateRows> createState() => _AppointmentDateRowsState();
}

class _AppointmentDateRowsState extends State<AppointmentDateRows> {
  _OpenRow? _open;

  /// Opening the month does NOT scroll the form (owner call, 2026-08-14).
  /// An `ensureVisible` here moved the page under the finger that had just
  /// tapped the row, so the row you were reading jumped away from where you
  /// left it — and it fought the sheet's own focus scrolling. The month simply
  /// appears where the row is; the form scrolls when the reader scrolls it.
  ///
  /// This is the ONLY thing that closes the month: picking a day does not
  /// (owner call, 2026-08-14). Choosing a date is rarely one tap — you pick
  /// the 12th, see it lands on a Wednesday, and move it — and a picker that
  /// shuts on every tap makes each correction cost a reopen. It closes when
  /// the row is tapped again, or when the other date row takes the panel.
  ///
  /// Nothing is left stale by staying open: the selected day comes from the
  /// widget's `startDate`/`endDate`, so the ring moves as the form updates,
  /// and `InlineMonthCalendar.didUpdateWidget` follows a date changed from
  /// outside (the start date shifting the end date) into its month.
  void _toggle(_OpenRow row) =>
      setState(() => _open = _open == row ? null : row);

  Widget _trailingIcon(_OpenRow row) {
    final theme = Theme.of(context);
    final isOpen = _open == row;
    return Icon(
      isOpen ? Icons.keyboard_arrow_up_rounded : Icons.calendar_today_outlined,
      size: isOpen ? 22 : 18,
      color: isOpen ? theme.palette.primaryAccent : theme.palette.textMuted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final divider = Divider(height: 1, color: theme.colorScheme.outlineVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dateRows(context, divider),
        // Deliberately NOT `AnimatedSize`: it ignores `reverseDuration` on a shrink, and a zero duration re-dirties its own layout.
        if (_open != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [divider, _inlineCalendar(context)],
          ),
      ],
    );
  }

  /// The start/end pair.
  ///
  /// Start and end share one row until the screen is too narrow to read both.
  /// A run member has no end row in EITHER layout, so that test comes first:
  /// each day of a run is its own appointment and its length is not editable.
  Widget _dateRows(BuildContext context, Widget divider) {
    final l10n = context.l10n;
    final startRow = SheetFieldRow(
      key: const ValueKey('appointment-start-date-row'),
      label: l10n.calendar_startDate,
      value: widget.startValue,
      placeholder: l10n.calendar_selectDate,
      accent: true,
      useMonoValue: true,
      errorText: widget.startError,
      onTap: () => _toggle(_OpenRow.start),
      trailing: _trailingIcon(_OpenRow.start),
    );
    if (!widget.showEndDate) return startRow;

    final endRow = SheetFieldRow(
      key: const ValueKey('appointment-end-date-row'),
      label: l10n.calendar_endDate,
      value: widget.endValue,
      placeholder: l10n.calendar_selectDate,
      accent: true,
      useMonoValue: true,
      errorText: widget.endError,
      onTap: () => _toggle(_OpenRow.end),
      // The run length only earns its space once there is a run to describe.
      trailingLabel: widget.endTrailingLabel,
      trailing: _trailingIcon(_OpenRow.end),
    );

    if (context.isNarrowWidth) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [startRow, divider, endRow],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: startRow),
          const VerticalDivider(width: 1),
          Expanded(child: endRow),
        ],
      ),
    );
  }

  /// The month panel for whichever row is open. The dropdown spans the full
  /// panel in both layouts — it belongs to the PAIR, not to one half of the
  /// row.
  Widget _inlineCalendar(BuildContext context) {
    final l10n = context.l10n;
    final isStart = _open == _OpenRow.start;
    return InlineMonthCalendar(
      // Keyed by row so switching from Start to End rebuilds the state rather
      // than keeping the other date's month.
      key: ValueKey('inline-month-${_open!.name}'),
      selectedDate: isStart ? widget.startDate : widget.endDate,
      firstDate: isStart
          ? widget.firstDate
          // Never offer an end before the start. Floored to midnight: a seeded
          // start carries the record's clock time, which would otherwise put
          // its own day out of bounds.
          : (widget.startDate?.dateOnly ?? widget.firstDate),
      lastDate: widget.lastDate,
      // The OTHER end of the run, marked on the month so the day being chosen
      // can be read against the day it pairs with — picking an end date
      // against a bare month means counting cells to find where the job
      // starts.
      companionDate: isStart ? widget.endDate : widget.startDate,
      companionLabel: isStart ? l10n.calendar_endDate : l10n.calendar_startDate,
      onDateSelected: isStart
          ? widget.onStartDateSelected
          : widget.onEndDateSelected,
    );
  }
}
