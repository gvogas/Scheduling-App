import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/features/maps/address_map_launcher.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/features/presence/widgets/live_map_labels.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// The selected person, at the top of the team sheet.
class StaffFocusPanel extends ConsumerWidget {
  const StaffFocusPanel({
    required this.point,
    required this.now,
    required this.distanceMeters,
    required this.onClose,
    super.key,
  });

  final StaffMapPoint point;
  final DateTime now;

  /// Null for the viewer's own pin, or when they have no pin to measure from.
  final double? distanceMeters;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final addressAsync = ref.watch(
      reverseGeocodeProvider(
        ReverseGeocodeQuery(
          lat: point.lat,
          lng: point.lng,
          locale: serverLocaleOf(Localizations.localeOf(context).languageCode),
        ),
      ),
    );
    final address = addressAsync.value;
    final meta = [
      freshnessLabel(l10n, point.updatedAt, now),
      if (distanceMeters case final meters?) distanceLabel(context, meters),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp8,
        AppSpacing.sp4,
        AppSpacing.sp8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(name: point.name, color: point.color),
              const SizedBox(width: AppSpacing.sp12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      point.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sp4),
                    Text(
                      meta,
                      style: theme.monoType.data.copyWith(
                        color: theme.palette.textTertiary,
                      ),
                    ),
                    if (addressAsync.isLoading)
                      _AddressText(l10n.liveMap_resolvingAddress, muted: true)
                    else if (address != null && address.isNotEmpty)
                      _AddressText(address),
                  ],
                ),
              ),
              GhostControl.icon(
                onTap: onClose,
                icon: Icons.close_rounded,
                tooltip: MaterialLocalizations.of(context).closeButtonLabel,
              ),
            ],
          ),
          GhostControl.pill(
            onTap: () => AddressMapLauncher.showMapChoices(
              context,
              ref,
              address: address?.isNotEmpty ?? false
                  ? address!
                  : '${point.lat},${point.lng}',
            ),
            label: l10n.liveMap_openInMaps,
            icon: Icons.directions_outlined,
            tone: GhostTone.accent,
          ),
        ],
      ),
    );
  }
}

class _AddressText extends StatelessWidget {
  const _AddressText(this.text, {this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sp4),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: muted
              ? theme.palette.textTertiary
              : theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}
