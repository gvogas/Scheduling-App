import 'dart:async';

/// Reentrancy guard that coalesces concurrent calls, so the latest state
/// always wins. `body` is responsible for handling its own errors.
///
/// It guards `sync` against `sync`. It does NOT guard `sync` against teardown
/// on its own — that is what [invalidateSync] is for. `deregisterThisDevice`
/// runs BEFORE `signOut()` by design, so a body resuming mid-teardown still
/// holds a valid credential and its writes SUCCEED, silently re-registering a
/// device that just signed out. Bump the generation at the top of every
/// `unregister()`, capture it at the top of the guarded body, and re-check
/// after each await.
mixin ReentrantSync {
  bool _syncPending = false;
  int _syncGeneration = 0;
  Object? _activeRun;

  /// Read this at the top of a guarded body and pass it to [isSyncStale].
  int get syncGeneration => _syncGeneration;

  /// True once [invalidateSync] has run since [generation] was read.
  bool isSyncStale(int generation) => generation != _syncGeneration;

  /// Abandons any in-flight body and drops a queued rerun. Call it FIRST in
  /// `unregister()`, before any await.
  void invalidateSync() {
    _syncGeneration += 1;
    _syncPending = false;
    _activeRun = null;
  }

  Future<void> runCoalesced(Future<void> Function() body) async {
    if (_activeRun != null) {
      _syncPending = true;
      return;
    }
    final run = _activeRun = Object();
    try {
      await body();
    } finally {
      if (identical(_activeRun, run)) {
        _activeRun = null;
        if (_syncPending) {
          _syncPending = false;
          unawaited(runCoalesced(body));
        }
      }
    }
  }
}
