import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/app/session_fence.dart';

void main() {
  test('exit fences work while Firebase still has the original credential', () {
    final fence = SessionFence(readUid: () => 'A');
    final lease = fence.capture()!;
    fence.beginExit();
    expect(lease.isCurrent, isFalse);
    expect(fence.capture(), isNull);
    expect(fence.capture(duringExit: true)!.isCurrent, isTrue);
  });

  test('a UID switch is detected before its stream event is delivered', () {
    String? uid = 'A';
    final fence = SessionFence(readUid: () => uid);
    final lease = fence.capture()!;
    uid = 'B';
    expect(lease.isCurrent, isFalse);
    expect(fence.capture()!.uid, 'B');
  });

  test('returning to the same UID cannot revive a previous session', () {
    String? uid = 'A';
    final fence = SessionFence(readUid: () => uid);
    final lease = fence.capture()!;
    uid = null;
    fence.observeUid(uid);
    uid = 'A';
    fence.observeUid(uid);
    expect(lease.isCurrent, isFalse);
    expect(fence.capture()!.isCurrent, isTrue);
  });

  test('failed exit restores eligibility without reviving stale cleanup', () {
    final fence = SessionFence(readUid: () => 'A');
    final old = fence.capture()!;
    fence.beginExit();
    final cleanup = fence.capture(duringExit: true)!;
    fence.resume();
    expect(old.isCurrent, isFalse);
    expect(cleanup.isCurrent, isFalse);
    expect(fence.capture()!.isCurrent, isTrue);
  });
}
