import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_aggregator.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_chip.dart';

/// A non-zero status count paired with its bar/legend color, shared between the
/// bar and legend widgets.
typedef _Segment = (AppointmentStatus status, Color color, int count);

/// Hero summary showing the total, the date, a status bar, and an unassigned
/// warning.
class DashboardHero extends StatelessWidget {
  const DashboardHero({required this.ops, required this.now, super.key});

  final TodayOps ops;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColors = theme.statusColors;
    final l10n = context.l10n;
    final segments = [
      // In progress is `statusColors.accent`, which IS `scheme.primary` — the
      // colour this hero's gradient starts from, so it paints invisible here.
      (AppointmentStatus.inProgress, scheme.onPrimary),
      (AppointmentStatus.overdue, statusColors.overdue),
      (AppointmentStatus.pending, statusColors.warning),
      (AppointmentStatus.done, statusColors.success),
      (AppointmentStatus.cancelled, scheme.error),
    ];
    // Resolve the counts once here and keep only the non-zero ones, so the bar
    // and legend stay in sync.
    final visible = <_Segment>[
      for (final (status, color) in segments)
        if ((ops.statusCounts[DashboardAggregator.statusCountKey(status)] ??
                0) >
            0)
          (
            status,
            color,
            ops.statusCounts[DashboardAggregator.statusCountKey(status)]!,
          ),
    ];
    final total = ops.total;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(AppSpacing.sp16),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp4,
        AppSpacing.sp16,
        AppSpacing.sp16,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        // Raw `Colors.black` below is not a missing token: it composes a SHADE
        // OF the theme's own primary through `alphaBlend`, so it tracks
        // whatever `scheme.primary` is in either theme.
        gradient: LinearGradient(
          colors: [
            scheme.primary,
            Color.alphaBlend(
              Colors.black.withValues(alpha: 0.2),
              scheme.primary,
            ),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: '$total ',
              style: theme.textTheme.headlineLarge?.copyWith(
                color: scheme.onPrimary,
                fontWeight: FontWeight.w700,
              ),
              children: [
                TextSpan(
                  text: l10n.dashboard_visitsToday(total),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onPrimary.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Text(
            DateUtilsHelper.formatDayHeader(now),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onPrimary.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: AppSpacing.sp12),
          _StatusBar(visible: visible, total: total),
          const SizedBox(height: AppSpacing.sp8),
          _StatusLegend(visible: visible),
          if (ops.unassignedCount > 0) ...[
            const SizedBox(height: AppSpacing.sp12),
            _UnassignedBanner(count: ops.unassignedCount),
          ],
        ],
      ),
    );
  }
}

/// A single-row bar sized proportionally to the counts.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.visible, required this.total});

  final List<_Segment> visible;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.rFull),
      child: SizedBox(
        height: 8,
        width: double.infinity,
        child: total == 0
            ? ColoredBox(color: scheme.onPrimary.withValues(alpha: 0.18))
            : Row(
                // A childless ColoredBox takes `constraints.smallest`, and a
                // Row's default centre alignment passes a LOOSE height — so
                // every segment laid out 0 tall and the bar painted nothing.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (_, color, count) in visible)
                    Expanded(
                      flex: count,
                      child: ColoredBox(color: color),
                    ),
                ],
              ),
      ),
    );
  }
}

/// A wrapped row of dot, count, and label for each non-zero status, mirroring
/// [_StatusBar].
class _StatusLegend extends StatelessWidget {
  const _StatusLegend({required this.visible});

  final List<_Segment> visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Wrap(
      spacing: AppSpacing.sp12,
      runSpacing: AppSpacing.sp4,
      children: [
        for (final (status, color, count) in visible)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppSpacing.sp4),
              Text(
                '$count ${statusLabel(l10n, status)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimary,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Attention pill shown only when some of today's visits have no assignee.
class _UnassignedBanner extends StatelessWidget {
  const _UnassignedBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColors = theme.statusColors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp12,
        vertical: AppSpacing.sp4,
      ),
      decoration: BoxDecoration(
        color: scheme.onPrimary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.rFull),
        border: Border.all(color: scheme.onPrimary.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_off_rounded, size: 14, color: statusColors.warning),
          const SizedBox(width: AppSpacing.sp8),
          Flexible(
            child: Text(
              context.l10n.dashboard_unassignedCount(count),
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
