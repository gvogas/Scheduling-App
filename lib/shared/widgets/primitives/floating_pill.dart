import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// A floating rounded control that scales and fades out while hidden, staying
/// mounted so the transition animates both ways.
class FloatingPill extends StatelessWidget {
  const FloatingPill({
    required this.visible,
    required this.tooltip,
    required this.onTap,
    required this.child,
    super.key,
  });

  final bool visible;
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instant = MediaQuery.disableAnimationsOf(context);
    final radius = BorderRadius.circular(AppRadius.rFull);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0.85,
        duration: instant ? Duration.zero : AppMotion.popIn,
        curve: AppMotion.emphasized,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: instant ? Duration.zero : AppMotion.popIn,
          child: Tooltip(
            message: tooltip,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: theme.cardStyle.pillShadow,
              ),
              child: Material(
                color: theme.colorScheme.surface,
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: InkWell(onTap: onTap, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
