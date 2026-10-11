import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:intl/intl.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/holidays.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_day_circle.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_month_grid.dart';
import 'package:scheduling/l10n/l10n.dart';

/// 1.0-scale FLOORS, like the calendar screen's grid — the real sizes derive
/// from the scaled day number so the month still fits at a large text size.
const double _kCellMinHeight = 38;
const double _kCircleMin = 30;
const EdgeInsets _kPadding = EdgeInsets.fromLTRB(10, 4, 10, 12);

/// A whole month, laid out for PICKING a date inside a form — the panel that
/// drops down under an appointment's date row.
///
/// Provider-free and clock-free by construction: it renders the month it is
/// given from the pure helpers in `month_grid.dart`, the same ones the calendar
/// screen's grid uses, so the two can't disagree about where a day sits or
/// where the week starts. It shows no crew dots: this asks "which date", not
/// "how busy is that day", and the form has no appointment stream to read.
///
/// Days outside [firstDate]/[lastDate] render faint and are untappable — an
/// end date before its start is unbookable, so it must not be reachable here
/// either.
class InlineMonthCalendar extends StatefulWidget {
  const InlineMonthCalendar({
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
    required this.onDateSelected,
    super.key,
    this.today,
    this.companionDate,
    this.companionLabel,
  });

  /// The date currently held by the field, or null when it is still empty.
  final DateTime? selectedDate;

  /// Inclusive bounds. A day outside them is rendered but not tappable.
  final DateTime firstDate;
  final DateTime lastDate;

  final ValueChanged<DateTime> onDateSelected;

  /// The OTHER end of the run — the start date while the end is being picked,
  /// and the end date while the start is. Marked with a soft fill so the day
  /// being chosen can be read against the day it is paired with: picking an
  /// end date against a bare month means counting cells to work out where the
  /// job began. Null when the pair has only one date, or when both ends are
  /// the same day (a one-day job marks it once, as the selection).
  final DateTime? companionDate;

  /// Names what [companionDate] is, for the screen reader — the marker is a
  /// tint, and a tint says nothing out loud.
  final String? companionLabel;

  /// Injectable for tests; defaults to the wall clock. This widget lives for
  /// as long as a dropdown is open, so it cannot outlive midnight the way the
  /// calendar screen can — that screen watches `currentDayProvider` instead.
  final DateTime? today;

  @override
  State<InlineMonthCalendar> createState() => _InlineMonthCalendarState();
}

class _InlineMonthCalendarState extends State<InlineMonthCalendar> {
  late DateTime _month = _monthOf(widget.selectedDate ?? _today);

  DateTime get _today => widget.today ?? DateTime.now();

  static DateTime _monthOf(DateTime day) => DateTime(day.year, day.month);

