import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notifications/push_notification_service.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';
import 'package:scheduling/core/utils/session_fenced_sync.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/notifications/data/fcm_token_repository.dart';

final pushNotificationServiceProvider = Provider<PushNotificationService>(
  (ref) => PushNotificationService(logger: ref.watch(loggerProvider)),
);

final fcmTokenRepositoryProvider = Provider<FcmTokenRepository>(
  (ref) => FcmTokenRepository(
    firestore: ref.watch(firestoreProvider),
    logger: ref.watch(loggerProvider),
    session: ref.watch(sessionFenceProvider),
  ),
);

final pushRegistrationControllerProvider = Provider<PushRegistrationController>(
  (ref) {
    final controller = PushRegistrationController(ref);
    ref.onDispose(controller.dispose);
    return controller;
  },
);

/// The live OS notification-authorization status, read without prompting the
/// user. Invalidate this to re-read it after permissions change.
final notificationAuthStatusProvider =
    FutureProvider.autoDispose<AuthorizationStatus>(
      (ref) => ref.watch(pushNotificationServiceProvider).authorizationStatus(),
    );

/// Gate for push registration — active employees and admins. Admins register
/// too, for timed nudges, but the server withholds change-driven pushes from them.
bool shouldRegisterPush({
  required String role,
  required String status,
  required bool signedIn,
}) => signedIn && status == 'active' && (role == 'employee' || role == 'admin');

/// Registers this device's FCM token for the signed-in active employee and
/// tears it down on sign-out; driven by `main.dart` on every
/// `currentUserDocProvider` emission and on app-language change.
class PushRegistrationController with ReentrantSync, SessionFencedSync {
  PushRegistrationController(Ref ref, {FirebaseAuth? auth})
    : _ref = ref,
      _auth = auth ?? ref.read(firebaseAuthProvider),
      _session = ref.read(sessionFenceProvider),
      _logger = ref.read(loggerProvider);

  final Ref _ref;
  final FirebaseAuth _auth;
  final SessionFence _session;
  final AppLogger _logger;

  StreamSubscription<String>? _refreshSub;
  String? _registeredDocId;
  String? _registeredToken;
  String? _registeredUid;
  String? _registeredLocale;
  SessionLease? _registeredLease;
  Timer? _retryTimer;
  int _retryAttempts = 0;
  int _tokenRevision = 0;
  bool _rotationRequired = false;
  Future<String?>? _tokenRotation;
  bool _rotationResyncRequested = false;

  static String _currentLocale() => currentServerLocale;

  /// Idempotent and safe to call on every account-doc emission or language
  /// change. Concurrent calls coalesce, so whichever finishes last wins.
  Future<void> sync() => runCoalesced(_syncGuarded);

  Future<void> retryRegistration() {
    _retryAttempts = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    return sync();
  }

  void _scheduleRetry(SessionLease lease) {
    if (isDisposed ||
        !lease.isCurrent ||
        _retryTimer != null ||
        _retryAttempts >= 5) {
      return;
    }
    final seconds = 5 * (1 << _retryAttempts++);
    _retryTimer = Timer(Duration(seconds: seconds > 60 ? 60 : seconds), () {
      _retryTimer = null;
      if (!isDisposed && lease.isCurrent) unawaited(sync());
    });
  }

