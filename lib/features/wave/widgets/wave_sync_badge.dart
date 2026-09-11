import 'package:flutter/material.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';
import 'package:scheduling/features/wave/domain/models/wave_sync_state.dart';
import 'package:scheduling/features/wave/widgets/wave_problem_list.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Sync states already reported, so an unrecognized one is filed ONCE per
/// process rather than on every rebuild of the row it sits in — the reason
/// logging inside a build method is otherwise forbidden.
final Set<String> _reportedUnknownStates = <String>{};
final AppLogger _waveBadgeLogger = AppLogger();

/// Small chip reflecting Wave sync state, plus the contract's reasons.
///
/// A reason is visible TEXT, not just a `Semantics` label: an admin looking at
/// a red chip could previously see a colour and nothing else, which is what
/// made a refused client indistinguishable from a slow one.
class WaveSyncBadge extends StatelessWidget {
  const WaveSyncBadge({
    required this.syncState,
    super.key,
    this.syncError,
    this.problems = const <WaveProblem>[],
  });

  final String syncState;

  /// Raw error string from waveSyncError. Exposed as the Semantics label when
  /// the state is 'error'.
  final String? syncError;

  /// Contract problems recorded on the client doc. Rendered whatever the
  /// state: an ADVISORY rides along on a perfectly synced client, and it is
  /// still the only place that problem is visible.
  final List<WaveProblem> problems;

  @override
  Widget build(BuildContext context) {
    final config = _badgeConfig(context);
    if (config == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semanticsLabel = syncState == kWaveSyncStateError && syncError != null
        ? '${config.label}: $syncError'
        : config.label;

    return Semantics(
      label: semanticsLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sp8,
              vertical: AppSpacing.sp4,
            ),
            decoration: BoxDecoration(
              color: config.background,
              borderRadius: BorderRadius.circular(AppRadius.rFull),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(config.icon, size: 12, color: config.foreground),
                const SizedBox(width: AppSpacing.sp4),
                Flexible(
                  child: Text(
                    config.label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: config.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          WaveProblemList(problems: problems),
        ],
      ),
    );
  }

  _BadgeConfig? _badgeConfig(BuildContext context) {
    final sc = Theme.of(context).statusColors;
    final scheme = Theme.of(context).colorScheme;

    switch (syncState) {
      case kWaveSyncStateSynced:
        return _BadgeConfig(
          label: context.l10n.wave_syncedWithWave,
          icon: Icons.check_circle_outline_rounded,
          background: sc.successContainer,
          foreground: sc.onSuccessContainer,
        );
      case kWaveSyncStatePending:
        return _BadgeConfig(
          label: context.l10n.wave_syncPending,
          icon: Icons.sync_rounded,
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
        );
      case kWaveSyncStateBlocked:
        return _BadgeConfig(
          label: context.l10n.wave_syncBlocked,
          icon: Icons.block_rounded,
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
        );
      case kWaveSyncStateError:
        return _BadgeConfig(
          label: context.l10n.wave_syncError,
          icon: Icons.error_outline_rounded,
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
        );
      default:
        // `syncState` is a SERVER-owned vocabulary, so a state added
        // backend-side (say `conflict`) would ship as a blank space on an
        // admin-only surface with no signal anywhere. Empty is the ordinary
        // "never synced" case and is not worth reporting.
        if (syncState.isNotEmpty && _reportedUnknownStates.add(syncState)) {
          _waveBadgeLogger.warn('WAVE-BADGE unknown syncState: $syncState');
        }
        return null;
    }
  }
}

class _BadgeConfig {
  const _BadgeConfig({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
}