  @override
  void didUpdateWidget(InlineMonthCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow a selection made from outside (the start date shifting the end
    // date, say) — but never fight the user's own paging, which is why this
    // only fires when the incoming date actually changed.
    final picked = widget.selectedDate;
    if (picked != null && picked != oldWidget.selectedDate) {
      _month = _monthOf(picked);
    }
  }

  bool _isSelected(DateTime day) {
    final picked = widget.selectedDate;
    return picked != null && isSameDate(day, picked);
  }

  bool _isCompanion(DateTime day) {
    final other = widget.companionDate;
    return other != null && isSameDate(day, other);
  }

  bool _isEnabled(DateTime day) {
    final date = day.dateOnly;
    return !date.isBefore(widget.firstDate.dateOnly) &&
        !date.isAfter(widget.lastDate.dateOnly);
  }

  /// True while the month one step in [direction] still holds a pickable day.
  bool _canPage(int direction) {
    final target = DateTime(_month.year, _month.month + direction);
    // `target` is the month's first day; day 0 of the NEXT month is its last.
    final lastOfTarget = DateTime(target.year, target.month + 1, 0);
    return direction < 0
        ? !lastOfTarget.isBefore(widget.firstDate.dateOnly)
        : !target.isAfter(widget.lastDate.dateOnly);
  }

  void _page(int direction) {
    if (!_canPage(direction)) return;
    setState(() {
      _month = DateTime(_month.year, _month.month + direction);
    });
  }

  void _onDayTapped(DateTime day) {
    // Tapping a trailing/leading cell picks that day AND brings its month into
    // view, so the picker never lands showing a month the selection isn't in.
    if (!isInMonth(day, _month)) {
      setState(() => _month = _monthOf(day));
    }
    widget.onDateSelected(day.dateOnly);
  }

  static double _circleSize(BuildContext context) =>
      math.max(_kCircleMin, MediaQuery.textScalerOf(context).scale(14) * 2);

  static double _cellHeight(BuildContext context) =>
      math.max(_kCellMinHeight, _circleSize(context) + AppSpacing.sp4);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final weekStart = CalendarMonthGrid.weekStartOf(context);
    final labels = weekdayLabelsForLocale(locale);
    // Resolved once for the whole month rather than per cell. The DateFormat
    // itself is memoized, but 42 cells each re-reading the locale and
    // formatting a full long date is real work on a panel that rebuilds on
    // every day tap and on any other form change while it is open.
    final dayLabelFormat = longDateFormatFor(locale);
    final days = monthGridDays(_month, weekStart: weekStart);
    final rows = days.length ~/ 7;
    final cellHeight = _cellHeight(context);
    final circleSize = _circleSize(context);
    final today = _today;

    return GestureDetector(
      // Swipe the month the way the calendar screen's pager and week strip are
      // swiped. The day taps inside still win — a horizontal drag recognizer
      // doesn't claim them.
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity == 0) return;
        _page(velocity < 0 ? 1 : -1);
      },
      child: Padding(
        padding: _kPadding,
        child: AnimatedSize(
          // Months occupy 4–6 weeks, so the panel's height changes as it pages.
          duration: AppMotion.popIn,
          curve: AppMotion.emphasized,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MonthHeader(
                label: monthYearFormatFor(locale).format(_month),
                canGoBack: _canPage(-1),
                canGoForward: _canPage(1),
                onBack: () => _page(-1),
                onForward: () => _page(1),
              ),
              _buildWeekdayLabels(theme, labels),
              const SizedBox(height: AppSpacing.sp4),
              for (var row = 0; row < rows; row++)
                _buildWeekRow(
                  days.skip(row * 7).take(7),
                  cellHeight: cellHeight,
                  circleSize: circleSize,
                  dayLabelFormat: dayLabelFormat,
                  today: today,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWeekdayLabels(ThemeData theme, List<String> labels) {
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  labels[i],
                  style: theme.monoType.fieldLabel.copyWith(
                    color: theme.palette.textMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWeekRow(
    Iterable<DateTime> week, {
    required double cellHeight,
    required double circleSize,
    required DateFormat dayLabelFormat,
    required DateTime today,
  }) {
    return SizedBox(
      height: cellHeight,
      child: Row(
        children: [
          for (final day in week)
            Expanded(
              child: _PickerDayCell(
                day: day,
                month: _month,
                isSelected: _isSelected(day),
                // Never on the selected day: a solid fill under a
                // soft one is just a muddier solid fill, and a
                // one-day job has both ends on it.
                isCompanion: !_isSelected(day) && _isCompanion(day),
                companionLabel: widget.companionLabel,
                isToday: isSameDate(day, today),
                isEnabled: _isEnabled(day),
                circleSize: circleSize,
                dayLabelFormat: dayLabelFormat,
                onTap: _onDayTapped,
              ),
            ),
        ],
      ),
    );
  }
}

/// "August 2026" with the two paging chevrons.
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.label,
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
  });

  final String label;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: AppSpacing.sp4),
            child: Text(
              label,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        _ChevronButton(
          key: const ValueKey('inline-date-prev-month'),
          icon: Icons.chevron_left_rounded,
          tooltip: l10n.calendar_previousMonth,
          onPressed: canGoBack ? onBack : null,
        ),
        _ChevronButton(
          key: const ValueKey('inline-date-next-month'),
          icon: Icons.chevron_right_rounded,
          tooltip: l10n.calendar_nextMonth,
          onPressed: canGoForward ? onForward : null,
        ),
      ],
    );
  }
}

