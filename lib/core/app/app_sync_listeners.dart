import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/app/carplay_bridge.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/ios_platform.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_provider.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_service.dart';

/// Cross-cutting sync wiring for app-wide listeners.
///
/// [registerAll] must be called from `build`, like any `ref.listen`.
class AppSyncListeners {
  const AppSyncListeners(this.ref, {this.isIosPlatform = defaultIsIosPlatform});

  final WidgetRef ref;

  /// Injected so the iOS-only mirror listeners can register in a host test.
  final bool Function() isIosPlatform;

  /// Registers every listener, in the same order as the original inline calls.
  void registerAll() {
    _pushRegistration();
    _presenceSync();
    _liveActivitySync();
    _widgetSync();
    _snapshotSync();
    _uploadDrain();
  }

  /// Runs [action] to completion, logging a throw under [tag] instead of
  /// rethrowing, so a chained step still runs and nothing reaches the zone.
  ///
  /// [logger] is passed in rather than read here: a step chained after an
  /// `await` must not touch `ref`.
  Future<void> _guarded(
    AppLogger logger,
    String tag,
    Future<void> Function() action,
  ) => Future<void>.sync(action).catchError((Object error, StackTrace stack) {
    logger.warn(tag, error, stack);
  });

  void _fireAndForget(String tag, Future<void> Function() action) {
    unawaited(_guarded(ref.read(loggerProvider), tag, action));
  }

  void _pushRegistration() {
    ref.listen<AsyncValue<Map<String, dynamic>>>(currentUserDocProvider, (
      prev,
      next,
    ) {
      _fireAndForget(
        'APP-SYNC push registration sync failed',
        () => ref.read(pushRegistrationControllerProvider).sync(),
      );
    });
  }

  void _presenceSync() {
    // Starts or stops the foreground location stream for leave-now reminders.
    ref.listen<AsyncValue<Map<String, dynamic>>>(currentUserDocProvider, (
      prev,
      next,
    ) {
      _fireAndForget(
        'APP-SYNC presence sync failed',
        () => ref.read(presenceSyncControllerProvider).sync(),
      );
    });
  }

  void _liveActivitySync() {
    // Registers Live Activity APNs tokens for lock-screen leave-now cards.
    ref.listen<AsyncValue<Map<String, dynamic>>>(currentUserDocProvider, (
      prev,
      next,
    ) {
      _fireAndForget(
        'APP-SYNC live activity sync failed',
        () => ref.read(liveActivityRegistrationControllerProvider).sync(),
      );
    });
  }

  /// True when an emission says nothing about whether the person is signed out.
  ///
  /// Both mirrors below publish `null` to mean SIGNED OUT and clear the App
  /// Group. But an `AsyncError` carries a null value too, and so does
  /// `AsyncLoading` — so keying on `value == null` alone made a failed Firestore
  /// read (past `retryAsync`) blank the home-screen widget and have Siri answer
  /// "no appointments" to someone who has jobs. Both surfaces are off-screen,
  /// so nothing reported it. A stale mirror beats a wrongly-empty one: keeping
  /// the last good payload is the honest degradation while the read is broken.
  ///
  /// Public because `CarPlayBridge` applies the same rule to the same snapshot
  /// on connect — a second spelling of it is a second chance to lose a clause.
  static bool isUnsettled(AsyncValue<Object?> next) =>
      next.isLoading || next.hasError;

  void _widgetSync() {
    if (!isIosPlatform()) return;
    ref.listen<AsyncValue<Map<String, dynamic>?>>(widgetPayloadProvider, (
      prev,
      next,
    ) {
      if (isUnsettled(next)) return;
      final payload = next.value;
      final service = ref.read(widgetSyncServiceProvider);
      if (payload == null) {
        _fireAndForget('APP-SYNC widget clear failed', service.clear);
      } else {
        _fireAndForget(
          'APP-SYNC widget sync failed',
          () => service.sync(payload),
        );
      }
    });
  }

  /// The App Group rewrite and the CarPlay ping are ONE chain, deliberately.
  ///
  /// `writeSnapshot`/`clearSnapshot` run synchronously only as far as their
  /// first `await`, so a ping fired from a second listener on the same
  /// emission reaches the car BEFORE the file changes: the store re-reads the
  /// old bytes, sees no change and does not re-render. On sign-out that leaves
  /// the ex-user's client names and addresses on the car display until CarPlay
  /// reconnects. Chaining is what makes "after the write LANDED" structural —
  /// registration order alone would still be two unawaited futures.
  void _snapshotSync() {
    if (!isIosPlatform()) return;
    ref.listen<AsyncValue<Map<String, dynamic>?>>(scheduleSnapshotProvider, (
      prev,
      next,
    ) {
      if (isUnsettled(next)) return;
      final logger = ref.read(loggerProvider);
      final payload = next.value;
      final service = ref.read(scheduleSnapshotServiceProvider);
      final bridge = ref.read(carPlayBridgeProvider);
      final tag = payload == null
          ? 'APP-SYNC snapshot clear failed'
          : 'APP-SYNC snapshot write failed';
      unawaited(
        _guarded(logger, tag, () => service.apply(payload)).then(
          (_) => _guarded(
            logger,
            'APP-SYNC carplay ping failed',
            bridge.notifySnapshotChanged,
          ),
        ),
      );
    });
  }

  void _uploadDrain() {
    // When we come back online after being offline, retry any queued photo
    // batches — once per flip.
    ref
      ..listen<bool>(isOfflineProvider, (previous, next) {
        final isSignedIn =
            ref.read(currentUserDocProvider).value?.isNotEmpty ?? false;
        if (previous == true && !next && isSignedIn) {
          _fireAndForget(
            'APP-SYNC photo drain failed',
            () => ref.read(appointmentImageUploadProvider).drainPending(),
          );
        }
      })
      // On startup or sign-in, drain once as soon as the account doc first
      // arrives. Storage rules require an authenticated user, so draining
      // while signed out would just re-queue everything.
      ..listen<AsyncValue<Map<String, dynamic>>>(currentUserDocProvider, (
        previous,
        next,
      ) {
        final wasEmpty = previous?.value?.isEmpty ?? true;
        final hasDoc = next.value?.isNotEmpty ?? false;
        final offline = ref.read(isOfflineProvider);
        if (wasEmpty && hasDoc && !offline) {
          _fireAndForget(
            'APP-SYNC photo drain failed',
            () => ref.read(appointmentImageUploadProvider).drainPending(),
          );
        }
      });
  }
}
