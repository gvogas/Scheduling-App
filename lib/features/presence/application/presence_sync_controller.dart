import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';
import 'package:scheduling/core/utils/session_fenced_sync.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart'
    show shouldRegisterPush;
import 'package:scheduling/features/presence/data/presence_repository.dart';
import 'package:scheduling/features/presence/domain/models/presence_fix.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/l10n/l10n.dart';

final presenceRepositoryProvider = Provider<PresenceRepository>(
  (ref) => PresenceRepository(
    firestore: ref.watch(firestoreProvider),
    logger: ref.watch(loggerProvider),
  ),
);

final presenceSyncControllerProvider = Provider<PresenceSyncController>((ref) {
  final controller = PresenceSyncController(
    ref,
    session: ref.watch(sessionFenceProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final myPresenceFixProvider = StreamProvider.autoDispose<PresenceFix?>((ref) {
  final record = ref.watch(myEmployeeRecordProvider);
  if (record == null) return Stream.value(null);
  return ref
      .watch(presenceRepositoryProvider)
      .watchLocation(userDocId: record.id);
});

/// The ONE owner of the location-sharing flip: the field AND presence.
Future<void> applyLocationSharing(
  WidgetRef ref,
  EmployeeRecord record, {
  required bool enabled,
  SessionFence? session,
}) async {
  final lease = session?.capture();
  if (session != null && lease == null) return;
  final presence = ref.read(presenceSyncControllerProvider);
  await ref
      .read(employeesRepositoryProvider)
      .updateSelfDetails(record.copyWith(locationSharingEnabled: enabled));
  if (!ref.context.mounted || (lease != null && !lease.isCurrent)) return;
  if (enabled) {
    await presence.sync();
  } else {
    await presence.unregister();
  }
}

/// [applyLocationSharing] behind the shared offline guard, tag and notice.
Future<bool> saveLocationSharing(
  BuildContext context,
  WidgetRef ref,
  EmployeeRecord record, {
  required bool enabled,
}) async {
  final l10n = context.l10n;
  final notices = ref.read(noticeServiceProvider);
  final logger = ref.read(loggerProvider);
  final session = ref.read(sessionFenceProvider);
  final lease = session.capture();
  if (lease == null) return false;
  if (guardedOffline(
    context,
    ref,
    intro: l10n.error_introSaveLocationSharing,
  )) {
    return false;
  }
  try {
    await applyLocationSharing(ref, record, enabled: enabled, session: session);
    if (!lease.isCurrent) return false;
    return true;
  } catch (error, stackTrace) {
    logger.warn('ME-SAVE location sharing failed', error, stackTrace);
    if (!context.mounted) return false;
    notices.error(
      composeErrorNoticeFor(
        l10n,
        intro: l10n.error_introSaveLocationSharing,
        error: error,
      ),
    );
    return false;
  }
}

/// Movement uploads at most this often — the stream's 250 m `distanceFilter`
/// handles granularity; this guards Firestore write volume on a highway.
const minPresenceUploadGap = Duration(minutes: 2);

/// Stationary heartbeat; must stay under PRESENCE_STALE_MINUTES (25).
const presenceHeartbeatEvery = Duration(minutes: 10);

/// Pure gate; delegates to [shouldRegisterPush] so the audiences can't drift.
bool shouldTrackPresence({
  required String role,
  required String status,
  required bool signedIn,
  required bool locationSharingEnabled,
}) =>
    locationSharingEnabled &&
    shouldRegisterPush(role: role, status: status, signedIn: signedIn);

/// Pure throttle for movement-driven fixes.
bool shouldWritePresenceFix({
  required DateTime? lastUploadAt,
  required DateTime now,
}) =>
    lastUploadAt == null ||
    now.difference(lastUploadAt) >= minPresenceUploadGap;

/// Heartbeat gate — only once no fix has gone out for a full period.
bool shouldHeartbeat({
  required DateTime? lastUploadAt,
  required DateTime now,
}) =>
    lastUploadAt != null &&
    now.difference(lastUploadAt) >= presenceHeartbeatEvery;

/// Delay until a throttled fix is allowed, so a burst's last fix lands.
Duration? trailingFlushDelay({
  required DateTime? lastUploadAt,
  required DateTime now,
}) {
  if (shouldWritePresenceFix(lastUploadAt: lastUploadAt, now: now)) return null;
  return minPresenceUploadGap - now.difference(lastUploadAt!);
}

/// Owns the foreground position stream behind `presence/location`.
class PresenceSyncController with ReentrantSync, SessionFencedSync {
  PresenceSyncController(this._ref, {FirebaseAuth? auth, SessionFence? session})
    : _auth = auth ?? FirebaseAuth.instance,
      _logger = _ref.read(loggerProvider),
      _session =
          session ??
          SessionFence(
            readUid: () => (auth ?? FirebaseAuth.instance).currentUser?.uid,
          );

  final Ref _ref;
  final FirebaseAuth _auth;
  final AppLogger _logger;
  final SessionFence _session;
  SessionLease? _trackingLease;
  int _trackingGeneration = 0;

  StreamSubscription<Position>? _positionSub;
  Timer? _heartbeat;
  Timer? _trailingFlush;
  AppLifecycleListener? _lifecycle;
  String? _trackedUid;
  String? _docId;
  Position? _lastPosition;
  DateTime? _lastUploadAt;
  bool _pauseCleared = false;

  Future<void> sync() => runCoalesced(_syncGuarded);

  Future<void> _syncGuarded() async {
    // Every await re-checks the generation: teardown precedes signOut().
    final generation = syncGeneration;
    try {
      final lease = _session.capture();
      if (lease == null || isDisposed) return;
      bool stale() => isAttemptStale(generation, lease);
      final gate = readAccountGateInputs(_ref, _auth);
      // Null is "we don't know yet" — leave presence tracking as it is.
      if (gate == null) return;
      final featureOn = _ref.read(featureFlagsProvider).presence;
      if (featureOn) _pauseCleared = false;
      final eligible = shouldTrackPresence(
        role: gate.role,
        status: gate.status,
        signedIn: gate.signedIn,
        locationSharingEnabled: gate.locationSharingEnabled,
      );
      if (!eligible || !featureOn) {
        final knownDocId = _docId;
        _stop();
        if (eligible && !_pauseCleared) {
          await _clearPausedFix(knownDocId, generation, lease);
        }
        return;
      }
      // Restart stream if permission was flipped while running.
      _lifecycle ??= AppLifecycleListener(onResume: _onResume);
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      // Fast path: already streaming for this uid.
      if (uid == _trackedUid &&
          _positionSub != null &&
          _trackingLease?.isCurrent == true) {
        return;
      }

      await _ref.read(firebaseReadyProvider.future).catchError((Object _) {});
      if (stale()) return;
      final permission = await _ref
          .read(locationPermissionServiceProvider)
          .ensureLocation();
      if (stale()) return;
      // Silent to the user, but breadcrumbed with the reason.
      if (permission != LocationPermissionResult.granted) {
        _logger.breadcrumb('PRESENCE not tracking: ${permission.name}');
        return;
      }

      final match = await _ref
          .read(employeesRepositoryProvider)
          .findUserByUid(uid);
      if (stale()) return;
      final docId = match?.id;
      if (docId == null) {
        _logger.warn('PRESENCE no users doc for uid; skip tracking');
        return;
      }
      _start(docId: docId, uid: uid, lease: lease);
    } catch (e, st) {
      // sync() is called unawaited, so nothing may escape.
      _logger.warn('PRESENCE sync failed', e, st);
    }
  }

  void _start({
    required String docId,
    required String uid,
    required SessionLease lease,
  }) {
    _stop();
    final generation = _trackingGeneration;
    bool current() =>
        generation == _trackingGeneration && lease.isCurrent && !isDisposed;
    _trackingLease = lease;
    _trackedUid = uid;
    _docId = docId;
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: _settingsForPlatform(),
        ).listen(
          (position) {
            if (!current()) return;
            _lastPosition = position;
            final now = DateTime.now();
            if (shouldWritePresenceFix(lastUploadAt: _lastUploadAt, now: now)) {
              _trailingFlush?.cancel();
              _trailingFlush = null;
              _uploadThrottled(position, now);
            } else {
              _armTrailingFlush(now);
            }
          },
          onError: (Object e, StackTrace st) {
            if (!current()) return;
            // Expected permission loss logs without Crashlytics record.
            if (_isExpectedLocationLoss(e)) {
              _logger.warn('PRESENCE stream stopped: location access lost');
            } else {
              _logger.warn('PRESENCE stream error', e, st);
            }
            _stop();
          },
        );
    _heartbeat = Timer.periodic(presenceHeartbeatEvery, (_) {
      if (!current()) return;
      final position = _lastPosition;
      if (position == null) return;
      final now = DateTime.now();
      if (shouldHeartbeat(lastUploadAt: _lastUploadAt, now: now)) {
        _trailingFlush?.cancel();
        _trailingFlush = null;
        _uploadThrottled(position, now);
      }
    });
  }

  void _onResume() {
    unawaited(sync());
    // The 250 m filter emits nothing for a phone reopened where it was closed.
    if (_positionSub != null) unawaited(_freshFixOnResume());
  }

  Future<void> _freshFixOnResume() async {
    final logger = _logger;
    final generation = _trackingGeneration;
    final lease = _trackingLease;
    if (lease == null || !lease.isCurrent || isDisposed) return;
    if (!shouldWritePresenceFix(
      lastUploadAt: _lastUploadAt,
      now: DateTime.now(),
    )) {
      return;
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );
      if (_positionSub == null ||
          generation != _trackingGeneration ||
          !lease.isCurrent ||
          isDisposed) {
        return;
      }
      _lastPosition = position;
      final now = DateTime.now();
      if (!shouldWritePresenceFix(lastUploadAt: _lastUploadAt, now: now)) {
        return;
      }
      _trailingFlush?.cancel();
      _trailingFlush = null;
      _uploadThrottled(position, now);
    } catch (e, st) {
      if (_isExpectedLocationLoss(e)) {
        logger.breadcrumb('PRESENCE resume fix skipped: location access lost');
      } else {
        logger.warn('PRESENCE resume fix failed', e, st);
      }
    }
  }

  void _armTrailingFlush(DateTime now) {
    final generation = _trackingGeneration;
    final lease = _trackingLease;
    final delay = trailingFlushDelay(lastUploadAt: _lastUploadAt, now: now);
    if (delay == null) return;
    _trailingFlush?.cancel();
    _trailingFlush = Timer(delay, () {
      if (generation != _trackingGeneration ||
          lease?.isCurrent != true ||
          isDisposed) {
        return;
      }
      _trailingFlush = null;
      final position = _lastPosition;
      final fireNow = DateTime.now();
      if (position == null ||
          !shouldWritePresenceFix(lastUploadAt: _lastUploadAt, now: fireNow)) {
        return;
      }
      _uploadThrottled(position, fireNow);
    });
  }

  /// Fires the write with the throttle clock set to [attemptedAt], and rolls
  /// it back on failure so a dropped write doesn't push us toward the staleness window.
  void _uploadThrottled(Position position, DateTime attemptedAt) {
    final generation = _trackingGeneration;
    final lease = _trackingLease;
    bool current() =>
        generation == _trackingGeneration &&
        lease?.isCurrent == true &&
        !isDisposed;
    if (!current()) return;
    final previous = _lastUploadAt;
    _lastUploadAt = attemptedAt;
    // Resolved here: the handler runs from a Timer after a possible dispose.
    final logger = _logger;
    unawaited(
      _upload(position)
          .then((result) {
            if (!current()) return;
            if (result == PresenceWriteResult.ok) return;
            if (_lastUploadAt == attemptedAt) _lastUploadAt = previous;
            if (result == PresenceWriteResult.denied) _stop();
          })
          .catchError((Object e, StackTrace st) {
            // A Timer callback has no caller; an escape would file a fatal.
            if (current() && _lastUploadAt == attemptedAt) {
              _lastUploadAt = previous;
            }
            logger.warn('PRESENCE upload failed', e, st);
          }),
    );
  }

  Future<PresenceWriteResult> _upload(Position position) {
    final docId = _docId;
    final uid = _trackedUid;
    if (docId == null ||
        uid == null ||
        _trackingLease?.isCurrent != true ||
        isDisposed) {
      return Future.value(PresenceWriteResult.failed);
    }
    return _ref
        .read(presenceRepositoryProvider)
        .upsertLocation(
          userDocId: docId,
          uid: uid,
          lat: position.latitude,
          lng: position.longitude,
        );
  }

  /// Expected, user-driven ways the position stream can die — permission
  /// revoked, or Location Services turned off.
  static bool _isExpectedLocationLoss(Object e) =>
      e is PermissionDeniedException ||
      e is LocationServiceDisabledException ||
      (e is PositionUpdateException &&
          (e.message ?? '').contains('kCLErrorDomain error 1'));

  /// Device capability, so `defaultTargetPlatform`, not `isCupertino`.
  LocationSettings _settingsForPlatform() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 250,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: true,
      );
    }
    return AndroidSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 250,
      // Keeps the Android stream alive in background (never shipped).
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'ES Pro',
        notificationText:
            'Sharing your location for time-to-leave alerts and the staff map.',
      ),
    );
  }

  void _stop() {
    _trackingGeneration++;
    _trackingLease = null;
    unawaited(
      _positionSub?.cancel().catchError((Object error, StackTrace stack) {
        _logger.warn('PRESENCE cancel stream failed', error, stack);
      }),
    );
    _positionSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _trailingFlush?.cancel();
    _trailingFlush = null;
    _trackedUid = null;
    _docId = null;
    _lastPosition = null;
    _lastUploadAt = null;
  }

  /// Best-effort sign-out teardown; never throws. True if the fix is gone.
  Future<bool> unregister() async {
    invalidateSync();
    final generation = syncGeneration;
    final lease = _session.capture(duringExit: true);
    final knownDocId = _trackedUid == lease?.uid ? _docId : null;
    _stop();
    try {
      if (lease == null || isDisposed) return false;
      final repository = _ref.read(presenceRepositoryProvider);
      // Resolve the doc id even if this session never started tracking.
      final docId = knownDocId ?? await _resolveUserDocId();
      if (docId == null || isAttemptStale(generation, lease)) return false;
      return await repository.deleteLocation(userDocId: docId);
    } catch (e, st) {
      _logger.warn('PRESENCE unregister failed', e, st);
      return false;
    }
  }

  /// Removes the stored fix once per remote pause; a failure leaves
  /// [_pauseCleared] false so the next sync retries. Never throws.
  Future<void> _clearPausedFix(
    String? knownDocId,
    int generation,
    SessionLease lease,
  ) async {
    try {
      final repository = _ref.read(presenceRepositoryProvider);
      final docId = knownDocId ?? await _resolveUserDocId();
      if (docId == null || isAttemptStale(generation, lease)) return;
      final cleared = await repository.deleteLocation(userDocId: docId);
      if (isAttemptStale(generation, lease)) return;
      _pauseCleared = cleared;
    } catch (e, st) {
      _logger.warn('PRESENCE pause clear failed', e, st);
    }
  }

  /// This device's `users` doc id, for a teardown that never got as far as
  /// [_start]. Null when signed out or when the lookup fails.
  Future<String?> _resolveUserDocId() => resolveUserDocId(
    ref: _ref,
    auth: _auth,
    logger: _logger,
    tag: 'PRESENCE',
  );

  /// Container-teardown cleanup — cancels the stream, timers, and lifecycle
  /// listener without the network delete that [unregister] does on sign-out.
  void dispose() {
    disposeSync();
    _stop();
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
