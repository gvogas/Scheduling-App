import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/floating_pill.dart';

/// The "jump to today" pill, hidden once today is already in view.
class TodayPill extends StatelessWidget {
  const TodayPill({required this.visible, required this.onPressed, super.key});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FloatingPill(
      visible: visible,
      tooltip: context.l10n.calendar_today,
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp16,
            vertical: 11,
          ),
          child: Center(
            child: Text(
              context.l10n.calendar_today,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.palette.primaryAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
