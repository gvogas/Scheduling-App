import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Not done / Complete for the ticked jobs, shown only while any are ticked.
class OverdueReviewActionBar extends StatelessWidget {
  const OverdueReviewActionBar({
    required this.count,
    required this.isBusy,
    required this.onComplete,
    required this.onNotDone,
    super.key,
  });

  final int count;
  final bool isBusy;
  final VoidCallback onComplete;
  final VoidCallback onNotDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    const minimumSize = Size.fromHeight(48);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp16,
            vertical: AppSpacing.sp12,
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: destructiveOutlinedButtonStyle(
                    context,
                    minimumSize: minimumSize,
                  ),
                  onPressed: isBusy ? null : onNotDone,
                  child: Text(
                    l10n.calendar_overdueReviewNotDoneCount(count),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sp12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: minimumSize),
                  onPressed: isBusy ? null : onComplete,
                  child: Text(
                    l10n.calendar_overdueReviewCompleteCount(count),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
