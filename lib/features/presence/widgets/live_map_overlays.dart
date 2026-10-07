import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// Stacked traffic and satellite toggles, filled while on.
class MapToggles extends StatelessWidget {
  const MapToggles({
    required this.traffic,
    required this.satellite,
    required this.onTrafficToggle,
    required this.onSatelliteToggle,
    super.key,
  });

  final bool traffic;
  final bool satellite;
  final VoidCallback onTrafficToggle;
  final VoidCallback onSatelliteToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MapGhostIcon(
          icon: Icons.traffic_outlined,
          tooltip: context.l10n.liveMap_trafficToggle,
          toggled: traffic,
          onTap: onTrafficToggle,
        ),
        MapGhostIcon(
          icon: Icons.layers_outlined,
          tooltip: context.l10n.liveMap_satelliteToggle,
          toggled: satellite,
          onTap: onSatelliteToggle,
        ),
      ],
    );
  }
}

/// A ghost tile that floats over the map, so it carries the pill shadow the
/// plain ghost tone has none of.
class MapGhostIcon extends StatelessWidget {
  const MapGhostIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.toggled,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// Null for a one-shot action; a toggle paints active while true.
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      toggled: toggled,
      child: Stack(
        alignment: Alignment.center,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: theme.cardStyle.pillShadow,
            ),
            child: const SizedBox.square(dimension: kGhostTile),
          ),
          GhostControl.icon(
            onTap: onTap,
            icon: icon,
            tooltip: tooltip,
            tone: toggled ?? false ? GhostTone.active : GhostTone.ghost,
          ),
        ],
      ),
    );
  }
}

class EmptyMapCard extends StatelessWidget {
  const EmptyMapCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.r16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        boxShadow: theme.cardStyle.pillShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sp16),
        child: Text(
          context.l10n.liveMap_emptyState,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class LiveMapLoadingBody extends StatelessWidget {
  const LiveMapLoadingBody({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: AdaptiveProgressIndicator(size: 32));
}