class _ChevronButton extends StatelessWidget {
  const _ChevronButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 24,
      // 40 rather than the 48 floor: two of these sit on one header row beside
      // the month name, and the whole panel is a dropdown inside a form row.
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      color: theme.palette.primaryAccent,
      disabledColor: theme.palette.textFaint,
      icon: Icon(icon),
    );
  }
}

/// One day in the picker. The day being chosen is a filled circle, the other
/// end of the run is a soft fill of the same hue, and today is a RING — the
/// same rule the calendar screen's cells follow.
class _PickerDayCell extends StatelessWidget {
  const _PickerDayCell({
    required this.day,
    required this.month,
    required this.isSelected,
    required this.isCompanion,
    required this.companionLabel,
    required this.isToday,
    required this.isEnabled,
    required this.circleSize,
    required this.dayLabelFormat,
    required this.onTap,
  });

  final DateTime day;
  final DateTime month;
  final bool isSelected;

  /// This day is the OTHER end of the run — see
  /// [InlineMonthCalendar.companionDate].
  final bool isCompanion;
  final String? companionLabel;

  final bool isToday;
  final bool isEnabled;
  final double circleSize;

  /// Resolved once by the month, not per cell — see [InlineMonthCalendar].
  final DateFormat dayLabelFormat;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final inMonth = isInMonth(day, month);

    final numberColor = _numberColor(theme, inMonth);

    final circle = calendarDayTokenWithRule(
      theme: theme,
      set: markerSetOn(day),
      isSelected: isSelected,
      // A disabled or off-month day in the picker reads faint, and the rule
      // fades with it.
      isFaint: !isEnabled || !inMonth,
      // No agenda row under the picker to name the holiday, so a selected day
      // keeps its hue (lifted) rather than going flat white — this is the one
      // surface where the marker can prevent a mis-booking, so it has to say
      // which kind of day it is at the moment the date is chosen.
      keepHueWhenSelected: true,
      token: _buildCircle(scheme, numberColor),
    );

    final cellKey = ValueKey(
      'inline-date-day-${day.year}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}',
    );

    if (!isEnabled) {
      return ExcludeSemantics(
        key: cellKey,
        child: Center(child: circle),
      );
    }

    final dateLabel = dayLabelFormat.format(day);

    return Semantics(
      button: true,
      selected: isSelected,
      // The companion marker is a tint, and a tint says nothing out loud.
      label: isCompanion && companionLabel != null
          ? '$dateLabel, $companionLabel'
          : dateLabel,
      excludeSemantics: true,
      child: InkResponse(
        key: cellKey,
        onTap: () => onTap(day),
        radius: circleSize,
        child: Center(child: circle),
      ),
    );
  }

  Color _numberColor(ThemeData theme, bool inMonth) {
    final scheme = theme.colorScheme;
    if (!isEnabled) return theme.palette.textFaint;
    if (isSelected) return scheme.onPrimary;
    if (isCompanion) return theme.palette.primaryAccent;
    if (!inMonth) return theme.palette.textMuted;
    return scheme.onSurface;
  }

  Widget _buildCircle(ColorScheme scheme, Color numberColor) {
    return Container(
      width: circleSize,
      height: circleSize,
      alignment: Alignment.center,
      decoration: calendarDayCircleDecoration(
        scheme: scheme,
        isSelected: isSelected,
        showTodayRing: isToday,
        // A tint of the SAME hue, never a second colour: this is one run with
        // two ends, not two things to tell apart.
        fill: isCompanion ? scheme.primary.withValues(alpha: 0.16) : null,
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          fontFamily: kFontSans,
          fontSize: 14,
          fontWeight: isSelected || isCompanion || isToday
              ? FontWeight.w700
              : FontWeight.w500,
          color: numberColor,
        ),
      ),
    );
  }
}
