import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/wave/application/wave_providers.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';
import 'package:scheduling/features/wave/domain/wave_sync_notice.dart';
import 'package:scheduling/features/wave/widgets/wave_blocked_list.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Admin-only Wave controls in Settings; failures surface via notices.
class WaveSettingsSection extends ConsumerStatefulWidget {
  const WaveSettingsSection({super.key});

  @override
  ConsumerState<WaveSettingsSection> createState() =>
      _WaveSettingsSectionState();
}

class _WaveSettingsSectionState extends ConsumerState<WaveSettingsSection> {
  // This-session Connect result; wins over the persisted status.
  WaveConnection? _connection;
  bool _connectBusy = false;
  bool _syncBusy = false;
  bool _retryBusy = false;

  /// True while any Wave round trip is in flight, Retry included.
  bool get _busy => _connectBusy || _syncBusy || _retryBusy;

  /// Fail-fast offline guard — the documented `guardedOffline` carve-out.
  bool _blockedOffline() {
    if (!ref.read(isOfflineProvider)) return false;
    ref
        .read(noticeServiceProvider)
        .error(const WaveNetwork().toLocalizedMessage(context));
    return true;
  }

  /// Shared try/finally shape for the three actions; logs `WAVE-<tag>`.
  Future<void> _runWaveAction({
    required String tag,
    required void Function({required bool busy}) setBusy,
    required Future<void> Function() action,
  }) async {
    // Hoisted before the await so the log lands before the mounted guard.
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    setBusy(busy: true);
    try {
      await action();
    } on WaveFailure catch (e, st) {
      logger.warn('WAVE-$tag failed', e, st);
      if (!mounted) return;
      notices.error(e.toLocalizedMessage(context));
    } on Object catch (e, st) {
      // Generic fallback: the action closures can throw a non-WaveFailure.
      logger.warn('WAVE-$tag failed (unexpected)', e, st);
      if (!mounted) return;
      notices.error(context.l10n.error_somethingWentWrongPleaseTryAgain);
    } finally {
      if (mounted) setBusy(busy: false);
    }
  }

  Future<void> _connect() async {
    if (_blockedOffline()) return;
    await _runWaveAction(
      tag: 'CONNECT',
      setBusy: ({required busy}) => setState(() => _connectBusy = busy),
      action: () async {
        // waveBootstrap resolves the business server-side.
        final conn = await ref.read(waveServiceProvider).bootstrap();
        if (!mounted) return;
        if (!conn.isConnected) {
          // No business returned — never show a blank "connected" state.
          ref
              .read(noticeServiceProvider)
              .error(context.l10n.wave_errorBusinessAmbiguous);
          return;
        }
        setState(() => _connection = conn);
        ref.invalidate(waveConnectionProvider);
        ref
            .read(noticeServiceProvider)
            .success(context.l10n.wave_connectedSuccess(conn.businessName));
      },
    );
  }

  Future<void> _sync() async {
    if (_blockedOffline()) return;
    await _runWaveAction(
      tag: 'SYNC',
      setBusy: ({required busy}) => setState(() => _syncBusy = busy),
      action: () async {
        final summary = await ref.read(waveServiceProvider).syncCustomers();
        if (!mounted) return;
        // Re-read the outbox counts this sync just drained.
        setState(() => _connection = null);
        ref.invalidate(waveConnectionProvider);
        ref
            .read(noticeServiceProvider)
            .success(waveSyncNotice(context.l10n, summary));
      },
    );
  }

