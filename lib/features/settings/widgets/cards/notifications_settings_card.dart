import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/notifications/push_notification_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/live_activity/application/live_activity_preference.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/settings/widgets/cards/settings_tiles.dart';
import 'package:scheduling/l10n/l10n.dart';

/// OS-notification and Live Activity rows.
class NotificationsSettingsCard extends ConsumerWidget {
  const NotificationsSettingsCard({
    required this.onNotificationsTap,
    required this.liveActivityEnabled,
    required this.onToggleLiveActivity,
    required this.travelAlertsEnabled,
    required this.onToggleTravelAlerts,
    required this.locationSharingEnabled,
    required this.onLocationSharingTap,
    required this.onToggleLocationSharing,
    this.isTogglingLiveActivity = false,
    this.isTogglingTravelAlerts = false,
    this.isTogglingLocationSharing = false,
    this.tourWrap,
    super.key,
  });

  final void Function(AuthorizationStatus status) onNotificationsTap;
  final bool liveActivityEnabled;
  final void Function({required bool value}) onToggleLiveActivity;
  final bool isTogglingLiveActivity;

  /// Null while the person's own record is still loading, which hides the row
  /// rather than rendering a switch in a state that may be wrong.
  final bool? travelAlertsEnabled;
  final void Function({required bool value}) onToggleTravelAlerts;
  final bool isTogglingTravelAlerts;
  final bool? locationSharingEnabled;
  final VoidCallback onLocationSharingTap;
  final void Function({required bool value}) onToggleLocationSharing;
  final bool isTogglingLocationSharing;

  /// Lets the Settings tour wrap a row as its own step. Null off-tour, so the
  /// card stays usable untoured. Keyed by step id rather than named per row,
  /// so a second toured row here costs a call, not a parameter.
  final Widget Function(TourStepId, Widget)? tourWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Default to notDetermined so the row offers enable rather than a misleading "On".
    final status =
        ref.watch(notificationAuthStatusProvider).asData?.value ??
        AuthorizationStatus.notDetermined;
    final granted = PushNotificationService.isGranted(status);
    final liveActivityReady = ref
        .watch(liveActivityPreferenceReadyProvider)
        .hasValue;
    // Hidden when the device/OS version can't host a Live Activity card.
    final showLiveActivity =
        (ref.watch(liveActivitySupportedProvider).asData?.value ?? false) &&
        liveActivityReady;
    final showTravelAlerts = travelAlertsEnabled != null;
    final showLocationSharing = locationSharingEnabled != null;
    // Held as a local so the tour's wrap can be applied to it by name.
    final locationTile = showLocationSharing
        ? _buildLocationTile(context, scheme)
        : null;
    // Dividers are indexed off this list, so a new row never has to be
    // threaded through every earlier row's "am I last" condition.
    final tiles = <Widget>[
      _buildNotificationsTile(context, scheme, status, granted),
      if (showLiveActivity)
        SettingsSwitchTile(
          icon: Icons.directions_car_rounded,
          label: context.l10n.settings_liveActivity,
          value: liveActivityEnabled,
          isBusy: isTogglingLiveActivity,
          onChanged: onToggleLiveActivity,
        ),
      if (showTravelAlerts)
        SettingsSwitchTile(
          switchKey: const Key('travelAlertsSwitch'),
          icon: Icons.schedule_send_rounded,
          label: context.l10n.settings_travelAlerts,
          value: travelAlertsEnabled!,
          isBusy: isTogglingTravelAlerts,
          onChanged: onToggleTravelAlerts,
        ),
      if (locationTile != null)
        tourWrap?.call(TourStepId.settingsLocationSharing, locationTile) ??
            locationTile,
    ];
    return SettingsSectionCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, tile) in tiles.indexed) ...[
            if (index > 0) const SettingsTileDivider(),
            tile,
          ],
        ],
      ),
    );
  }

  SettingsSwitchTile _buildLocationTile(
    BuildContext context,
    ColorScheme scheme,
  ) {
    return SettingsSwitchTile(
      switchKey: const Key('locationSharingSwitch'),
      icon: Icons.location_on_rounded,
      label: context.l10n.settings_locationSharing,
      value: locationSharingEnabled!,
      isBusy: isTogglingLocationSharing,
      onChanged: onToggleLocationSharing,
      // The row opens the detail screen; only the switch flips sharing.
      onTap: onLocationSharingTap,
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildNotificationsTile(
    BuildContext context,
    ColorScheme scheme,
    AuthorizationStatus status,
    bool granted,
  ) {
    return SettingsTile(
      iconBg: granted ? scheme.primaryContainer : scheme.errorContainer,
      icon: granted
          ? Icons.notifications_active_rounded
          : Icons.notifications_off_rounded,
      iconColor: granted ? scheme.primary : scheme.error,
      label: context.l10n.settings_notifications,
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.sp4,
        runSpacing: AppSpacing.sp4,
        children: [
          SettingsTrailingPill(
            label: granted
                ? context.l10n.settings_notificationsOn
                : context.l10n.settings_notificationsOff,
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
      onTap: () => onNotificationsTap(status),
    );
  }
}
