import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/permissions/location_permission_service.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';
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
  final controller = PresenceSyncController(ref);
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

/// Writes the location-sharing choice and starts or stops presence tracking.
///
/// The ONE owner of that pair: the Settings row and the Location sharing
/// screen both flip the same field, and a write that skipped the presence half
/// would leave a technician's phone uploading fixes after they turned it off.
Future<void> applyLocationSharing(
  WidgetRef ref,
  EmployeeRecord record, {
  required bool enabled,
}) async {
  await ref
      .read(employeesRepositoryProvider)
      .updateSelfDetails(record.copyWith(locationSharingEnabled: enabled));
  final presence = ref.read(presenceSyncControllerProvider);
  if (enabled) {
    await presence.sync();
  } else {
    await presence.unregister();
  }
}

/// [applyLocationSharing] behind the offline guard, log tag and error notice
/// the two toggles share.
///
/// The Settings row and the Location sharing screen are the same operation, so
/// the `ME-SAVE location sharing failed` tag — the only place Crashlytics can
/// find it since notices stopped carrying support codes — lives here rather
/// than at each site. Returns whether the write committed; the caller keeps
/// its own busy-flag bracketing.
Future<bool> saveLocationSharing(
  BuildContext context,
  WidgetRef ref,
  EmployeeRecord record, {
  required bool enabled,
}) async {
  final l10n = context.l10n;
  final notices = ref.read(noticeServiceProvider);
  final logger = ref.read(loggerProvider);
  if (guardedOffline(
    context,
    ref,
    intro: l10n.error_introSaveLocationSharing,
  )) {
    return false;
  }
  try {
    await applyLocationSharing(ref, record, enabled: enabled);
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

/// Stationary re-upsert cadence that keeps `updatedAt` fresh. Keep this in
/// sync with PRESENCE_STALE_MINUTES = 25 in functions/travel_utils.js — the
/// window is comfortably above two missed heartbeats.
const presenceHeartbeatEvery = Duration(minutes: 10);

/// Pure gate — presence tracks exactly the timed-push audience. Delegates to
/// [shouldRegisterPush] so the "presence audience == push audience" invariant
/// holds by construction and can't drift apart.
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

/// Pure gate for the heartbeat tick. Only re-upserts when no movement fix
/// has gone out for a full heartbeat period — a fresh fix already reset the clock.
bool shouldHeartbeat({
  required DateTime? lastUploadAt,
  required DateTime now,
}) =>
    lastUploadAt != null &&
    now.difference(lastUploadAt) >= presenceHeartbeatEvery;

/// Delay until a throttled fix is allowed, or null if it's already allowed.
/// Used to arm the trailing-flush timer so the last fix in a burst still lands.
Duration? trailingFlushDelay({
  required DateTime? lastUploadAt,
  required DateTime now,
}) {
  if (shouldWritePresenceFix(lastUploadAt: lastUploadAt, now: now)) return null;
  return minPresenceUploadGap - now.difference(lastUploadAt!);
}

/// Owns the foreground position stream that keeps
/// `users/{docId}/presence/location` fresh for travel-time reminders. iOS
/// suspends it on background — see `_settingsForPlatform`.
class PresenceSyncController with ReentrantSync {
  PresenceSyncController(this._ref, {FirebaseAuth? auth})
    : _auth = auth ?? FirebaseAuth.instance;

  final Ref _ref;
  final FirebaseAuth _auth;

  StreamSubscription<Position>? _positionSub;
  Timer? _heartbeat;
  Timer? _trailingFlush;
  AppLifecycleListener? _lifecycle;
  String? _trackedUid;
  String? _docId;
  Position? _lastPosition;
  DateTime? _lastUploadAt;

  AppLogger get _logger => _ref.read(loggerProvider);

  Future<void> sync() => runCoalesced(_syncGuarded);

  Future<void> _syncGuarded() async {
    // Teardown runs BEFORE signOut(), so a body resuming mid-teardown still
    // holds a valid credential: it would re-open the position stream and
    // re-create presence/location for a user who just signed out, and keep
    // uploading until the process dies. Every await below re-checks this.
    final generation = syncGeneration;
    try {
      final gate = readAccountGateInputs(_ref, _auth);
      // Null is "we don't know yet" — leave presence tracking as it is.
      if (gate == null) return;
      if (!shouldTrackPresence(
        role: gate.role,
        status: gate.status,
        signedIn: gate.signedIn,
        locationSharingEnabled: gate.locationSharingEnabled,
      )) {
        _stop();
        return;
      }
      // Restart stream if permission was flipped while running.
      _lifecycle ??= AppLifecycleListener(onResume: _onResume);
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      // Fast path: already streaming for this uid.
      if (uid == _trackedUid && _positionSub != null) return;

      await _ref.read(firebaseReadyProvider.future).catchError((Object _) {});
      if (isSyncStale(generation)) return;
      final permission = await _ref
          .read(locationPermissionServiceProvider)
          .ensureLocation();
      if (isSyncStale(generation)) return;
      // Silent no-op on any non-grant (never nag) — the server's
      // address-fallback chain covers an untracked user. Silent to the USER,
      // not to us: the three non-grant reasons need different remedies
      // (re-prompt vs. open Settings vs. turn Location Services on), and
      // collapsing them to one early return left "presence never starts" with
      // nothing anywhere saying why. A breadcrumb, not a warn — a declined
      // permission is a choice, not a defect.
      if (permission != LocationPermissionResult.granted) {
        _logger.breadcrumb('PRESENCE not tracking: ${permission.name}');
        return;
      }

      final match = await _ref
          .read(employeesRepositoryProvider)
          .findUserByUid(uid);
      if (isSyncStale(generation)) return;
      final docId = match?.id;
      if (docId == null) {
        _logger.warn('PRESENCE no users doc for uid; skip tracking');
        return;
      }
      _start(docId: docId, uid: uid);
    } catch (e, st) {
      // sync() is called unawaited, so don't let failures escape as uncaught
      // async errors.
      _logger.warn('PRESENCE sync failed', e, st);
    }
  }

  void _start({required String docId, required String uid}) {
    _stop();
    _trackedUid = uid;
    _docId = docId;
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: _settingsForPlatform(),
        ).listen(
          (position) {
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
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );
      if (_positionSub == null) return;
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
    final delay = trailingFlushDelay(lastUploadAt: _lastUploadAt, now: now);
    if (delay == null) return;
    _trailingFlush?.cancel();
    _trailingFlush = Timer(delay, () {
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
    final previous = _lastUploadAt;
    _lastUploadAt = attemptedAt;
    // Resolved here, not in the handler: the handler runs from a Timer after
    // this controller may be disposed, and Riverpod 3 throws on `ref.read`
    // from a disposed consumer.
    final logger = _logger;
    unawaited(
      _upload(position)
          .then((result) {
            if (result == PresenceWriteResult.ok) return;
            if (_lastUploadAt == attemptedAt) _lastUploadAt = previous;
            if (result == PresenceWriteResult.denied) _stop();
          })
          .catchError((Object e, StackTrace st) {
            // Runs from a Timer callback, so a throw here has no caller left and
            // would land in Crashlytics as a fatal from a background GPS write.
            if (_lastUploadAt == attemptedAt) _lastUploadAt = previous;
            logger.warn('PRESENCE upload failed', e, st);
          }),
    );
  }

  Future<PresenceWriteResult> _upload(Position position) {
    final docId = _docId;
    final uid = _trackedUid;
    if (docId == null || uid == null) {
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

  /// This is about device capability, not UI look, so we use
  /// `defaultTargetPlatform` rather than `context.isCupertino` — there's no
  /// BuildContext here anyway, same as in `AddressMapLauncher`.
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
      // The foreground-service notification is what keeps the stream alive in
      // background on Android (dev harness only — never ships to Play, so the
      // untranslated text is acceptable).
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'ES Pro',
        notificationText:
            'Sharing your location for time-to-leave alerts and the staff map.',
      ),
    );
  }

  void _stop() {
    unawaited(_positionSub?.cancel());
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

  /// Best-effort teardown for sign-out or account deletion — stops the stream
  /// and deletes the presence doc. Never throws, since sign-out must not be blocked.
  /// Returns whether the stored fix is provably gone — see
  /// `PresenceRepository.deleteLocation`.
  Future<bool> unregister() async {
    invalidateSync();
    final knownDocId = _docId;
    _stop();
    try {
      // Resolve the docId when this session never started — `_start` needs
      // firebaseReady AND a granted location permission AND a successful
      // findUserByUid, and if any of those failed today the doc from a
      // PREVIOUS launch is still live. The map shows that pin for up to two
      // hours (`presenceHiddenAfter`), and the privacy policy promises sign-out
      // clears it. Same fix as `LiveActivityRegistrationController.unregister`.
      final docId = knownDocId ?? await _resolveUserDocId();
      if (docId == null) return false;
      return await _ref
          .read(presenceRepositoryProvider)
          .deleteLocation(userDocId: docId);
    } catch (e, st) {
      _logger.warn('PRESENCE unregister failed', e, st);
      return false;
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
    _stop();
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
