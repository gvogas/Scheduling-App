import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// The two-button footer of a custom dialog: an outlined secondary beside a
/// filled primary, equal width, 44 high.
class DialogActionPair extends StatelessWidget {
  const DialogActionPair({
    required this.secondaryLabel,
    required this.onSecondary,
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryBackgroundColor,
    this.primaryForegroundColor,
    super.key,
  });

  final String secondaryLabel;
  final VoidCallback onSecondary;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final Color? primaryBackgroundColor;
  final Color? primaryForegroundColor;

  static const Size _buttonSize = Size(double.infinity, 44);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: _buttonSize),
            onPressed: onSecondary,
            child: Text(secondaryLabel),
          ),
        ),
        const SizedBox(width: AppSpacing.sp12),
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: _buttonSize,
              backgroundColor: primaryBackgroundColor,
              foregroundColor: primaryForegroundColor,
            ),
            onPressed: onPrimary,
            child: Text(primaryLabel),
          ),
        ),
      ],
    );
  }
}
