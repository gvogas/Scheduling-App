import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive_action_sheet.dart';
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/wave/application/wave_providers.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/domain/models/wave_import_schedule.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';
import 'package:scheduling/features/wave/domain/wave_sync_notice.dart';
import 'package:scheduling/features/wave/widgets/wave_blocked_list.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Localized label for an automatic-import cadence — used by the picker row and
/// the action sheet.
String _scheduleLabel(BuildContext context, WaveImportSchedule schedule) =>
    switch (schedule) {
      WaveImportSchedule.off => context.l10n.wave_autoImportOff,
      WaveImportSchedule.weekly => context.l10n.wave_autoImportWeekly,
      WaveImportSchedule.monthly => context.l10n.wave_autoImportMonthly,
    };

/// Admin-only Wave integration controls in Settings. Holds ephemeral
/// [WaveConnection] and busy-flag state, and surfaces any [WaveFailure] via
/// notices — never ScaffoldMessenger.
class WaveSettingsSection extends ConsumerStatefulWidget {
  const WaveSettingsSection({super.key});

  @override
  ConsumerState<WaveSettingsSection> createState() =>
      _WaveSettingsSectionState();
}

class _WaveSettingsSectionState extends ConsumerState<WaveSettingsSection> {
  // This-session Connect result; takes precedence over the persisted
  // [waveConnectionProvider] status right after connecting.
  WaveConnection? _connection;
  bool _connectBusy = false;
  bool _syncBusy = false;
  bool _scheduleBusy = false;
  bool _retryBusy = false;

  /// True while any Wave round trip is in flight. The cadence picker adds
  /// [_scheduleBusy] on top; the Connect/Sync buttons swap places, so neither
  /// needs it. [_retryBusy] IS in here — Retry drains the same queue Sync
  /// does, so running both at once would have the two presses fighting over
  /// the same jobs and reporting each other's work.
  bool get _busy => _connectBusy || _syncBusy || _retryBusy;

  /// Fail-fast offline guard so the long-running Wave callables don't hang.
  /// Surfaces the network notice and returns true, so the caller can abort.
  ///
  /// Deliberately NOT `guardedOffline` (`core/errors/error_cause.dart`), which
  /// is otherwise the one owner of this shape: it hardcodes
  /// `composeErrorNotice`, and every other notice this section emits is a
  /// [WaveFailure]'s own localized message via [_runWaveAction]. Routing this
  /// one through the composer would make the offline notice the only one here
  /// speaking a different vocabulary, against the typed-Failure-branch-first
  /// rule. This is the second carve-out from that docstring's rule.
  bool _blockedOffline() {
    if (!ref.read(isOfflineProvider)) return false;
    ref
        .read(noticeServiceProvider)
        .error(const WaveNetwork().toLocalizedMessage(context));
    return true;
  }