  void _acknowledged() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempts = 0;
  }

  Future<void> _syncGuarded() async {
    // Teardown runs before `signOut()`: a late body would upsert the fresh token `deleteToken()` mints.
    final generation = syncGeneration;
    SessionLease? attemptLease;
    // The guard opens HERE: the gate read and the awaited cancel can throw, and `sync()` runs unawaited.
    try {
      final lease = _session.capture();
      attemptLease = lease;
      if (lease == null || isDisposed) return;
      if (_rotationRequired || _tokenRotation != null) {
        _rotationResyncRequested = true;
        unawaited(
          _rotateNativeToken(_ref.read(pushNotificationServiceProvider)),
        );
        return;
      }
      bool stale() => isAttemptStale(generation, lease);
      final gate = readAccountGateInputs(_ref, _auth);
      // Null is "we don't know yet" — leave the registration as it is.
      if (gate == null) return;
      if (!shouldRegisterPush(
        role: gate.role,
        status: gate.status,
        signedIn: gate.signedIn,
      )) {
        final refreshSub = _refreshSub;
        _refreshSub = null;
        await refreshSub?.cancel();
        return;
      }

      final uid = _auth.currentUser?.uid;
      final locale = _currentLocale();
      // Fast path — already registered for this uid+locale with a live
      // refresh subscription, so skip the query and upsert.
      if (uid != null &&
          uid == _registeredUid &&
          locale == _registeredLocale &&
          _registeredLease?.isCurrent == true &&
          _refreshSub != null) {
        return;
      }

      await _ref.read(firebaseReadyProvider.future).catchError((Object _) {});
      if (stale()) return;
      final service = _ref.read(pushNotificationServiceProvider);
      final status = await service.authorizationStatus();
      if (!PushNotificationService.isGranted(status) || stale()) {
        return;
      }
      await service.configureForegroundPresentation();
      if (stale()) return;

      if (uid == null) return;
      final match = await _ref
          .read(employeesRepositoryProvider)
          .findUserByUid(uid);
      if (stale()) return;
      final docId = match?.id;
      if (docId == null) {
        _logger.warn('PUSH no users doc for uid; skip token upsert');
        _scheduleRetry(lease);
        return;
      }
      final tokenRevision = _tokenRevision;
      final token = await service.currentToken();
      if (stale()) return;
      if (token == null) {
        _scheduleRetry(lease);
        return;
      }

      await _upsert(docId, token, uid, locale);
      if (stale() || tokenRevision != _tokenRevision) return;
      _registeredDocId = docId;
      _registeredToken = token;
      _registeredUid = uid;
      _registeredLocale = locale;
      _registeredLease = lease;
      _acknowledged();
      _subscribeRefresh(docId, uid, lease, generation);
    } catch (e, st) {
      // sync() is called unawaited, so don't let a registration failure
      // escape as an uncaught async error — just log it as non-fatal.
      _logger.warn('PUSH sync failed', e, st);
      final lease = attemptLease;
      if (!isSyncStale(generation) && lease != null) _scheduleRetry(lease);
    }
  }

  /// This device's `users` doc id, for a teardown that never completed a
  /// registration. Null when signed out or when the lookup fails.
  Future<String?> _resolveUserDocId() =>
      resolveUserDocId(ref: _ref, auth: _auth, logger: _logger, tag: 'PUSH');

  Future<void> _upsert(String docId, String token, String uid, String locale) {
    return _ref
        .read(fcmTokenRepositoryProvider)
        .upsertToken(
          userDocId: docId,
          token: token,
          platform: Platform.isIOS ? 'ios' : 'android',
          locale: locale,
          uid: uid,
        );
  }

  void _subscribeRefresh(
    String docId,
    String uid,
    SessionLease lease,
    int generation,
  ) {
    unawaited(_cancelRefresh(_refreshSub));
    _refreshSub = _ref
        .read(pushNotificationServiceProvider)
        .onTokenRefresh
        .listen(
          (token) {
            if (isAttemptStale(generation, lease)) return;
            final revision = ++_tokenRevision;
            final locale = _currentLocale();
            _registeredLocale = null;
            unawaited(
              _registerRefresh(
                docId,
                token,
                uid,
                locale,
                lease,
                generation,
                revision,
              ),
            );
          },
          onError: (Object e, StackTrace st) =>
              _logger.warn('PUSH token refresh stream error', e, st),
        );
  }

  Future<void> _registerRefresh(
    String docId,
    String token,
    String uid,
    String locale,
    SessionLease lease,
    int generation,
    int revision,
  ) async {
    bool current() =>
        !isAttemptStale(generation, lease) && revision == _tokenRevision;
    try {
      await _upsert(docId, token, uid, locale);
      if (!current()) return;
      _registeredToken = token;
      _registeredLocale = locale;
      _acknowledged();
    } catch (error, stack) {
      _logger.warn('PUSH refresh registration failed', error, stack);
      if (current()) _scheduleRetry(lease);
    }
  }

  /// Best-effort de-registration for sign-out — deletes the token doc and
  /// invalidates the FCM token; never throws, so sign-out is never blocked.
  Future<void> unregisterCurrentDevice() async {
    invalidateSync();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempts = 0;
    _tokenRevision++;
    _rotationResyncRequested = false;
    final generation = syncGeneration;
    final refreshSub = _refreshSub;
    final registeredToken = _registeredToken;
    final registeredDocId = _registeredDocId;
    final registeredUid = _registeredUid;
    _refreshSub = null;
    _registeredDocId = null;
    _registeredToken = null;
    _registeredUid = null;
    _registeredLocale = null;
    _registeredLease = null;
    try {
      final lease = _session.capture(duringExit: true);
      final service = _ref.read(pushNotificationServiceProvider);
      final repository = _ref.read(fcmTokenRepositoryProvider);
      if (lease == null) return;
      _rotationRequired = true;
      final rotation = _rotateNativeToken(
        service,
        knownToken: registeredUid == lease.uid ? registeredToken : null,
      );
      await _cancelRefresh(refreshSub);
      bool stale() => isAttemptStale(generation, lease);
      if (stale()) return;
      // The token comes from FCM, never a kind/platform sweep, which would de-register the user's other phones.
      final token = await rotation;
      if (stale()) return;
      final docId =
          (registeredUid == lease.uid ? registeredDocId : null) ??
          await _resolveUserDocId();
      if (stale()) return;
      if (docId != null && token != null) {
        await repository.deleteToken(userDocId: docId, token: token);
      }
    } catch (e, st) {
      _logger.warn('PUSH unregister failed', e, st);
    }
  }

  Future<String?> _rotateNativeToken(
    PushNotificationService service, {
    String? knownToken,
  }) {
    final pending = _tokenRotation;
    if (pending != null) return pending;
    final rotation = () async {
      var token = knownToken;
      try {
        token ??= await service.currentToken();
        await service.deleteToken();
        _rotationRequired = false;
      } catch (error, stack) {
        _rotationRequired = true;
        _logger.warn('PUSH native token rotation failed', error, stack);
      }
      return token;
    }();
    return _tokenRotation = rotation.whenComplete(() {
      _tokenRotation = null;
      if (isDisposed || !_rotationResyncRequested) return;
      final lease = _session.capture();
      if (lease == null) return;
      if (_rotationRequired) {
        _scheduleRetry(lease);
      } else {
        _rotationResyncRequested = false;
        unawaited(sync());
      }
    });
  }

  /// Container-teardown cleanup — cancels the token-refresh subscription
  /// without the network delete that [unregisterCurrentDevice] does on sign-out.
  void dispose() {
    disposeSync();
    _retryTimer?.cancel();
    unawaited(
      _refreshSub?.cancel().catchError((Object error, StackTrace stack) {
        _logger.warn('PUSH cancel token refresh failed', error, stack);
      }),
    );
    _refreshSub = null;
  }

  Future<void> _cancelRefresh(StreamSubscription<String>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (error, stack) {
      _logger.warn('PUSH cancel token refresh failed', error, stack);
    }
  }
}
