import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

/// Wraps [FirebaseRemoteConfig]: cached values first, then a background
/// fetch, then every real-time update. Every failure keeps the last values.
class RemoteConfigService {
  RemoteConfigService({FirebaseRemoteConfig? remoteConfig, AppLogger? logger})
    : _remoteConfig = remoteConfig ?? FirebaseRemoteConfig.instance,
      _logger = logger ?? AppLogger();

  final FirebaseRemoteConfig _remoteConfig;
  final AppLogger _logger;

  Stream<FeatureFlags> watch() {
    late final StreamController<FeatureFlags> controller;
    StreamSubscription<RemoteConfigUpdate>? updates;
    FeatureFlags? last;
    var cancelled = false;

    void emit() {
      if (cancelled || controller.isClosed) return;
      try {
        final flags = FeatureFlags.fromValues(_remoteConfig.getAll());
        if (flags == last) return;
        if (last != null) _logger.breadcrumb('FLAGS changed: $flags');
        last = flags;
        controller.add(flags);
      } catch (e, st) {
        _logger.warn('FLAGS read failed', e, st);
      }
    }

    Future<void> fetch() async {
      try {
        await _remoteConfig.fetchAndActivate();
        emit();
      } catch (e, st) {
        _logger.warn('FLAGS fetch failed', e, st);
      }
    }

    Future<void> activateUpdate() async {
      try {
        await _remoteConfig.activate();
        emit();
      } catch (e, st) {
        _logger.warn('FLAGS update activate failed', e, st);
      }
    }

    Future<void> start() async {
      try {
        await _remoteConfig.setDefaults(
          FeatureFlags.defaults.toRemoteConfigDefaults(),
        );
        await _remoteConfig.activate();
      } catch (e, st) {
        _logger.warn('FLAGS activate failed', e, st);
      }
      emit();
      if (cancelled || controller.isClosed) return;
      unawaited(fetch());
      try {
        updates = _remoteConfig.onConfigUpdated.listen(
          (_) => unawaited(activateUpdate()),
          onError: (Object e, StackTrace st) =>
              _logger.warn('FLAGS update stream failed', e, st),
        );
        if (cancelled) unawaited(updates?.cancel());
      } catch (e, st) {
        _logger.warn('FLAGS update listen failed', e, st);
      }
    }

    controller = StreamController<FeatureFlags>(
      onListen: () => unawaited(start()),
      onCancel: () {
        cancelled = true;
        return updates?.cancel();
      },
    );
    return controller.stream;
  }
}