  /// Shared try/on-WaveFailure/finally-busy-reset shape for the three actions
  /// below. Logs under `WAVE-<tag>` before showing the notice, so failures
  /// still reach Crashlytics.
  Future<void> _runWaveAction({
    required String tag,
    required void Function({required bool busy}) setBusy,
    required Future<void> Function() action,
  }) async {
    // Captured before the await so the log genuinely happens BEFORE the
    // mounted guard, as the docstring promises. It used to sit after it, so a
    // failure on an unmounted section reached Crashlytics never — and moving
    // it back above the guard without hoisting the read would instead throw
    // there, since `ref.read` is unsafe on an unmounted consumer in Riverpod 3.
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
      // `WaveService` maps its own throws, but the `action:` closures also run
      // notices, `ref.invalidate` and `setState` — so a non-`WaveFailure` is
      // reachable, and it used to escape to the zone handler with NO notice
      // shown: the admin taps Sync and nothing visibly happens. Reuses the
      // existing generic string rather than minting an `error_intro*` key for
      // a path that should never fire; this section is already the documented
      // carve-out from `composeErrorNotice`.
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
        // No business chosen client-side — waveBootstrap resolves it
        // server-side, so the name never ships in the app.
        final conn = await ref.read(waveServiceProvider).bootstrap();
        if (!mounted) return;
        if (!conn.isConnected) {
          // Server returned no business (misconfigured WAVE_BUSINESS_NAME) —
          // don't show a blank "connected" state.
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
        // Re-read the outbox counts: this sync drained the queue, so the
        // pending and failed rows above the button are now describing a state
        // that no longer exists.
        setState(() => _connection = null);
        ref.invalidate(waveConnectionProvider);
        ref
            .read(noticeServiceProvider)
            .success(waveSyncNotice(context.l10n, summary));
      },
    );
  }

  /// Returns dead-lettered client edits to the queue and pushes them.
  ///
  /// The counter this acts on is the only trace a dead-lettered job leaves
  /// outside one client's detail screen, so the notice has to distinguish
  /// every outcome — including the one that made this press look broken: a job
  /// dies on something Wave will reject again, so the push behind the requeue
  /// dead-letters it inside the same call and the failed row does not move.
  /// `waveRetryNotice` owns that wording; the tone is picked here, because a
  /// notice claiming success over an unchanged failure row is the whole bug.
  Future<void> _retryFailed() async {
    if (_blockedOffline()) return;
    await _runWaveAction(
      tag: 'RETRY',
      setBusy: ({required busy}) => setState(() => _retryBusy = busy),
      action: () async {
        final result = await ref.read(waveServiceProvider).retryFailedJobs();
        if (!mounted) return;
        // Re-read the counts rather than guessing them: the push may have
        // moved `pending` too, and a concurrent edit may have added to it.
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

  Future<void> _pickSchedule(WaveImportSchedule current) async {
    final choice = await showAdaptiveActionSheet<WaveImportSchedule>(
      context,
      title: context.l10n.wave_autoImportLabel,
      actions: [
        for (final s in WaveImportSchedule.values)
          AdaptiveSheetAction(value: s, label: _scheduleLabel(context, s)),
      ],
    );
    if (choice == null || choice == current) return;
    if (!mounted) return;
    if (_blockedOffline()) return;

    await _runWaveAction(
      tag: 'SCHEDULE',
      setBusy: ({required busy}) => setState(() => _scheduleBusy = busy),
      action: () async {
        await ref.read(waveServiceProvider).setImportSchedule(choice);
        if (!mounted) return;
        // Reflect the new cadence locally; invalidate so a later mount
        // re-reads the persisted value.
        final base = _connection ?? ref.read(waveConnectionProvider).value;
        if (base != null) {
          setState(() => _connection = base.copyWith(importSchedule: choice));
        }
        ref.invalidate(waveConnectionProvider);
        ref
            .read(noticeServiceProvider)
            .success(context.l10n.wave_autoImportUpdated);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final connectionAsync = ref.watch(waveConnectionProvider);
    // A this-session Connect wins; otherwise fall back to the cached persisted status.
    final connection = _connection ?? connectionAsync.value;
    final connected = connection != null;

    // Distinguish loading/error from not-connected, so a connected admin
    // doesn't see the Connect CTA flash, and a failure still offers a retry.
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
            scheduleBusy: _scheduleBusy,
            onTapSchedule: _busy || _scheduleBusy
                ? null
                : () => _pickSchedule(connection.importSchedule),
            retryBusy: _retryBusy,
            onRetryFailed: _busy || _scheduleBusy ? null : _retryFailed,
          ),
        // Connect is first-time setup only — the status row replaces it once connected.
        if (!connected)
          AnimatedLoadingButton(
            label: context.l10n.wave_connectToWave,
            isLoading: _connectBusy,
            onPressed: _busy ? null : _connect,
          )
        else
          // Syncing only makes sense once connected — a tap while
          // disconnected is guaranteed to fail.
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

/// The persisted-connection status row + auto-import schedule tile, shown
/// once Wave is connected.
class _ConnectedStatus extends StatelessWidget {
  const _ConnectedStatus({
    required this.connection,
    required this.scheduleBusy,
    required this.onTapSchedule,
    required this.retryBusy,
    required this.onRetryFailed,
  });

  final WaveConnection connection;
  final bool scheduleBusy;
  final VoidCallback? onTapSchedule;
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.sync_rounded),
          title: Text(context.l10n.wave_autoImportLabel),
          trailing: scheduleBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: AdaptiveProgressIndicator(),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _scheduleLabel(context, connection.importSchedule),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
          onTap: onTapSchedule,
        ),
        // The outbox, which had nowhere to be shown. Both rows are omitted at
        // zero AND at null — null means the count could not be taken (or an
        // older backend did not send it), and "nothing shown" is the honest
        // rendering of both. Never render null as 0: that reads as "the queue
        // is empty", which is the one thing an admin would act on.
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
        // A refused client is NOT a failed outbox job — it never became one —
        // so it is absent from both counters above and needs its own surface.
        const WaveBlockedList(),
      ],
    );
  }
}

/// One outbox line: an icon, a count sentence, and an optional trailing
/// action. Kept as its own widget so the pending and failed rows cannot drift
/// in padding or type scale.
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
