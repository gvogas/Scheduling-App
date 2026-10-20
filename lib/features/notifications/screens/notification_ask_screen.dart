import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The one-time notifications page, pushed over the calendar before the
/// team-map page while iOS has never shown its prompt.
class NotificationAskScreen extends ConsumerStatefulWidget {
  const NotificationAskScreen({super.key});

  @override
  ConsumerState<NotificationAskScreen> createState() =>
      _NotificationAskScreenState();
}

class _NotificationAskScreenState extends ConsumerState<NotificationAskScreen> {
  bool _busy = false;

  /// The tap IS the in-context step; the prompt never moves onto `sync()`.
  Future<void> _turnOn() async {
    setState(() => _busy = true);
    final service = ref.read(pushNotificationServiceProvider);
    final controller = ref.read(pushRegistrationControllerProvider);
    await service.requestPermission();
    if (!mounted) return;
    ref.invalidate(notificationAuthStatusProvider);
    unawaited(controller.sync());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
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
              Expanded(child: _intro(context)),
              const SizedBox(height: AppSpacing.sp16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : _turnOn,
                child: _busy
                    ? const AdaptiveProgressIndicator()
                    : Text(l10n.onboarding_notificationsTurnOn),
              ),
              const SizedBox(height: AppSpacing.sp8),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(l10n.onboarding_notificationsNotNow),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _BellBadge(),
          const SizedBox(height: AppSpacing.sp24),
          Text(
            l10n.onboarding_notificationsTitle,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.sp8),
          Text(
            l10n.onboarding_notificationsBody,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.palette.textBody,
            ),
          ),
          const SizedBox(height: AppSpacing.sp24),
          _Reassurance(l10n.onboarding_notificationsOnlyJobs),
          _Reassurance(l10n.onboarding_notificationsLeaveOnTime),
          _Reassurance(l10n.onboarding_notificationsOffAnytime),
        ],
      ),
    );
  }
}

class _BellBadge extends StatelessWidget {
  const _BellBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.notifications_active_rounded,
            size: 48,
            color: theme.palette.primaryAccent,
          ),
        ),
      ),
    );
  }
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
