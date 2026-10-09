import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feature_paused_notice.dart';

class LocationSharingView extends ConsumerStatefulWidget {
  const LocationSharingView({super.key, this.onApplied});

  final VoidCallback? onApplied;

  @override
  ConsumerState<LocationSharingView> createState() =>
      _LocationSharingViewState();
}

class _LocationSharingViewState extends ConsumerState<LocationSharingView> {
  bool? _pendingValue;

  Future<void> _setLocationSharing({required bool value}) async {
    if (_pendingValue != null) return;
    final record = ref.read(myEmployeeRecordProvider);
    if (record == null) return;

    setState(() => _pendingValue = value);
    try {
      if (await saveLocationSharing(context, ref, record, enabled: value)) {
        widget.onApplied?.call();
      }
    } finally {
      if (mounted) setState(() => _pendingValue = null);
    }
  }

  Future<void> _clearLocation() async {
    if (_pendingValue != null) return;
    final record = ref.read(myEmployeeRecordProvider);
    if (record == null) return;

    final l10n = context.l10n;
    final notices = ref.read(noticeServiceProvider);
    final logger = ref.read(loggerProvider);
    if (guardedOffline(
      context,
      ref,
      intro: l10n.error_introSaveLocationSharing,
    )) {
      return;
    }

    setState(() => _pendingValue = false);
    try {
      if (record.locationSharingEnabled) {
        await applyLocationSharing(ref, record, enabled: false);
      }
      final cleared = await ref
          .read(presenceSyncControllerProvider)
          .unregister();
      if (!mounted) return;
      // Sharing is off either way; only the ERASED half can fail, and this
      // screen must not claim it when it did not happen.
      notices.success(
        cleared ? l10n.settings_locationCleared : l10n.settings_locationPaused,
      );
      widget.onApplied?.call();
    } catch (error, stackTrace) {
      logger.warn('ME-SAVE clear location failed', error, stackTrace);
      if (!mounted) return;
      notices.error(
        composeErrorNotice(
          context,
          intro: l10n.error_introSaveLocationSharing,
          error: error,
        ),
      );
    } finally {
      if (mounted) setState(() => _pendingValue = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final record = ref.watch(myEmployeeRecordProvider);
    final enabled = _pendingValue ?? record?.locationSharingEnabled ?? false;
    final paused = !ref.watch(featureFlagsProvider.select((f) => f.presence));
    final isBusy = _pendingValue != null || record == null;
    final fix = ref.watch(myPresenceFixProvider);
    final lastUploaded = fix.when(
      data: (value) => _formatUploadedAt(context, value?.updatedAt),
      loading: () => context.l10n.settings_locationLoading,
      error: (_, _) => context.l10n.settings_locationUnavailable,
    );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.sp16),
      children: [
        if (paused)
          FeaturePausedNotice(message: context.l10n.common_featurePaused),
        _buildStatusPanel(
          context,
          scheme,
          enabled,
          isBusy,
          paused,
          lastUploaded,
        ),
        const SizedBox(height: AppSpacing.sp12),
        Text(
          context.l10n.settings_locationSharingBlurb,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp24),
        OutlinedButton.icon(
          key: const Key('clearLocationButton'),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.error,
            side: BorderSide(color: scheme.error),
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.r12),
            ),
          ),
          onPressed: isBusy ? null : _clearLocation,
          icon: isBusy
              ? const SizedBox.square(
                  dimension: 18,
                  child: AdaptiveProgressIndicator(),
                )
              : const Icon(Icons.location_disabled_rounded),
          label: Text(context.l10n.settings_clearMyLocation),
        ),
      ],
    );
  }

  Widget _buildStatusPanel(
    BuildContext context,
    ColorScheme scheme,
    bool enabled,
    bool isBusy,
    bool paused,
    String lastUploaded,
  ) {
    return _Panel(
      child: Column(
        children: [
          _StatusRow(
            icon: Icons.location_on_rounded,
            label: context.l10n.settings_locationSharing,
            value: enabled
                ? context.l10n.settings_notificationsOn
                : context.l10n.settings_notificationsOff,
            trailing: Switch.adaptive(
              key: const Key('locationSharingPrivacySwitch'),
              value: enabled,
              onChanged: isBusy || paused
                  ? null
                  : (value) => _setLocationSharing(value: value),
              activeTrackColor: scheme.primary,
            ),
          ),
          const Divider(height: 1, indent: 52),
          _StatusRow(
            icon: Icons.update_rounded,
            label: context.l10n.settings_locationLastUploaded,
            value: lastUploaded,
          ),
        ],
      ),
    );
  }

  String _formatUploadedAt(BuildContext context, DateTime? uploadedAt) {
    if (uploadedAt == null) return context.l10n.settings_locationNone;
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMMMd(locale).add_jm().format(uploadedAt);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: appCardDecoration(theme, color: theme.colorScheme.surface),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp12),
      child: child,
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.r8),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: AppSpacing.sp12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