  /// Requeues dead-lettered client edits; the notice tone must match.
  Future<void> _retryFailed() async {
    if (_blockedOffline()) return;
    await _runWaveAction(
      tag: 'RETRY',
      setBusy: ({required busy}) => setState(() => _retryBusy = busy),
      action: () async {
        final result = await ref.read(waveServiceProvider).retryFailedJobs();
        if (!mounted) return;
        // Re-read the counts: the push or a concurrent edit may move them.
        setState(() => _connection = null);
        ref.invalidate(waveConnectionProvider);
        final message = waveRetryNotice(context.l10n, result);
        final notices = ref.read(noticeServiceProvider);
        if (result.hasFailed) {
          notices.error(message);
        } else {
          notices.success(message);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final connectionAsync = ref.watch(waveConnectionProvider);
    // A this-session Connect wins; otherwise fall back to the cached persisted status.
    final connection = _connection ?? connectionAsync.value;
    final connected = connection != null;

    // Loading/error is not "not connected", so Connect never flashes.
    if (_connection == null && connectionAsync.isLoading) {
      return const _WaveStatusLoading();
    }
    if (_connection == null && connectionAsync.hasError) {
      return _WaveStatusError(
        onRetry: () => ref.invalidate(waveConnectionProvider),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (connected)
          _ConnectedStatus(
            connection: connection,
            retryBusy: _retryBusy,
            onRetryFailed: _busy ? null : _retryFailed,
          ),
        // Connect is first-time setup only — the status row replaces it once connected.
        if (!connected)
          AnimatedLoadingButton(
            label: context.l10n.wave_connectToWave,
            isLoading: _connectBusy,
            onPressed: _busy ? null : _connect,
          )
        else
          // Syncing only makes sense once connected.
          AnimatedLoadingButton(
            label: context.l10n.wave_syncButton,
            isLoading: _syncBusy,
            onPressed: _busy ? null : _sync,
            variant: AnimatedLoadingButtonVariant.outlined,
          ),
      ],
    );
  }
}

/// The persisted-connection status row and the outbox rows, shown once Wave
/// is connected.
class _ConnectedStatus extends StatelessWidget {
  const _ConnectedStatus({
    required this.connection,
    required this.retryBusy,
    required this.onRetryFailed,
  });

  final WaveConnection connection;
  final bool retryBusy;
  final VoidCallback? onRetryFailed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.sp4,
            bottom: AppSpacing.sp8,
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 14,
                color: Theme.of(context).statusColors.success,
              ),
              const SizedBox(width: AppSpacing.sp8),
              Flexible(
                child: Text(
                  connection.businessName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // Omitted at zero AND null; never render an unknown count as 0.
        if (connection.hasPending)
          _OutboxRow(
            icon: Icons.schedule_rounded,
            label: context.l10n.wave_outboxPending(connection.pendingCount!),
            tone: scheme.onSurfaceVariant,
          ),
        if (connection.hasFailed)
          _OutboxRow(
            icon: Icons.error_outline_rounded,
            label: context.l10n.wave_outboxFailed(connection.failedCount!),
            tone: scheme.error,
            action: retryBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: AdaptiveProgressIndicator(),
                  )
                : TextButton(
                    onPressed: onRetryFailed,
                    child: Text(context.l10n.wave_retryFailedButton),
                  ),
          ),
        // A refused client is in neither counter, so it gets its own surface.
        const WaveBlockedList(),
      ],
    );
  }
}

/// One outbox line, its own widget so the two rows can't drift.
class _OutboxRow extends StatelessWidget {
  const _OutboxRow({
    required this.icon,
    required this.label,
    required this.tone,
    this.action,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.sp4,
        top: AppSpacing.sp8,
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: tone),
          const SizedBox(width: AppSpacing.sp8),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: tone),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Subtle placeholder while the persisted Wave status is still loading.
class _WaveStatusLoading extends StatelessWidget {
  const _WaveStatusLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.sp12),
      child: Center(
        child: AdaptiveProgressIndicator(),
      ),
    );
  }
}

/// Inline error + retry shown when the Wave status read fails (rather than
/// silently rendering "not connected").
class _WaveStatusError extends StatelessWidget {
  const _WaveStatusError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
        const SizedBox(width: AppSpacing.sp8),
        Expanded(
          child: Text(
            context.l10n.error_somethingWentWrong,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          child: Text(context.l10n.common_retry),
        ),
      ],
    );
  }
}
