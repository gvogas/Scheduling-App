import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/features/dashboard/widgets/charts/weekly_bar_chart.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// Trends card with a done/cancelled chart and a busiest-weekday row.
///
/// Its span is named in its own title ("last 8 weeks") and is deliberately NOT
/// scoped by the dashboard's period control — see `PeriodSummarySection`.
/// New clients moved to their own section when they gained tappable rows.
class BusinessTrendsSection extends StatelessWidget {
  const BusinessTrendsSection({
    required this.buckets,
    required this.busiestWeekday,
    super.key,
  });

  final List<WeekBucket> buckets;
  final BusiestWeekday? busiestWeekday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColors = theme.statusColors;
    final l10n = context.l10n;
    final busiest = busiestWeekday;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l10n.dashboard_businessTrends),
        const SizedBox(height: AppSpacing.sp8),
        _buildChartCard(theme, scheme, statusColors, l10n),
        if (busiest != null) ...[
          const SizedBox(height: AppSpacing.sp16),
          Row(
            children: [
              Icon(Icons.event_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: AppSpacing.sp8),
              Expanded(
                child: Text(
                  l10n.dashboard_busiestWeekday(
                    _weekdayName(context, busiest.weekday),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildChartCard(
    ThemeData theme,
    ColorScheme scheme,
    AppStatusColors statusColors,
    AppLocalizations l10n,
  ) {
    return Container(
      decoration: appCardDecoration(theme, color: scheme.surface),
      padding: const EdgeInsets.all(AppSpacing.sp16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.dashboard_completedVsCancelled,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.sp12),
          WeeklyBarChart(
            weekStarts: [for (final b in buckets) b.weekStart],
            series: [
              WeeklyBarSeries(
                values: [for (final b in buckets) b.completed],
                color: statusColors.success,
                label: statusLabel(l10n, AppointmentStatus.done),
              ),
              WeeklyBarSeries(
                values: [for (final b in buckets) b.cancelled],
                color: scheme.error,
                label: statusLabel(l10n, AppointmentStatus.cancelled),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Localized full weekday name — 2024-01-01 is a Monday, so day N of that
  /// month is ISO weekday N.
  String _weekdayName(BuildContext context, int weekday) {
    final locale = Localizations.localeOf(context).toString();
    return DateFormat('EEEE', locale).format(DateTime(2024, 1, weekday));
  }
}
