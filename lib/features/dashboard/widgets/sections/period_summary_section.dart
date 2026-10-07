import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/dashboard/application/dashboard_providers.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_period.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// The KPI tiles and the Today/Week/Month control that scopes them.
///
/// **Only these numbers move with the period.** The charts below carry their
/// own span in their titles ("last 8 weeks", "next 7 days") and the "right
/// now" sections — hero, Upcoming today, workload, Attention — answer a
/// different question entirely. Attention especially: it is the one reducer
/// with no range predicate, and clipping it to a period would drop the oldest
/// and most neglected work from the list whose whole job is to surface it.
class PeriodSummarySection extends ConsumerWidget {
  const PeriodSummarySection({required this.summary, super.key});

  final PeriodSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final period = ref.watch(dashboardPeriodProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l10n.dashboard_summary),
        const SizedBox(height: AppSpacing.sp8),
        _PeriodControl(
          selected: period,
          onSelected: (next) =>
              ref.read(dashboardPeriodProvider.notifier).select(next),
        ),
        const SizedBox(height: AppSpacing.sp12),
        _KpiGrid(
          tiles: [
            (
              label: l10n.dashboard_kpiBooked,
              value: summary.booked,
              tint: null,
            ),
            (
              label: l10n.dashboard_kpiCompleted,
              value: summary.completed,
              tint: theme.statusColors.success,
            ),
            (
              label: l10n.dashboard_kpiCancelled,
              value: summary.cancelled,
              tint: theme.colorScheme.error,
            ),
            (
              label: l10n.dashboard_newClients,
              value: summary.newClients,
              tint: null,
            ),
          ],
        ),
      ],
    );
  }
}

class _PeriodControl extends StatelessWidget {
  const _PeriodControl({required this.selected, required this.onSelected});

  final DashboardPeriod selected;
  final ValueChanged<DashboardPeriod> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.dashboard_periodLabel,
      child: SegmentedButton<DashboardPeriod>(
        segments: [
          for (final period in DashboardPeriod.values)
            ButtonSegment<DashboardPeriod>(
              value: period,
              label: Text(_labelFor(l10n, period)),
            ),
        ],
        selected: {selected},
        showSelectedIcon: false,
        onSelectionChanged: (selection) => onSelected(selection.first),
      ),
    );
  }

  String _labelFor(AppLocalizations l10n, DashboardPeriod period) =>
      switch (period) {
        DashboardPeriod.today => l10n.dashboard_periodToday,
        DashboardPeriod.week => l10n.dashboard_periodWeek,
        DashboardPeriod.month => l10n.dashboard_periodMonth,
      };
}

typedef _KpiTile = ({String label, int value, Color? tint});

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.tiles});

  final List<_KpiTile> tiles;

  @override
  Widget build(BuildContext context) {
    // Four tiles across two rows on a phone, one row when there is width for
    // it. A GridView would need its own scroll physics inside the dashboard's
    // ListView; a Wrap of fixed-fraction tiles does not.
    final columns = context.isWide ? 4 : 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = AppSpacing.sp8;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: width,
                child: _KpiCard(tile: tile),
              ),
          ],
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.tile});

  final _KpiTile tile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: appCardDecoration(theme, color: theme.colorScheme.surface),
      padding: const EdgeInsets.all(AppSpacing.sp12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${tile.value}',
            style: theme.monoType.numeralKpi.copyWith(color: tile.tint),
          ),
          const SizedBox(height: AppSpacing.sp4),
          Text(
            tile.label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
