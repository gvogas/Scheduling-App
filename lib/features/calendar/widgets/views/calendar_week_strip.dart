import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/calendar/domain/holidays.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_day_circle.dart';

/// Design metrics (`03-screens-schedule.md`). 1.0-scale FLOORS — the real
/// height derives from the scaled day number, exactly like the month grid.
const double _kStripCellMinHeight = 56;
const double _kStripCircleMin = 30;
const double _kStripDot = 4.5;
const double _kStripDotGap = 3;

/// The selected day's week, shown inside the fixed header once the month grid
/// collapses. One dot per day rather than the grid's three: the strip is a
/// wayfinding aid, not a density read.
class CalendarWeekStrip extends StatelessWidget {
  const CalendarWeekStrip({
    required this.weekDays,
    required this.selectedDay,
    required this.today,
    required this.onDaySelected,
    required this.dotColorsFor,
    super.key,
  });

  final List<DateTime> weekDays;
  final DateTime selectedDay;

  /// Today, from `currentDayProvider` — never a bare `DateTime.now()`.
  final DateTime today;
  final ValueChanged<DateTime> onDaySelected;

  /// The day's dot colours, capped at one — same shape as the month grid's so
  /// both read the one `dayJobDotColors`. Empty means no work at all; a single
  /// null entry means work whose lead assignee has no colour, which still earns
  /// a (neutral) dot.
  final List<Color?> Function(DateTime day) dotColorsFor;

  static double _circleSize(BuildContext context) => math.max(
    _kStripCircleMin,
    MediaQuery.textScalerOf(context).scale(14.5) * 2,
  );

  /// The painted body height, excluding the leading gap. Self-sizing on
  /// purpose: the strip rises inside the header's `AnimatedSwitcher` and the
  /// two-viewport collapse (P2) has no vacated extent to hold, so nothing
  /// outside this widget needs to predict how tall it will be.
  static double _bodyHeight(BuildContext context) => math.max(
    _kStripCellMinHeight,
    _circleSize(context) +
        MediaQuery.textScalerOf(context).scale(9.5) +
        AppSpacing.sp4 +
        _kStripDot +
        _kStripDotGap,
  );

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final abbrev = weekdayAbbrevFormatFor(locale);
    final circle = _circleSize(context);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sp8),
      child: SizedBox(
        height: _bodyHeight(context),
        child: Row(
          children: [
            for (final day in weekDays)
              Expanded(
                child: _StripCell(
                  day: day,
                  isSelected: isSameDate(day, selectedDay),
                  isToday: isSameDate(day, today),
                  label: abbrev.format(day).toUpperCase(),
                  circleSize: circle,
                  dotColors: dotColorsFor(day),
                  onTap: onDaySelected,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StripCell extends StatelessWidget {
  const _StripCell({
    required this.day,
    required this.isSelected,
    required this.isToday,
    required this.label,
    required this.circleSize,
    required this.dotColors,
    required this.onTap,
  });

  final DateTime day;
  final bool isSelected;
  final bool isToday;
  final String label;
  final double circleSize;
  final List<Color?> dotColors;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      button: true,
      selected: isSelected,
      label: longDateFormatFor(
        Localizations.localeOf(context).toString(),
      ).format(day),
      excludeSemantics: true,
      child: InkResponse(
        key: ValueKey(
          'calendar-strip-day-${day.year}-'
          '${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}',
        ),
        onTap: () => onTap(day.dateOnly),
        radius: circleSize,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              style: theme.monoType.micro.copyWith(
                color: theme.palette.textMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.sp4),
            calendarDayTokenWithRule(
              theme: theme,
              set: markerSetOn(day),
              isSelected: isSelected,
              // Every day in the strip belongs to the week on screen, so
              // nothing here is off-month and nothing fades.
              isFaint: false,
              token: _buildCircle(scheme),
            ),
            _buildDot(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildCircle(ColorScheme scheme) {
    return Container(
      width: circleSize,
      height: circleSize,
      alignment: Alignment.center,
      decoration: calendarDayCircleDecoration(
        scheme: scheme,
        isSelected: isSelected,
        showTodayRing: isToday,
      ),
      child: Text(
        '${day.day}',
        style: TextStyle(
          fontFamily: kFontSans,
          fontSize: 14.5,
          fontWeight: isSelected || isToday ? FontWeight.w700 : FontWeight.w500,
          color: isSelected ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );
  }

  Widget _buildDot(ThemeData theme) {
    return SizedBox(
      height: _kStripDot + _kStripDotGap,
      // Kept on the selected day too, like the month grid's cells (ADR-0152).
      child: dotColors.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: _kStripDotGap),
              child: Container(
                key: const ValueKey('calendar-strip-dot'),
                width: _kStripDot,
                height: _kStripDot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColors.first == null
                      ? theme.palette.textFaint
                      : crewColorOf(theme, dotColors.first!.toARGB32()),
                ),
              ),
            ),
    );
  }
}
