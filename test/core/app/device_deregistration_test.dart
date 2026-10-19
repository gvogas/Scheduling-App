import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';

import '../../support/account_exit_stubs.dart';

class _MockPush extends Mock implements PushRegistrationController {}

class _MockPresence extends Mock implements PresenceSyncController {}

class _MockLiveActivity extends Mock
    implements LiveActivityRegistrationController {}

/// `deregisterThisDevice` drops every server-side registration this device
/// holds, and it is reached from all three account exits (the runtime
/// account-deletion signal, Settings' sign-out, Settings' delete-account).
///
/// Two properties are pinned here because a regression in either is a PRIVACY
/// leak rather than a visible bug: a surviving `fcmToken` keeps pushing to a
/// signed-out device, and a surviving `presence/location` keeps rendering the
/// person on the admin's live map — where `LiveMapAggregator.join` filters on
/// missing/inactive user and never on freshness, so the stale pin looks live.
void main() {
  late _MockPush push;
  late _MockPresence presence;
  late _MockLiveActivity liveActivity;
  late List<String> calls;

  setUp(() {
    push = _MockPush();
    presence = _MockPresence();
    liveActivity = _MockLiveActivity();
    calls = [];

    when(push.unregisterCurrentDevice).thenAnswer((_) async {
      calls.add('push');
    });
    when(presence.unregister).thenAnswer((_) async {
      calls.add('presence');
      return true;
    });
    when(liveActivity.unregister).thenAnswer((_) async {
      calls.add('liveActivity');
    });
  });

  /// Pumps a widget holding a real `WidgetRef` and runs the function through
  /// it — the signature is `WidgetRef`, not `Ref`, because all three exits are
  /// widget-layer.
  Future<void> run(WidgetTester tester, {SessionFence? session}) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pushRegistrationControllerProvider.overrideWithValue(push),
          presenceSyncControllerProvider.overrideWithValue(presence),
          liveActivityRegistrationControllerProvider.overrideWithValue(
            liveActivity,
          ),
          ...accountExitStubOverrides(calls: calls, session: session),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await deregisterThisDevice(DeviceDeregistrationDeps.from(captured.read));
  }

  testWidgets(
    'exit fences work before a held push cleanup and cannot clear the next account',
    (tester) async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      final oldWork = session.capture()!;
      final entered = Completer<void>();
      final release = Completer<void>();
      when(push.unregisterCurrentDevice).thenAnswer((_) {
        calls.add('push');
        entered.complete();
        return release.future;
      });
      final pending = run(tester, session: session);
      await entered.future;
      expect(oldWork.isCurrent, isFalse);
      expect(session.capture(), isNull);
      uid = 'B';
      release.complete();
      await pending;
      expect(calls, [
        'push',
        'presence',
        'liveActivity',
        'imageCache',
        'imageUploads',
        'clients',
        'appointments',
      ]);
      expect(session.capture()!.uid, 'B');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tears down push, presence and Live Activity, then every local cache',
    (tester) async {
      // The ORDER is load-bearing: each server-side step needs the credential
      // that sign-out revokes, and callers run this ahead of the revocation.
      // The three local caches are purely local, so they go last — but they
      // must still GO: the photo bytes are on disk and outlive the process,
      // and both repository windows hold this user's client and appointment
      // PII for the life of the process.
      await run(tester);

      expect(calls, [
        'push',
        'presence',
        'liveActivity',
        'imageCache',
        'imageUploads',
        'clients',
        'appointments',
      ]);
    },
  );

  testWidgets('a stalled remote cleanup cannot hold exit past its budget', (
    tester,
  ) async {
    final entered = Completer<void>();
    final stalled = Completer<void>();
    when(push.unregisterCurrentDevice).thenAnswer((_) {
      calls.add('push');
      entered.complete();
      return stalled.future;
    });
    var completed = false;
    final pending = run(tester).then((_) => completed = true);
    await entered.future;
    expect(
      calls,
      containsAll(['presence', 'liveActivity', 'clients', 'appointments']),
    );
    expect(completed, isFalse);
    await tester.pump(deviceCleanupBudget);
    await pending;
    expect(completed, isTrue);
    stalled.completeError(Exception('late cleanup error'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failing first step does not skip the other two', (
    tester,
  ) async {
    // The whole point. These used to be three bare awaits, so a throw from the
    // push teardown silently skipped presence and Live Activity — leaving
    // exactly the rows that are visible to OTHER people.
    when(push.unregisterCurrentDevice).thenThrow(Exception('no network'));

    await run(tester);

    expect(calls, [
      'presence',
      'liveActivity',
      'imageCache',
      'imageUploads',
      'clients',
      'appointments',
    ]);
    verify(presence.unregister).called(1);
    verify(liveActivity.unregister).called(1);
  });

  testWidgets('a failing middle step does not skip the last', (tester) async {
    when(presence.unregister).thenThrow(Exception('permission denied'));

    await run(tester);

    expect(calls, [
      'push',
      'liveActivity',
      'imageCache',
      'imageUploads',
      'clients',
      'appointments',
    ]);
  });

  testWidgets('never rethrows, so it cannot block the sign-out behind it', (
    tester,
  ) async {
    // Best-effort by contract: callers run this ahead of the action that
    // actually protects the user.
    when(push.unregisterCurrentDevice).thenThrow(Exception('a'));
    when(presence.unregister).thenThrow(Exception('b'));
    when(liveActivity.unregister).thenThrow(Exception('c'));

    await run(tester);

    expect(tester.takeException(), isNull);
  });
}
