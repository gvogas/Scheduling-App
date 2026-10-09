import 'package:flutter/material.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

/// Tooltip action pill; text scale is capped (1× when compact) because the
/// package lays the actions out in a non-flexing Row.
class TourActionButton extends StatelessWidget {
  const TourActionButton({
    required this.label,
    required this.style,
    required this.onTap,
    this.fill,
    this.compactIcon,
    super.key,
  });

  final String label;
  final TextStyle? style;
  final VoidCallback onTap;
  final Color? fill;

  /// Shown instead of [label] when compact; [label] stays the semantic name.
  final IconData? compactIcon;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: compact ? 1 : kTourActionMaxTextScale,
      child: Material(
        color: fill ?? Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.rFull),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.rFull),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? AppSpacing.sp8 : AppSpacing.sp16,
              vertical: AppSpacing.sp8,
            ),
            child: compact && compactIcon != null
                ? Semantics(
                    label: label,
                    button: true,
                    excludeSemantics: true,
                    child: Icon(compactIcon, color: style?.color),
                  )
                : Text(label, style: style),
          ),
        ),
      ),
    );
  }
}

const kTourActionMaxTextScale = 1.2;
