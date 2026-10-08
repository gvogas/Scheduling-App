import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

/// Tooltip action pill; text scale is capped because the package lays the
/// actions out in a non-flexing Row.
class TourActionButton extends StatelessWidget {
  const TourActionButton({
    required this.label,
    required this.style,
    required this.onTap,
    this.fill,
    super.key,
  });

  final String label;
  final TextStyle? style;
  final VoidCallback onTap;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kTourActionMaxTextScale,
      child: Material(
        color: fill ?? Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.rFull),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.rFull),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sp16,
              vertical: AppSpacing.sp8,
            ),
            child: Text(label, style: style),
          ),
        ),
      ),
    );
  }
}

const kTourActionMaxTextScale = 1.2;
