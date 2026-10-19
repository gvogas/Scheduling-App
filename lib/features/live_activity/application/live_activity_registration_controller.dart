import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/activity_update.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/ios_platform.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';
import 'package:scheduling/core/utils/session_fenced_sync.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart'
    show widgetAppGroupId;
import 'package:scheduling/features/live_activity/application/live_activity_preference.dart';
import 'package:scheduling/features/live_activity/data/live_activity_token_repository.dart';
import 'package:scheduling/features/live_activity/domain/live_activity_token.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart'
    show shouldRegisterPush;

final liveActivityTokenRepositoryProvider =
    Provider<LiveActivityTokenRepository>(
      (ref) => LiveActivityTokenRepository(
        firestore: ref.watch(firestoreProvider),
        logger: ref.watch(loggerProvider),
        session: ref.watch(sessionFenceProvider),
      ),
    );

final liveActivityRegistrationControllerProvider =
    Provider<LiveActivityRegistrationController>((ref) {
      final controller = LiveActivityRegistrationController(
        ref,
        session: ref.watch(sessionFenceProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Whether this device can host a push-started Live Activity (drives the Settings row).
final liveActivitySupportedProvider = FutureProvider<bool>(
  (ref) => ref.watch(liveActivityRegistrationControllerProvider).canHostCards(),
);

/// Gate for Live Activity registration; delegates to [shouldRegisterPush].
bool shouldRegisterLiveActivity({
  required String role,
  required String status,
  required bool signedIn,
}) => shouldRegisterPush(role: role, status: status, signedIn: signedIn);

/// Registers this device's Live Activity APNs tokens; iOS-gated and best effort.
class LiveActivityRegistrationController with ReentrantSync, SessionFencedSync {
  LiveActivityRegistrationController(
    this._ref, {
    FirebaseAuth? auth,
    LiveActivities? plugin,
    SessionFence? session,
    this.isIosPlatform = defaultIsIosPlatform,
  }) : _injectedAuth = auth,
       _injectedPlugin = plugin,
       _logger = _ref.read(loggerProvider),
       _session =
           session ??
           SessionFence(
             readUid: () => (auth ?? FirebaseAuth.instance).currentUser?.uid,
           );

  final Ref _ref;
  final FirebaseAuth? _injectedAuth;
  final LiveActivities? _injectedPlugin;
  final AppLogger _logger;
  final SessionFence _session;
  SessionLease? _registrationLease;
  Future<bool>? _endingCards;
  bool _endRequired = false;
  bool _resyncAfterEnd = false;

  /// Injected so tests can reach past the iOS gate (see `defaultIsIosPlatform`).
  final bool Function() isIosPlatform;

  // Lazy: endLocalCards runs in unit tests without Firebase.
  FirebaseAuth get _auth => _injectedAuth ?? FirebaseAuth.instance;
  LiveActivities get _plugin =>
      _injectedPlugin ?? (_lazyPlugin ??= LiveActivities());
  LiveActivities? _lazyPlugin;

  StreamSubscription<String>? _pushToStartSub;
  StreamSubscription<ActivityUpdate>? _activitySub;
  bool _pluginReady = false;
  String? _docId;
  String? _uid;
  String? _locale;
  String? _pushToStartToken;
  bool _pauseCleared = false;

  /// Live cards keyed by activity id — one update token each.
  final Map<String, String> _activityTokens = <String, String>{};

  static String _currentLocale() => currentServerLocale;

  /// Idempotent; concurrent calls coalesce.
  Future<void> sync() async {
    if (!isIosPlatform()) return;
    await runCoalesced(_runSync);
  }

  Future<void> _runSync() async {
    try {
      await _syncGuarded();
    } catch (e, st) {
      // sync() is called unawaited, so nothing else would catch this.
      _logger.warn('LIVE-ACT sync failed', e, st);
    }
  }

  /// The body of [sync], run under the [ReentrantSync] guard.
  Future<void> _syncGuarded() async {
    final generation = syncGeneration;
    final lease = _session.capture();
    if (lease == null || isDisposed) return;
    bool stale() => isAttemptStale(generation, lease);
    if (_endingCards != null) {
      _resyncAfterEnd = true;
      return;
    }
    // The cold-start default is true, so wait for the stored preference.
    await _ref.read(liveActivityEnabledProvider.notifier).ready;
    if (stale()) return;
    final featureOn = _ref.read(featureFlagsProvider).liveActivities;
    if (featureOn) _pauseCleared = false;
    if (_endRequired) {
      final ended = await _endCardsNative();
      if (stale() || !ended) return;
      if (!featureOn) _pauseCleared = true;
    }
    if (!_ref.read(liveActivityEnabledProvider)) {
      // Not `unregister`: invalidating the generation would drop an in-flight preference flip.
      await _teardown();
      return;
    }
    final gate = readAccountGateInputs(_ref, _auth);
    // Null is "we don't know yet" — leave the registration as it is.
    if (gate == null) return;
    if (!shouldRegisterLiveActivity(
      role: gate.role,
      status: gate.status,
      signedIn: gate.signedIn,
    )) {
      await _cancelStreams();
      return;
    }
    if (!featureOn) {
      // A remote pause keeps the push-to-start row: iOS may not re-emit its token on resume.
      if (!_pauseCleared) {
        final ended = await _endLocalCards();
        if (!stale()) _pauseCleared = ended;
      }
      return;
    }

    final uid = _auth.currentUser?.uid;
    final locale = _currentLocale();
    // Already subscribed for this uid+locale.
    if (uid != null &&
        uid == _uid &&
        locale == _locale &&
        _pushToStartSub != null &&
        _registrationLease?.isCurrent == true) {
      return;
    }

    await _ref.read(firebaseReadyProvider.future).catchError((Object _) {});
    if (uid == null || stale()) return;
    if (!await _ensurePlugin() || stale()) return;

    final docId = await _resolveUserDocId();
    if (stale()) return;
    if (docId == null) {
      _logger.warn('LIVE-ACT no users doc for uid; skip token upsert');
      return;
    }

    _docId = docId;
    _uid = uid;
    _locale = locale;
    _registrationLease = lease;
    await _reupsertKnownTokens(lease);
    if (stale()) return;
    _subscribePushToStart(lease, generation);
    _subscribeActivityUpdates(lease, generation);
  }

  /// The one device-capability probe (iOS 17.2+, ActivityKit on, push start allowed); never throws.
  Future<bool> canHostCards() async {
    if (!isIosPlatform()) return false;
    try {
      return await _plugin.areActivitiesSupported() &&
          await _plugin.areActivitiesEnabled() &&
          await _plugin.allowsPushStart();
    } catch (e, st) {
      _logger.warn('LIVE-ACT support probe failed', e, st);
      return false;
    }
  }

  /// [canHostCards] plus a one-time plugin init.
  Future<bool> _ensurePlugin() async {
    if (!await canHostCards()) return false;
    if (!_pluginReady) {
      await _plugin.init(appGroupId: widgetAppGroupId);
      _pluginReady = true;
    }
    return true;
  }

  /// Re-stamps this device's rows so their `locale` (the card's EN/FR text) follows the app.
  Future<void> _reupsertKnownTokens(SessionLease lease) async {
    final pushToStart = _pushToStartToken;
    if (pushToStart != null) {
      await _upsert(
        token: pushToStart,
        kind: LiveActivityTokenKind.pushToStart,
        lease: lease,
      );
    }
    for (final entry in _activityTokens.entries.toList()) {
      await _upsert(
        token: entry.value,
        kind: LiveActivityTokenKind.update,
        activityId: entry.key,
        lease: lease,
      );
    }
  }

  void _subscribePushToStart(SessionLease lease, int generation) {
    unawaited(_cancel(_pushToStartSub));
    _pushToStartSub = _plugin.pushToStartTokenUpdateStream.listen(
      (token) {
        if (isAttemptStale(generation, lease) ||
            !identical(lease, _registrationLease)) {
          return;
        }
        _pushToStartToken = token;
        unawaited(
          _upsert(
            token: token,
            kind: LiveActivityTokenKind.pushToStart,
            lease: lease,
          ),
        );
      },
      onError: (Object e, StackTrace st) =>
          _logger.warn('LIVE-ACT push-to-start stream error', e, st),
    );
  }

  void _subscribeActivityUpdates(SessionLease lease, int generation) {
    unawaited(_cancel(_activitySub));
    _activitySub = _plugin.activityUpdateStream.listen(
      (event) {
        if (isAttemptStale(generation, lease) ||
            !identical(lease, _registrationLease)) {
          return;
        }
        event.mapOrNull<void>(
          active: (value) {
            _activityTokens[value.activityId] = value.activityToken;
            unawaited(
              _upsert(
                token: value.activityToken,
                kind: LiveActivityTokenKind.update,
                activityId: value.activityId,
                lease: lease,
              ),
            );
          },
          // `ended` also covers a dismissed card, whose update token is dead.
          ended: (value) => unawaited(_forgetActivity(value.activityId)),
        );
      },
      onError: (Object e, StackTrace st) =>
          _logger.warn('LIVE-ACT activity stream error', e, st),
    );
  }

  Future<void> _upsert({
    required SessionLease lease,
    required String token,
    required LiveActivityTokenKind kind,
    String? activityId,
  }) async {
    final docId = _docId;
    final uid = _uid;
    if (docId == null ||
        uid == null ||
        !lease.isCurrent ||
        !identical(lease, _registrationLease) ||
        isDisposed) {
      return;
    }
    await _ref
        .read(liveActivityTokenRepositoryProvider)
        .upsertToken(
          userDocId: docId,
          docId: liveActivityTokenDocId(
            kind: kind,
            token: token,
            activityId: activityId,
          ),
          token: token,
          kind: kind,
          locale: _locale ?? _currentLocale(),
          uid: uid,
          expiresAt: liveActivityTokenExpiry(kind: kind, now: DateTime.now()),
        );
  }

  Future<void> _forgetActivity(String activityId) async {
    _activityTokens.remove(activityId);
    final docId = _docId;
    if (docId == null) return;
    await _ref
        .read(liveActivityTokenRepositoryProvider)
        .deleteToken(userDocId: docId, docId: activityId);
  }

  /// Ends this device's cards — Settings opt-out only; `endAllActivities()` is device-wide.
  Future<void> endLocalCards() => _endLocalCards();

  /// [endLocalCards], reporting whether the device-wide end succeeded.
  Future<bool> _endLocalCards() async {
    if (!isIosPlatform() || !_pluginReady) return true;
    final lease = _session.capture(duringExit: true);
    final docId = _uid == lease?.uid ? _docId : null;
    final activityIds = _activityTokens.keys.toList();
    _activityTokens.clear();
    final repository = _ref.read(liveActivityTokenRepositoryProvider);
    final ended = await _endCardsNative();
    for (final activityId in activityIds) {
      if (lease?.isCurrent != true || docId == null || isDisposed) break;
      await repository.deleteToken(userDocId: docId, docId: activityId);
    }
    return ended;
  }

  Future<bool> _endCardsNative() {
    final pending = _endingCards;
    if (pending != null) return pending;
    _endRequired = true;
    final ending = () async {
      try {
        await _plugin.endAllActivities();
        _endRequired = false;
        return true;
      } catch (error, stack) {
        _logger.warn('LIVE-ACT endLocalCards failed', error, stack);
        return false;
      }
    }();
    return _endingCards = ending.whenComplete(() {
      _endingCards = null;
      if (_resyncAfterEnd && !_endRequired && !isDisposed) {
        _resyncAfterEnd = false;
        unawaited(sync());
      }
    });
  }

  /// Best-effort de-registration for sign-out or account deletion; never throws.
  Future<void> unregister() async {
    invalidateSync();
    await _teardown();
  }

  /// [unregister] without the sync invalidation, for the opt-out reconcile in [_syncGuarded].
  Future<void> _teardown() async {
    final generation = syncGeneration;
    final lease = _session.capture(duringExit: true);
    final knownDocId = _uid == lease?.uid ? _docId : null;
    final ending = endLocalCards();
    final cancellation = _cancelStreams();
    _registrationLease = null;
    _docId = null;
    _uid = null;
    _locale = null;
    _pushToStartToken = null;
    _activityTokens.clear();
    try {
      final repository = _ref.read(liveActivityTokenRepositoryProvider);
      await ending;
      await cancellation;
      if (lease == null || isAttemptStale(generation, lease)) return;
      final docId = knownDocId ?? await _resolveUserDocId();
      if (isAttemptStale(generation, lease)) return;
      if (docId != null) {
        // By kind: the push-to-start doc id IS a token this session may never have seen.
        await repository.deleteTokensOfKind(
          userDocId: docId,
          kind: LiveActivityTokenKind.pushToStart,
        );
      }
    } catch (e, st) {
      _logger.warn('LIVE-ACT unregister failed', e, st);
    }
  }

  /// The signed-in uid's users-doc id, or null; never throws.
  Future<String?> _resolveUserDocId() => resolveUserDocId(
    ref: _ref,
    auth: _auth,
    logger: _logger,
    tag: 'LIVE-ACT',
  );

  Future<void> _cancelStreams() async {
    final push = _pushToStartSub?.cancel();
    final activity = _activitySub?.cancel();
    _pushToStartSub = null;
    _activitySub = null;
    try {
      await Future.wait([?push, ?activity]);
    } catch (error, stack) {
      _logger.warn('LIVE-ACT cancel streams failed', error, stack);
    }
  }

  Future<void> _cancel(StreamSubscription<dynamic>? stream) async {
    try {
      await stream?.cancel();
    } catch (error, stack) {
      _logger.warn('LIVE-ACT cancel stream failed', error, stack);
    }
  }

  /// Cancels the token streams without [unregister]'s network delete.
  void dispose() {
    disposeSync();
    unawaited(_cancelStreams());
  }
}
