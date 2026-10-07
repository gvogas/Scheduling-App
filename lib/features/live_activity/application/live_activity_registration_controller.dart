import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/activity_update.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/platform/ios_platform.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';
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
      ),
    );

final liveActivityRegistrationControllerProvider =
    Provider<LiveActivityRegistrationController>((ref) {
      final controller = LiveActivityRegistrationController(ref);
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Whether this device can host a push-started Live Activity. Drives whether
/// the Settings row is shown.
final liveActivitySupportedProvider = FutureProvider<bool>(
  (ref) => ref.watch(liveActivityRegistrationControllerProvider).canHostCards(),
);

/// Gate for Live Activity registration. Delegates to [shouldRegisterPush] so
/// the two audiences can't drift apart.
bool shouldRegisterLiveActivity({
  required String role,
  required String status,
  required bool signedIn,
}) => shouldRegisterPush(role: role, status: status, signedIn: signedIn);

/// Registers this device's Live Activity APNs tokens into
/// `users/{docId}/liveActivityTokens/{id}`. iOS-gated and best effort — a
/// failure here just leaves the plain `leaveNow` push working as before.
class LiveActivityRegistrationController with ReentrantSync {
  LiveActivityRegistrationController(
    this._ref, {
    FirebaseAuth? auth,
    LiveActivities? plugin,
    this.isIosPlatform = defaultIsIosPlatform,
  }) : _injectedAuth = auth,
       _injectedPlugin = plugin;

  final Ref _ref;
  final FirebaseAuth? _injectedAuth;
  final LiveActivities? _injectedPlugin;

  /// Injected for the same reason `AppSyncListeners` takes one: `flutter test`
  /// runs on the host, so a bare `Platform.isIOS` returns before any injectable
  /// point and leaves this whole controller unreachable from the harness — on
  /// the ONLY platform that ships. Everything below the three gates it guards
  /// (the token upserts, the opt-out sweep that deletes stale server rows, the
  /// local-card teardown) was untested for exactly that reason.
  final bool Function() isIosPlatform;

  // Resolved lazily rather than in the constructor, since endLocalCards runs
  // in unit tests that don't have Firebase set up.
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

  /// Live cards keyed by activity id — one update token each.
  final Map<String, String> _activityTokens = <String, String>{};

  AppLogger get _logger => _ref.read(loggerProvider);

  static String _currentLocale() => currentServerLocale;

  /// Idempotent and safe to call on every account-doc emission or language
  /// change. Concurrent calls coalesce, so whichever finishes last wins.
  Future<void> sync() async {
    if (!isIosPlatform()) return;
    await runCoalesced(_runSync);
  }

  Future<void> _runSync() async {
    try {
      await _syncGuarded();
    } catch (e, st) {
      // sync() is called unawaited, so don't let failures escape as uncaught
      // async errors.
      _logger.warn('LIVE-ACT sync failed', e, st);
    }
  }

  /// The body of [sync], run under the [ReentrantSync] guard.
  Future<void> _syncGuarded() async {
    // Teardown runs BEFORE signOut(), so a body resuming mid-teardown still
    // holds a valid credential and its token upsert SUCCEEDS — re-registering
    // a device that just signed out, with nothing logging an error.
    final generation = syncGeneration;
    // Wait for ready before reading the preference — on cold start it
    // defaults to true, which would re-register a device that opted out.
    await _ref.read(liveActivityEnabledProvider.notifier).ready;
    if (isSyncStale(generation)) return;
    if (!_ref.read(liveActivityEnabledProvider) ||
        !_ref.read(featureFlagsProvider).liveActivities) {
      // A stored opt-out is authoritative, so reconcile by actively removing
      // any stale server rows left behind by an interrupted previous opt-out
      // rather than only stopping local streams. Straight to `_teardown` -
      // going through `unregister` would invalidate the generation and drop a
      // preference flip that arrived while this run was in flight.
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

    final uid = _auth.currentUser?.uid;
    final locale = _currentLocale();
    // Fast path — already subscribed for this uid+locale, so token rotations
    // just flow through the existing streams.
    if (uid != null &&
        uid == _uid &&
        locale == _locale &&
        _pushToStartSub != null) {
      return;
    }

    await _ref.read(firebaseReadyProvider.future).catchError((Object _) {});
    if (uid == null || isSyncStale(generation)) return;
    if (!await _ensurePlugin() || isSyncStale(generation)) return;

    final docId = await _resolveUserDocId();
    if (isSyncStale(generation)) return;
    if (docId == null) {
      _logger.warn('LIVE-ACT no users doc for uid; skip token upsert');
      return;
    }

    _docId = docId;
    _uid = uid;
    _locale = locale;
    await _reupsertKnownTokens();
    _subscribePushToStart();
    _subscribeActivityUpdates();
  }

  /// Whether this device can host a push-started card — needs iOS 17.2+,
  /// ActivityKit available, and the user opted in. Never throws.
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

  /// Same check as [canHostCards], plus a one-time plugin init for devices
  /// that can host cards.
  Future<bool> _ensurePlugin() async {
    if (!await canHostCards()) return false;
    if (!_pluginReady) {
      await _plugin.init(appGroupId: widgetAppGroupId);
      _pluginReady = true;
    }
    return true;
  }

  /// Language change / account switch: re-stamp the rows this device already
  /// owns so their `locale` (which drives the card's EN/FR text) follows the
  /// app, instead of waiting for iOS to rotate a token.
  Future<void> _reupsertKnownTokens() async {
    final pushToStart = _pushToStartToken;
    if (pushToStart != null) {
      await _upsert(
        token: pushToStart,
        kind: LiveActivityTokenKind.pushToStart,
      );
    }
    for (final entry in _activityTokens.entries) {
      await _upsert(
        token: entry.value,
        kind: LiveActivityTokenKind.update,
        activityId: entry.key,
      );
    }
  }

  void _subscribePushToStart() {
    unawaited(_pushToStartSub?.cancel());
    _pushToStartSub = _plugin.pushToStartTokenUpdateStream.listen(
      (token) {
        _pushToStartToken = token;
        unawaited(
          _upsert(token: token, kind: LiveActivityTokenKind.pushToStart),
        );
      },
      onError: (Object e, StackTrace st) =>
          _logger.warn('LIVE-ACT push-to-start stream error', e, st),
    );
  }

  void _subscribeActivityUpdates() {
    unawaited(_activitySub?.cancel());
    _activitySub = _plugin.activityUpdateStream.listen(
      (event) {
        event.mapOrNull<void>(
          active: (value) {
            _activityTokens[value.activityId] = value.activityToken;
            unawaited(
              _upsert(
                token: value.activityToken,
                kind: LiveActivityTokenKind.update,
                activityId: value.activityId,
              ),
            );
          },
          // `ended` also covers a dismissed card: its update token is dead, so
          // drop the row rather than leaving the server pushing into a void.
          ended: (value) => unawaited(_forgetActivity(value.activityId)),
        );
      },
      onError: (Object e, StackTrace st) =>
          _logger.warn('LIVE-ACT activity stream error', e, st),
    );
  }

  Future<void> _upsert({
    required String token,
    required LiveActivityTokenKind kind,
    String? activityId,
  }) async {
    final docId = _docId;
    final uid = _uid;
    if (docId == null || uid == null) return;
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

  /// Ends this device's live cards immediately — for the Settings opt-out
  /// only. Never wire this to status writes: `endAllActivities()` is
  /// device-wide and can't target a single appointment. Terminal transitions
  /// are ended server-side instead, by `endCardOnTerminal`.
  Future<void> endLocalCards() async {
    if (!isIosPlatform() || !_pluginReady) return;
    try {
      await _plugin.endAllActivities();
    } catch (e, st) {
      _logger.warn('LIVE-ACT endLocalCards failed', e, st);
    }
    // The `ended` stream events clear these rows too; sweeping here means a
    // missed event can't leave the server pushing at a card that's gone.
    for (final activityId in _activityTokens.keys.toList()) {
      await _forgetActivity(activityId);
    }
  }

  /// Best-effort de-registration for sign-out or account deletion — ends any
  /// live card and deletes this device's token rows. Never throws, so
  /// sign-out is never blocked on this.
  Future<void> unregister() async {
    invalidateSync();
    await _teardown();
  }

  /// The teardown itself, without the sync invalidation — the opt-out
  /// reconcile in [_syncGuarded] runs this while a sync is legitimately alive.
  Future<void> _teardown() async {
    try {
      // Ends the cards and drops every per-activity row. The push-to-start
      // row is handled separately just below.
      await endLocalCards();
      // Resolve docId in case _docId was never set — e.g. the user opted out
      // before the token stream emitted, or the preference was off at cold start.
      final docId = _docId ?? await _resolveUserDocId();
      if (docId != null) {
        // Delete by kind rather than by id, since the push-to-start doc id
        // IS the token — and this session may never have seen it.
        await _ref
            .read(liveActivityTokenRepositoryProvider)
            .deleteTokensOfKind(
              userDocId: docId,
              kind: LiveActivityTokenKind.pushToStart,
            );
      }
    } catch (e, st) {
      _logger.warn('LIVE-ACT unregister failed', e, st);
    } finally {
      await _cancelStreams();
      _docId = null;
      _uid = null;
      _locale = null;
      _pushToStartToken = null;
      _activityTokens.clear();
    }
  }

  /// The users-doc id for the signed-in uid, or null when signed out or the
  /// lookup fails; never throws, so [unregister] is never blocked.
  Future<String?> _resolveUserDocId() => resolveUserDocId(
    ref: _ref,
    auth: _auth,
    logger: _logger,
    tag: 'LIVE-ACT',
  );

  Future<void> _cancelStreams() async {
    await _pushToStartSub?.cancel();
    _pushToStartSub = null;
    await _activitySub?.cancel();
    _activitySub = null;
  }

  /// Container-teardown cleanup — cancels the token streams without the
  /// network delete that [unregister] does on sign-out/opt-out.
  void dispose() {
    unawaited(_cancelStreams());
  }
}
