import 'package:flutter/material.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/widgets/tour_action_button.dart';
import 'package:scheduling/features/feature_tour/widgets/tour_step_text.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:showcaseview/showcaseview.dart';

/// One tour step: themed Showcase with index/count.
class TourShowcase extends StatelessWidget {
  const TourShowcase({
    required this.showcaseKey,
    required this.scope,
    required this.id,
    required this.index,
    required this.count,
    required this.child,
    this.targetBorderRadius,
    super.key,
  });

  final GlobalKey showcaseKey;
  final TourScope scope;
  final TourStepId id;
  final int index;
  final int count;

  /// Target cutout rounding; defaults to r12.
  final BorderRadius? targetBorderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = tourStepText(context.l10n, id);
    final noMotion = MediaQuery.disableAnimationsOf(context);
    // showcaseview's action Row can't flex; drop the counter when it won't fit.
    final showCounter = !context.isNarrowWidth;
    return Showcase(
      key: showcaseKey,
      scope: scope.storageKey,
      title: text.title,
      description: text.description,
      titleTextStyle: theme.textTheme.titleMedium?.copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
      ),
      descTextStyle: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      tooltipBackgroundColor: scheme.surface,
      tooltipBorderRadius: BorderRadius.circular(AppRadius.r16),
      tooltipPadding: const EdgeInsets.all(AppSpacing.sp16),
      targetBorderRadius:
          targetBorderRadius ?? BorderRadius.circular(AppRadius.r12),
      targetPadding: const EdgeInsets.all(AppSpacing.sp4),
      overlayColor: scheme.scrim,
      overlayOpacity: 0.62,
      disableMovingAnimation: noMotion,
      disableScaleAnimation: noMotion,
      // Package defaults already give position: inside + spaceBetween.
      tooltipActionConfig: const TooltipActionConfig(actionGap: AppSpacing.sp8),
      tooltipActions: _buildActions(context, theme, scheme, showCounter),
      child: child,
    );
  }

  List<TooltipActionButton> _buildActions(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    bool showCounter,
  ) {
    return [
      if (showCounter)
        TooltipActionButton.custom(
          button: MediaQuery.withClampedTextScaling(
            maxScaleFactor: kTourActionMaxTextScale,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp8),
              child: Text(
                context.l10n.tour_stepCounter(index + 1, count),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      TooltipActionButton.custom(
        button: TourActionButton(
          label: context.l10n.tour_skip,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
          compactIcon: Icons.close,
          onTap: () => ShowcaseView.getNamed(scope.storageKey).dismiss(),
        ),
      ),
      TooltipActionButton.custom(
        button: TourActionButton(
          label: context.l10n.tour_next,
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary),
          fill: scheme.primary,
          onTap: () =>
              ShowcaseView.getNamed(scope.storageKey).next(force: true),
        ),
      ),
    ];
  }
}

/// [TourShowcase] adapter for `AppTopBar.bottom`, which requires a
/// [PreferredSizeWidget] that a bare Showcase wrapper would break.
class TourShowcaseBar extends StatelessWidget implements PreferredSizeWidget {
  const TourShowcaseBar({
    required this.showcaseKey,
    required this.scope,
    required this.id,
    required this.index,
    required this.count,
    required this.bar,
    super.key,
  });

  final GlobalKey showcaseKey;
  final TourScope scope;
  final TourStepId id;
  final int index;
  final int count;
  final PreferredSizeWidget bar;

  @override
  Size get preferredSize => bar.preferredSize;

  @override
  Widget build(BuildContext context) => TourShowcase(
    showcaseKey: showcaseKey,
    scope: scope,
    id: id,
    index: index,
    count: count,
    child: bar,
  );
}
