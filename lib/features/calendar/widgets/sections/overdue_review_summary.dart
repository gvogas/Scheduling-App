import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The big overdue count, and the oldest date or the selection size.
class OverdueReviewSummary extends StatelessWidget {
  const OverdueReviewSummary({
    required this.count,
    required this.oldest,
    required this.selectedCount,
    super.key,
  });

  final int count;
  final DateTime? oldest;
  final int selectedCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final first = oldest;
    final detail = selectedCount > 0
        ? l10n.calendar_overdueReviewSelected(selectedCount)
        : first == null
        ? null
        : l10n.calendar_overdueReviewOldest(
            DateUtilsHelper.formatMonthDay(first),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$count',
          style: theme.monoType.numeralHero.copyWith(
            color: theme.statusColors.overdue,
          ),
        ),
        const SizedBox(height: AppSpacing.sp4),
        Text(
          l10n.calendar_overdueReviewSummary(count),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: AppSpacing.sp8),
          Text(
            detail,
            style: theme.monoType.data.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ],
      ],
    );
  }
}
