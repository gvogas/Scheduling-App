import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/utils/reentrant_sync.dart';

/// Minimal host that drives [ReentrantSync] with a body whose completion this
/// test controls, so overlap is deterministic (no reliance on wall-clock).
class _Host with ReentrantSync {
  int started = 0;
  final List<Completer<void>> _gates = <Completer<void>>[];

  Future<void> sync() => runCoalesced(_body);

  Future<void> _body() {
    started++;
    final gate = Completer<void>();
    _gates.add(gate);
    return gate.future;
  }

  /// Completes the oldest in-flight body, letting that run finish.
  void release() => _gates.removeAt(0).complete();
}

void main() {
  group('ReentrantSync.runCoalesced', () {
    test('runs the body when idle', () async {
      final host = _Host();
      final f = host.sync();
      expect(host.started, 1);
      host.release();
      await f;
    });

    test(
      'a call arriving mid-flight coalesces into a single trailing re-run',
      () async {
        final host = _Host();
        final first = host.sync();
        expect(host.started, 1);

        // Three concurrent calls while the first body is still in flight.
        unawaited(host.sync());
        unawaited(host.sync());
        unawaited(host.sync());
        // None started yet — they were folded into one pending flag.
        expect(host.started, 1);

        host.release(); // finish the first body
        await first;
        await Future<void>.delayed(
          Duration.zero,
        ); // let the trailing re-run start

        // Exactly ONE trailing run, not three.
        expect(host.started, 2);

        host.release(); // finish the trailing run
        await Future<void>.delayed(Duration.zero);
        // No further runs were queued.
        expect(host.started, 2);
      },
    );

    test('sequential (non-overlapping) calls each run', () async {
      final host = _Host();
      final a = host.sync();
      host.release();
      await a;

      final b = host.sync();
      expect(host.started, 2);
      host.release();
      await b;
    });

    test('a throwing body still resets the guard (no wedge)', () async {
      final host = _ThrowingHost();
      await host.sync(); // first body throws, swallowed by the host
      expect(host.started, 1);
      // The guard is not stuck busy — a later call runs.
      await host.sync();
      expect(host.started, 2);
    });
  });

  // The generation half — the sign-out teardown guard. `runCoalesced` guards
  // sync-against-sync; NOTHING here guarded sync against teardown, and the
  // failure is silent: `deregisterThisDevice` runs BEFORE `signOut()`, so a
  // body resuming mid-teardown still holds a valid credential and its
  // re-registration SUCCEEDS — putting back the push token, presence row or
  // Live Activity registration of a device that just signed out.
  group('generation guard', () {
    test(
      'a new generation runs while an old request remains stalled',
      () async {
        final host = _Host();
        final old = host.sync();
        host.invalidateSync();
        final current = host.sync();
        expect(host.started, 2);
        host.release();
        await old;
        unawaited(host.sync());
        expect(host.started, 2);
        host.release();
        await current;
        await Future<void>.delayed(Duration.zero);
        expect(host.started, 3);
        host.release();
        await Future<void>.delayed(Duration.zero);
      },
    );
    test('a body that ran to completion never looked stale', () async {
      final host = _GenerationHost()..release.complete();
      await host.sync();
      expect(host.abandoned, isFalse);
      expect(host.completed, isTrue);
    });

    test('an in-flight body sees isSyncStale at its next await', () async {
      final host = _GenerationHost();
      final inFlight = host.sync();
      await host.reachedFirstAwait.future;
      host.invalidateSync();
      host.release.complete();
      await inFlight;
      expect(host.abandoned, isTrue);
      expect(host.completed, isFalse);
    });

    test('a generation captured before invalidation stays stale', () {
      final host = _GenerationHost();
      final captured = host.syncGeneration;
      host.invalidateSync();
      expect(host.isSyncStale(captured), isTrue);
      // Permanently — a later unrelated bump must not wrap back to valid.
      host.invalidateSync();
      expect(host.isSyncStale(captured), isTrue);
    });

    test('a generation read after invalidation is fresh again', () {
      final host = _GenerationHost()..invalidateSync();
      expect(host.isSyncStale(host.syncGeneration), isFalse);
    });

    test('invalidateSync also drops a queued rerun', () async {
      final host = _GenerationHost();
      final first = host.sync();
      await host.reachedFirstAwait.future;
      // Queue a rerun behind the in-flight body, then tear down.
      unawaited(host.sync());
      host.invalidateSync();
      host.release.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(host.started, 1);
    });
  });
}

/// Host whose body throws (swallowed the way real controllers do), to prove
/// the guard's `finally` clears busy even on failure.
class _ThrowingHost with ReentrantSync {
  int started = 0;

  Future<void> sync() => runCoalesced(_body);

  Future<void> _body() async {
    started++;
    try {
      throw StateError('boom');
    } catch (_) {
      // Controllers log with their own tag; here we just swallow.
    }
  }
}

/// Host that captures its generation and re-checks it after an await, the way
/// the three device-registration controllers do.
class _GenerationHost with ReentrantSync {
  int started = 0;
  bool abandoned = false;
  bool completed = false;
  Completer<void> reachedFirstAwait = Completer<void>();
  Completer<void> release = Completer<void>();

  Future<void> sync() => runCoalesced(_body);

  Future<void> _body() async {
    started++;
    final generation = syncGeneration;
    if (!reachedFirstAwait.isCompleted) reachedFirstAwait.complete();
    await release.future;
    if (isSyncStale(generation)) {
      abandoned = true;
      return;
    }
    completed = true;
  }
}
