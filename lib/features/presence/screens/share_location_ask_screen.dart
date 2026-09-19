import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/presence/domain/location_share_ask_policy.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// The "Be on the team map" page, pushed over the calendar once per app build.
class ShareLocationAskScreen extends ConsumerStatefulWidget {
  const ShareLocationAskScreen({super.key});

  @override
  ConsumerState<ShareLocationAskScreen> createState() =>
      _ShareLocationAskScreenState();
}

class _ShareLocationAskScreenState
    extends ConsumerState<ShareLocationAskScreen> {
  bool _busy = false;

  Future<bool> _enable(EmployeeRecord record) async {
    setState(() => _busy = true);
    final saved = await saveLocationSharing(
      context,
      ref,
      record,
      enabled: true,
    );
    if (mounted) setState(() => _busy = false);
    return saved;
  }

  Future<void> _turnOn(EmployeeRecord record) async {
    if (await _enable(record) && mounted) Navigator.of(context).pop();
  }

  /// iOS will not ask again, so the switch is saved and Settings does the rest.
  Future<void> _openSettings(EmployeeRecord record) async {
    final permissions = ref.read(locationPermissionServiceProvider);
    if (!record.locationSharingEnabled && !await _enable(record)) return;
    if (!mounted) return;
    Navigator.of(context).pop();
    await permissions.openSettings();
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(myEmployeeRecordProvider);
    final permission = ref.watch(locationPermissionStatusProvider).value;
    final variant = locationShareAskVariant(
      sharing: record?.locationSharingEnabled ?? false,
      permission: permission ?? LocationPermissionResult.denied,
    );

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sp24,
            AppSpacing.sp16,
            AppSpacing.sp24,
            AppSpacing.sp16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _intro(context, variant, record)),
              const SizedBox(height: AppSpacing.sp16),
              ..._actions(
                context,
                variant,
                record: record,
                enabled: !_busy && record != null && permission != null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro(
    BuildContext context,
    LocationShareAskVariant variant,
    EmployeeRecord? record,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isOn = variant == LocationShareAskVariant.alreadyOn;
    final bodyStyle = theme.textTheme.bodyLarge?.copyWith(
      color: theme.palette.textBody,
    );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MapThumbnail(record: record),
          const SizedBox(height: AppSpacing.sp24),
          Text(
            isOn
                ? l10n.onboarding_shareLocationOnTitle
                : l10n.onboarding_shareLocationTitle,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.sp8),
          Text(
            isOn
                ? l10n.onboarding_shareLocationOnBody
                : l10n.onboarding_shareLocationBody,
            style: bodyStyle,
          ),
          if (variant == LocationShareAskVariant.openSettings) ...[
            const SizedBox(height: AppSpacing.sp8),
            Text(l10n.onboarding_shareLocationBlocked, style: bodyStyle),
          ],
          const SizedBox(height: AppSpacing.sp24),
          _Reassurance(l10n.onboarding_shareLocationOnlyOpen),
          _Reassurance(l10n.onboarding_shareLocationOnlyLatest),
          _Reassurance(l10n.onboarding_shareLocationOffAnytime),
        ],
      ),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    LocationShareAskVariant variant, {
    required EmployeeRecord? record,
    required bool enabled,
  }) {
    final l10n = context.l10n;
    final (String label, VoidCallback onPressed) = switch (variant) {
      LocationShareAskVariant.turnOn => (
        l10n.onboarding_shareLocationTurnOn,
        () => _turnOn(record!),
      ),
      LocationShareAskVariant.openSettings => (
        l10n.onboarding_shareLocationOpenSettings,
        () => _openSettings(record!),
      ),
      LocationShareAskVariant.alreadyOn => (
        l10n.common_done,
        () => Navigator.of(context).pop(),
      ),
    };
    return [
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: enabled ? onPressed : null,
        child: _busy ? const AdaptiveProgressIndicator() : Text(label),
      ),
      if (variant != LocationShareAskVariant.alreadyOn) ...[
        const SizedBox(height: AppSpacing.sp8),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.onboarding_shareLocationNotNow),
        ),
      ],
    ];
  }
}

/// A painted street grid with the person's own avatar as the pin.
class _MapThumbnail extends StatelessWidget {
  const _MapThumbnail({required this.record});

  final EmployeeRecord? record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        child: SizedBox(
          height: 168,
          width: double.infinity,
          child: CustomPaint(
            painter: _StreetsPainter(
              ground: theme.palette.sheetRow,
              street: theme.colorScheme.surface,
            ),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 3,
                  ),
                  boxShadow: theme.cardStyle.pillShadow,
                ),
                child: AppAvatar(
                  name: record?.displayName ?? '',
                  color: record?.color,
                  size: AvatarSize.lg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StreetsPainter extends CustomPainter {
  const _StreetsPainter({required this.ground, required this.street});

  final Color ground;
  final Color street;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    final paint = Paint()
      ..color = street
      ..strokeWidth = 10;
    for (final fraction in const [0.22, 0.58, 0.86]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (final fraction in const [0.14, 0.47, 0.78]) {
      final x = size.width * fraction;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_StreetsPainter oldDelegate) =>
      ground != oldDelegate.ground || street != oldDelegate.street;
}

class _Reassurance extends StatelessWidget {
  const _Reassurance(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sp12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 20,
            color: theme.palette.primaryAccent,
          ),
          const SizedBox(width: AppSpacing.sp12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
