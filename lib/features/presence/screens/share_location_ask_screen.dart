import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

/// The one-time "Be on the team map" page, pushed over the calendar.
class ShareLocationAskScreen extends ConsumerStatefulWidget {
  const ShareLocationAskScreen({super.key});

  @override
  ConsumerState<ShareLocationAskScreen> createState() =>
      _ShareLocationAskScreenState();
}

class _ShareLocationAskScreenState
    extends ConsumerState<ShareLocationAskScreen> {
  bool _busy = false;

  Future<void> _turnOn(EmployeeRecord record) async {
    setState(() => _busy = true);
    final saved = await saveLocationSharing(
      context,
      ref,
      record,
      enabled: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final record = ref.watch(myEmployeeRecordProvider);

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
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _MapThumbnail(record: record),
                      const SizedBox(height: AppSpacing.sp24),
                      Text(
                        l10n.onboarding_shareLocationTitle,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sp8),
                      Text(
                        l10n.onboarding_shareLocationBody,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.palette.textBody,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sp24),
                      _Reassurance(l10n.onboarding_shareLocationOnlyOpen),
                      _Reassurance(l10n.onboarding_shareLocationOnlyLatest),
                      _Reassurance(l10n.onboarding_shareLocationOffAnytime),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sp16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy || record == null
                    ? null
                    : () => _turnOn(record),
                child: _busy
                    ? const AdaptiveProgressIndicator()
                    : Text(l10n.onboarding_shareLocationTurnOn),
              ),
              const SizedBox(height: AppSpacing.sp8),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.onboarding_shareLocationNotNow),
              ),
            ],
          ),
        ),
      ),
    );
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
