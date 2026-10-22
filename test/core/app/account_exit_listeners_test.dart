// Pins the two things the forced-exit flow calls load-bearing: the teardown
// ORDER (de-register everything BEFORE signOut, because each de-registration
// needs the credential sign-out revokes) and the one-exit-at-a- time guard
// (three listeners can fire for a single underlying event).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/account_exit_controller.dart';
import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

import '../../support/account_exit_stubs.dart';

class _MockPush extends Mock implements PushRegistrationController {}

class _MockPresence extends Mock implements PresenceSyncController {}

class _MockLiveActivity extends Mock
    implements LiveActivityRegistrationController {}

class _MockAuthService extends Mock implements AuthService {}

void main() {
  late _MockPush push;
  late _MockPresence presence;
  late _MockLiveActivity liveActivity;
  late _MockAuthService auth;
  late List<String> calls;
  late GlobalKey<NavigatorState> navigatorKey;
  late GlobalKey<ScaffoldMessengerState> messengerKey;
  late List<String?> pushedRoutes;

  setUp(() {
    push = _MockPush();
    presence = _MockPresence();
    liveActivity = _MockLiveActivity();
    auth = _MockAuthService();
    calls = [];
    navigatorKey = GlobalKey<NavigatorState>();
    messengerKey = GlobalKey<ScaffoldMessengerState>();
    pushedRoutes = [];

    when(() => push.unregisterCurrentDevice()).thenAnswer((_) async {
      calls.add('push');
    });
    when(() => presence.unregister()).thenAnswer((_) async {
      calls.add('presence');
      return true;
    });
    when(() => liveActivity.unregister()).thenAnswer((_) async {
      calls.add('liveActivity');
    });
    when(() => auth.signOut()).thenAnswer((_) async {
      calls.add('signOut');
    });
  });

  /// Pumps a real MaterialApp so navigatorKey.currentContext resolves — the
  /// handler bails early without one.
  Future<AccountExitController> pumpController(
    WidgetTester tester, {
    bool signedIn = true,
    SessionFence? session,
    int pendingPhotos = 0,
  }) async {
    late AccountExitController controller;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pushRegistrationControllerProvider.overrideWithValue(push),
          presenceSyncControllerProvider.overrideWithValue(presence),
          liveActivityRegistrationControllerProvider.overrideWithValue(
            liveActivity,
          ),
          authServiceProvider.overrideWithValue(auth),
          ...accountExitStubOverrides(session: session),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: messengerKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // Records what the exit pushes.
          onGenerateRoute: (settings) {
            pushedRoutes.add(settings.name);
            return MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const Scaffold(body: SizedBox.shrink()),
            );
          },
          home: Consumer(
            builder: (context, ref, _) {
              controller = AccountExitController(
                logger: AppLogger(),
                authService: auth,
                deregisterDevice: () => deregisterThisDevice(
                  DeviceDeregistrationDeps.from(ref.read),
                ),
                isSignedIn: () => signedIn,
                sessionForExit: session == null ? null : () => session,
                pendingPhotoCount: () => pendingPhotos,
              );
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('forced exit discloses known unsaved photo work', (tester) async {
    final controller = await pumpController(tester, pendingPhotos: 2);
    await controller.exitAccount(
      selectMessage: (_) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Some photos had not finished saving.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a forced exit cannot sign out the next user after held cleanup',
    (tester) async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      final entered = Completer<void>();
      final release = Completer<void>();
      when(push.unregisterCurrentDevice).thenAnswer((_) {
        entered.complete();
        return release.future;
      });
      final controller = await pumpController(tester, session: session);
      final pending = controller.exitAccount(
        selectMessage: (_) => 'disabled',
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        isMounted: () => true,
      );
      await entered.future;
      uid = 'B';
      release.complete();
      await pending;
      await tester.pumpAndSettle();
      verifyNever(auth.signOut);
      expect(pushedRoutes, isEmpty);
      expect(session.capture()!.uid, 'B');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tears every registration down BEFORE signing out', (
    tester,
  ) async {
    final controller = await pumpController(tester);

    await controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    await tester.pumpAndSettle();

    // Reordering signOut above any de-registration makes those writes fail
    // permission-denied — swallowed by the best-effort catches, so a terminated
    // user quietly keeps receiving pushes.
    expect(calls, ['push', 'presence', 'liveActivity', 'signOut']);
  });

  testWidgets('a second signal while one exit is in flight is ignored', (
    tester,
  ) async {
    final controller = await pumpController(tester);

    // Three listeners can fire for one underlying event (a delete flips status
    // AND empties the doc).
    final first = controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    final second = controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    await Future.wait([first, second]);
    await tester.pumpAndSettle();

    verify(() => auth.signOut()).called(1);
    expect(calls.where((c) => c == 'signOut').length, 1);
  });

  testWidgets('a forced exit during a voluntary teardown is ignored', (
    tester,
  ) async {
    final controller = await pumpController(tester);
    final release = Completer<void>();

    final voluntary = controller.runVoluntaryTeardown(() => release.future);
    await controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    release.complete();

    expect(await voluntary, isTrue);
    expect(calls, isEmpty);
  });

  testWidgets('a voluntary teardown during a forced exit does not run', (
    tester,
  ) async {
    final controller = await pumpController(tester);
    final release = Completer<void>();
    when(push.unregisterCurrentDevice).thenAnswer((_) => release.future);

    final forced = controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    var ran = false;
    final voluntary = await controller.runVoluntaryTeardown(
      () async => ran = true,
    );
    release.complete();
    await forced;
    await tester.pumpAndSettle();

    expect((voluntary, ran), (false, false));
  });

  testWidgets('does nothing when nobody is signed in', (tester) async {
    final controller = await pumpController(tester, signedIn: false);

    await controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    verifyNever(() => auth.signOut());
  });

  testWidgets(
    'a failed sign-out releases the guard so the next signal retries',
    (tester) async {
      final controller = await pumpController(tester);
      when(() => auth.signOut()).thenThrow(Exception('network'));

      await controller.exitAccount(
        selectMessage: (l10n) => 'disabled',
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        isMounted: () => true,
      );
      await tester.pumpAndSettle();

      // The guard must NOT stay latched on failure — the account is still live
      // on this device until a retry succeeds.
      when(() => auth.signOut()).thenAnswer((_) async {
        calls.add('signOut');
      });
      await controller.exitAccount(
        selectMessage: (l10n) => 'disabled',
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        isMounted: () => true,
      );
      await tester.pumpAndSettle();

      expect(calls.where((c) => c == 'signOut').length, 1);
    },
  );

  testWidgets('sends the signed-out user to the login route', (tester) async {
    // The ORDER and the guard were pinned; the navigation was not.
    final controller = await pumpController(tester);

    await controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    // The navigation and the snack bar run from an addPostFrameCallback, and a
    // callback registered while the binding is idle does not run until a frame
    // is actually scheduled — in the app something is always rendering, in a
    // test nothing is.
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();

    expect(pushedRoutes, [AppRoutes.login]);
  });

  testWidgets('shows the reason on the way out', (tester) async {
    final controller = await pumpController(tester);

    await controller.exitAccount(
      selectMessage: (l10n) => 'your account was disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => true,
    );
    // The navigation and the snack bar run from an addPostFrameCallback, and a
    // callback registered while the binding is idle does not run until a frame
    // is actually scheduled — in the app something is always rendering, in a
    // test nothing is.
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();

    expect(find.text('your account was disabled'), findsOneWidget);
  });

  testWidgets('an unmounted app navigates nowhere and releases the guard', (
    tester,
  ) async {
    var mounted = true;
    final controller = await pumpController(tester);

    await controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => mounted,
    );
    mounted = false;
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();

    expect(pushedRoutes, isEmpty);

    // The half the name promised and nothing proved: releasing the guard is
    // only observable by exiting AGAIN. Left latched, the app that comes back
    // stays signed in on a revoked account with no second signal to save it.
    mounted = true;
    await controller.exitAccount(
      selectMessage: (l10n) => 'disabled',
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      isMounted: () => mounted,
    );
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();

    expect(pushedRoutes, [AppRoutes.login]);
  });
}
