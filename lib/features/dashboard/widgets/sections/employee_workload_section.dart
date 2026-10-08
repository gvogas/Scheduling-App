import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// Jobs per active employee with week-share bar.
class EmployeeWorkloadSection extends StatelessWidget {
  const EmployeeWorkloadSection({required this.workload, super.key});

  final List<EmployeeWorkload> workload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    var maxWeek = 0;
    for (final row in workload) {
      if (row.weekCount > maxWeek) maxWeek = row.weekCount;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l10n.dashboard_employeeWorkload),
        const SizedBox(height: AppSpacing.sp8),
        if (workload.isEmpty)
          Text(
            l10n.dashboard_noActiveEmployees,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Container(
            decoration: appCardDecoration(theme, color: scheme.surface),
            padding: const EdgeInsets.all(AppSpacing.sp12),
            child: Column(
              children: [
                for (var i = 0; i < workload.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == workload.length - 1 ? 0 : AppSpacing.sp12,
                    ),
                    child: _WorkloadRow(row: workload[i], maxWeek: maxWeek),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _WorkloadRow extends StatelessWidget {
  const _WorkloadRow({required this.row, required this.maxWeek});

  final EmployeeWorkload row;
  final int maxWeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fillFraction = maxWeek == 0
        ? 0.0
        : (row.weekCount / maxWeek).clamp(0.0, 1.0);
    return Row(
      children: [
        AppAvatar(
          name: row.employee.name,
          color: row.employee.color,
          size: AvatarSize.sm,
        ),
        const SizedBox(width: AppSpacing.sp12),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.employee.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.sp4),
              Container(
                height: 6,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.rFull),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fillFraction,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: row.employee.color,
                      borderRadius: BorderRadius.circular(AppRadius.rFull),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sp12),
        Flexible(
          child: Text(
            context.l10n.dashboard_workloadCounts(
              row.todayCount,
              row.weekCount,
            ),
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
