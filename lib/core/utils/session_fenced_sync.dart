import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';

/// The disposal flag and stale check shared by the device-registration controllers.
mixin SessionFencedSync on ReentrantSync {
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Marks the controller disposed and abandons any in-flight body.
  void disposeSync() {
    _disposed = true;
    invalidateSync();
  }

  /// True once teardown, a session change or disposal has overtaken this attempt.
  bool isAttemptStale(int generation, SessionLease lease) =>
      _disposed || isSyncStale(generation) || !lease.isCurrent;
}
