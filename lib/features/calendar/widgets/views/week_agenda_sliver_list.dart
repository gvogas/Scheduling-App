import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/holidays.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/widgets/views/agenda_sliver_list.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The whole selected week, day by day: a pinned day bar over each day's agenda
/// rows.
List<Widget> weekAgendaSlivers(
  BuildContext context, {
  required List<DateTime> days,
  required List<AppointmentDaySlice> Function(DateTime day) eventsFor,
  required DateTime today,
  required ValueChanged<DateTime> onDaySelected,
  required Map<String, String> nameMap,
  required Map<String, Color> colorMap,
  bool isAdmin = true,
  bool isLoading = false,
  bool hasError = false,
  VoidCallback? onRetry,
  double bottomClearance = 0,
}) {
  if (hasError) return [AgendaSliverList.errorState(context, onRetry: onRetry)];
  if (isLoading) return const [SliverToBoxAdapter(child: AgendaSkeleton())];
  // Memoized per locale; never a DateFormat constructor inside a builder.
  final weekdayFormat = weekdayAbbrevFormatFor(
    Localizations.localeOf(context).toString(),
  );
  final extent = WeekDayBar.extentFor(context);
  return [
    for (final day in days)
      SliverMainAxisGroup(
        slivers: [
          SliverPersistentHeader(
            delegate: WeekDayBar(
              day: day,
              weekdayLabel: weekdayFormat.format(day).toUpperCase(),
              jobCount: eventsFor(
                day,
              ).where((slice) => countsAsWork(slice.appointment)).length,
              isToday: isSameDate(day, today),
              extent: extent,
              onTap: () => onDaySelected(day),
            ),
          ),
          if (holidaysOn(day) case final holidays when holidays.isNotEmpty)
            AgendaSliverList.holidayRows(holidays),
          AgendaSliverList(
            events: eventsFor(day),
            day: day,
            nameMap: nameMap,
            colorMap: colorMap,
            isAdmin: isAdmin,
            inWeek: true,
          ),
        ],
      ),
    SliverToBoxAdapter(child: SizedBox(height: bottomClearance)),
  ];
}

/// The pinned `MON 1 · 3 JOBS` bar over one day of the week agenda.
class WeekDayBar extends SliverPersistentHeaderDelegate {
  WeekDayBar({
    required this.day,
    required this.weekdayLabel,
    required this.jobCount,
    required this.isToday,
    required this.extent,
    required this.onTap,
  });

  final DateTime day;
  final String weekdayLabel;
  final int jobCount;
  final bool isToday;
  final double extent;
  final VoidCallback onTap;

  /// The bar's height at scale 1, before the text scaler is applied.
  static const double baseExtent = 40;

  /// A persistent header's extent is a number, not a layout, so it is sized
  /// against the text scaler by the caller.
  static double extentFor(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(baseExtent);

  /// The finder key of [day]'s bar.
  static Key keyFor(DateTime day) =>
      ValueKey('week-day-bar-${day.year}-${day.month}-${day.day}');

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Today is the accent, the rest read as headings — colour is never the only
    // cue, since the number is also bold.
    final dayColor = isToday ? scheme.primary : scheme.onSurface;
    return Material(
      // Opaque on purpose: pinned, it scrolls over the rows beneath it.
      color: theme.scaffoldBackgroundColor,
      child: InkWell(
        key: keyFor(day),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
          child: Row(
            children: [
              Text(
                weekdayLabel,
                style: theme.monoType.label.copyWith(
                  color: isToday ? scheme.primary : theme.palette.textTertiary,
                ),
              ),
              const SizedBox(width: AppSpacing.sp8),
              Text(
                '${day.day}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: dayColor,
                ),
              ),
              const Spacer(),
              Text(
                context.l10n.calendar_jobsCount(jobCount),
                style: theme.monoType.data,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant WeekDayBar oldDelegate) =>
      oldDelegate.day != day ||
      oldDelegate.weekdayLabel != weekdayLabel ||
      oldDelegate.jobCount != jobCount ||
      oldDelegate.isToday != isToday ||
      oldDelegate.extent != extent;
}
