import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/l10n/l10n.dart';

/// "JULY 2026 · 2" over a hairline, with a per-month Select all / Clear.
class OverdueMonthSplitter extends StatelessWidget {
  const OverdueMonthSplitter({
    required this.month,
    required this.count,
    required this.allSelected,
    required this.onToggleAll,
    super.key,
  });

  final DateTime month;
  final int count;
  final bool allSelected;

  /// Called with true to tick the whole month, false to clear it.
  final ValueChanged<bool> onToggleAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sp8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                l10n.calendar_overdueReviewMonthSplitter(
                  DateUtilsHelper.formatMonthYear(month).toUpperCase(),
                  count,
                ),
                style: theme.monoType.groupLabel.copyWith(
                  color: theme.palette.textMuted,
                ),
              ),
              TextButton(
                onPressed: () => onToggleAll(!allSelected),
                child: Text(
                  allSelected
                      ? l10n.calendar_overdueReviewClear
                      : l10n.calendar_overdueReviewSelectAll,
                ),
              ),
            ],
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: AppSpacing.sp8),
        ],
      ),
    );
  }
}
