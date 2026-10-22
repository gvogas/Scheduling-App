import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';

final sessionFenceProvider = Provider<SessionFence>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  final fence = SessionFence(readUid: () => auth.currentUser?.uid);
  final logger = ref.read(loggerProvider);
  final subscription = auth.authStateChanges().listen(
    (user) => fence.observeUid(user?.uid),
    onError: (Object error, StackTrace stack) {
      fence.invalidate();
      logger.warn('ACCOUNT-EXIT auth stream failed', error, stack);
    },
  );
  ref.onDispose(() {
    fence.beginExit();
    unawaited(subscription.cancel());
  });
  return fence;
});

/// Invalidates asynchronous work at UID transitions and before account teardown.
class SessionFence {
  SessionFence({required String? Function() readUid}) : _readUid = readUid;

  final String? Function() _readUid;
  String? _uid;
  int _generation = 0;
  bool _exiting = false;

  void invalidate() => _generation++;

  bool Function() captureBoundary() {
    observeUid(_readUid());
    final generation = _generation;
    final uid = _uid;
    return () {
      observeUid(_readUid());
      return generation == _generation && uid == _uid;
    };
  }

  void observeUid(String? uid) {
    if (_uid == uid) return;
    _uid = uid;
    _generation++;
    _exiting = false;
  }

  SessionLease? beginExit() {
    observeUid(_readUid());
    if (!_exiting) {
      _generation++;
      _exiting = true;
    }
    return capture(duringExit: true);
  }

  /// A failed exit starts fresh work without reviving any abandoned operation.
  void resume() {
    observeUid(_readUid());
    if (!_exiting) return;
    _generation++;
    _exiting = false;
  }

  SessionLease? capture({bool duringExit = false}) {
    observeUid(_readUid());
    if (_uid == null || (_exiting && !duringExit)) return null;
    return SessionLease._(this, _generation, _uid!, duringExit);
  }
}

class SessionLease {
  SessionLease._(this._fence, this._generation, this.uid, this._duringExit);

  final SessionFence _fence;
  final int _generation;
  final String uid;
  final bool _duringExit;

  bool get isCurrent {
    _fence.observeUid(_fence._readUid());
    return _generation == _fence._generation &&
        uid == _fence._uid &&
        (_duringExit || !_fence._exiting);
  }
}
