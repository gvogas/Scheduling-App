import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/account_exit_controller.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/security/app_lock.dart';
import 'package:scheduling/core/security/biometric_auth_service.dart';
import 'package:scheduling/core/storage/secure_storage_service.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockSecureStorage extends Mock implements SecureStorageService {}

class _MockBiometrics extends Mock implements BiometricAuthService {}

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockAccountExit extends Mock implements AccountExitController {}

/// Drives the lifecycle the way the OS does, so the widget's observer fires.
void _lifecycle(AppLifecycleState state) =>
    WidgetsBinding.instance.handleAppLifecycleStateChanged(state);

void main() {
  late _MockSecureStorage storage;
  late _MockBiometrics biometrics;

  setUpAll(() {
    registerFallbackValue(GlobalKey<NavigatorState>());
    registerFallbackValue(GlobalKey<ScaffoldMessengerState>());
    registerFallbackValue((AppLocalizations _) => '');
    registerFallbackValue(() => true);
  });

  setUp(() {
    storage = _MockSecureStorage();
    biometrics = _MockBiometrics();
    when(() => biometrics.isAvailable()).thenAnswer((_) async => true);
    when(() => biometrics.authenticate(any())).thenAnswer((_) async => false);
  });

  Future<void> pumpLock(
    WidgetTester tester, {
    _MockAccountExit? exit,
    FirebaseAuth? auth,
    GlobalKey<NavigatorState>? navigatorKey,
    GlobalKey<ScaffoldMessengerState>? messengerKey,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageServiceProvider.overrideWithValue(storage),
          biometricAuthServiceProvider.overrideWithValue(biometrics),
          if (exit != null)
            accountExitControllerProvider.overrideWithValue(exit),
          if (auth != null) firebaseAuthProvider.overrideWithValue(auth),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: messengerKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppLock(
            navigatorKey: navigatorKey,
            scaffoldMessengerKey: messengerKey,
            child: const Scaffold(body: Text('secret')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The lock overlay is private, so key off its Unlock button.
  bool isLocked(WidgetTester tester) =>
      find.byIcon(Icons.lock_open_rounded).evaluate().isNotEmpty;

  testWidgets('a resolved-off flag leaves the app unlocked in the background', (
    tester,
  ) async {
    when(() => storage.readFlag(any())).thenAnswer((_) async => false);
    await pumpLock(tester);

    _lifecycle(AppLifecycleState.inactive);
    await tester.pumpAndSettle();

    expect(isLocked(tester), isFalse);
  });

  testWidgets('an UNRESOLVED flag still locks on backgrounding', (
    tester,
  ) async {
    // The gate the OS grabs its app-switcher snapshot behind. Reading the
    // tri-state as a plain bool here left the signed-in session in the
    // switcher unprotected for the whole session after one failed read.
    when(() => storage.readFlag(any())).thenThrow(Exception('keystore'));
    await pumpLock(tester);

    _lifecycle(AppLifecycleState.inactive);
    await tester.pumpAndSettle();

    expect(isLocked(tester), isTrue);
  });

  testWidgets('resume releases a defensive lock once the retry reads off', (
    tester,
  ) async {
    // The retry is held open so the defensive lock is observable: the widget
    // fires one from initState, and letting it settle immediately resolves the
    // flag before backgrounding ever happens.
    final retry = Completer<bool>();
    var attempt = 0;
    when(() => storage.readFlag(any())).thenAnswer((_) {
      if (attempt++ == 0) return Future<bool>.error(Exception('keystore'));
      return retry.future;
    });
    await pumpLock(tester);

    _lifecycle(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(isLocked(tester), isTrue, reason: 'locked while unresolved');

    _lifecycle(AppLifecycleState.resumed);
    await tester.pump();
    retry.complete(false);
    await tester.pumpAndSettle();

    // Never opted in, so they must not be held behind a biometric prompt.
    expect(isLocked(tester), isFalse);
    verifyNever(() => biometrics.authenticate(any()));
  });

  testWidgets('a PERSISTENTLY unreadable flag still degrades to unlocked', (
    tester,
  ) async {
    // The other half of the tri-state rule, and the one no test pinned: the
    // defensive lock buys the app-switcher window, not a hard guarantee.
    // Someone who never enabled biometrics must never be trapped behind a
    // prompt they cannot satisfy, so a read that NEVER succeeds opens up.
    when(() => storage.readFlag(any())).thenThrow(Exception('keystore'));
    await pumpLock(tester);

    _lifecycle(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(isLocked(tester), isTrue, reason: 'locked while unresolved');

    _lifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(isLocked(tester), isFalse);
    verifyNever(() => biometrics.authenticate(any()));
  });

  testWidgets('resume keeps the lock and prompts when the retry reads on', (
    tester,
  ) async {
    var attempt = 0;
    when(() => storage.readFlag(any())).thenAnswer((_) async {
      if (attempt++ == 0) throw Exception('keystore');
      return true;
    });
    await pumpLock(tester);

    _lifecycle(AppLifecycleState.inactive);
    await tester.pumpAndSettle();

    _lifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(isLocked(tester), isTrue);
    verify(() => biometrics.authenticate(any())).called(greaterThan(0));
  });

  testWidgets('unavailable biometrics says so INLINE and Continue opens the '
      'session WITHOUT disabling the stored setting', (tester) async {
    // `isAvailable()` is `try { isDeviceSupported() } catch { false }`, so it
    // returns false for the pre-first-unlock `local_auth` channel window this
    // whole subsystem exists to handle. Persisting that answer turns the
    // user's app lock off forever after one hiccup. The message used to be a
    // toast over a vanishing overlay (C21); now the overlay stays and explains
    // itself, and Continue is the same session-only release.
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    when(
      () => storage.writeFlag(any(), value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(() => biometrics.isAvailable()).thenAnswer((_) async => false);

    await pumpLock(tester);

    expect(
      find.text("Biometric lock isn't available on this device."),
      findsOneWidget,
    );
    expect(isLocked(tester), isFalse, reason: 'no biometric prompt to retry');
    verifyNever(() => biometrics.authenticate(any()));

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(
      find.text('Continue'),
      findsNothing,
      reason: 'open for THIS session',
    );
    verifyNever(() => storage.writeFlag(any(), value: any(named: 'value')));
  });

  testWidgets('the overlay offers no Log out without the navigator keys', (
    tester,
  ) async {
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    await pumpLock(tester);

    expect(isLocked(tester), isTrue);
    expect(find.text('Log out'), findsNothing);
  });

  testWidgets(
    'Log out exits through AccountExitController and drops the lock',
    (tester) async {
      // C21: the overlay was a dead end for someone whose biometrics no longer
      // match. The exit goes through the ONE shared owner (ADR-0026), and the
      // lock lifts only once nobody is signed in — a signed-out app has nothing
      // left to protect.
      when(() => storage.readFlag(any())).thenAnswer((_) async => true);
      final exit = _MockAccountExit();
      final auth = _MockFirebaseAuth();
      final user = _MockUser();
      when(() => auth.currentUser).thenReturn(user);
      when(
        () => exit.exitAccount(
          selectMessage: any(named: 'selectMessage'),
          navigatorKey: any(named: 'navigatorKey'),
          scaffoldMessengerKey: any(named: 'scaffoldMessengerKey'),
          isMounted: any(named: 'isMounted'),
        ),
      ).thenAnswer((_) async => when(() => auth.currentUser).thenReturn(null));
      await pumpLock(
        tester,
        exit: exit,
        auth: auth,
        navigatorKey: GlobalKey<NavigatorState>(),
        messengerKey: GlobalKey<ScaffoldMessengerState>(),
      );
      expect(isLocked(tester), isTrue);

      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();

      verify(
        () => exit.exitAccount(
          selectMessage: any(named: 'selectMessage'),
          navigatorKey: any(named: 'navigatorKey'),
          scaffoldMessengerKey: any(named: 'scaffoldMessengerKey'),
          isMounted: any(named: 'isMounted'),
        ),
      ).called(1);
      expect(isLocked(tester), isFalse);
    },
  );

  testWidgets('a Log out that leaves the session signed in keeps the lock', (
    tester,
  ) async {
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    final exit = _MockAccountExit();
    final auth = _MockFirebaseAuth();
    when(() => auth.currentUser).thenReturn(_MockUser());
    when(
      () => exit.exitAccount(
        selectMessage: any(named: 'selectMessage'),
        navigatorKey: any(named: 'navigatorKey'),
        scaffoldMessengerKey: any(named: 'scaffoldMessengerKey'),
        isMounted: any(named: 'isMounted'),
      ),
    ).thenAnswer((_) async {});
    await pumpLock(
      tester,
      exit: exit,
      auth: auth,
      navigatorKey: GlobalKey<NavigatorState>(),
      messengerKey: GlobalKey<ScaffoldMessengerState>(),
    );

    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();

    expect(isLocked(tester), isTrue);
  });

  testWidgets('a successful unlock clears the gate', (tester) async {
    // THE RELEASE SIDE, which no test reached: every other case here stubs
    // `authenticate` to false or to a throw, so the one transition the whole
    // feature exists to perform never executed under test. A regression that
    // locked the app and never opened it would have shipped green.
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    when(() => biometrics.authenticate(any())).thenAnswer((_) async => true);

    await pumpLock(tester);

    expect(isLocked(tester), isFalse);
    verify(() => biometrics.authenticate(any())).called(1);
  });

  testWidgets('a refused unlock keeps the gate up and can be retried', (
    tester,
  ) async {
    // The pair to the case above: refusing must leave the overlay in place
    // AND leave the Unlock button working, or a mistyped passcode strands the
    // user on a screen with no way forward.
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    await pumpLock(tester);
    expect(isLocked(tester), isTrue);

    when(() => biometrics.authenticate(any())).thenAnswer((_) async => true);
    await tester.tap(find.byIcon(Icons.lock_open_rounded));
    await tester.pumpAndSettle();

    expect(isLocked(tester), isFalse);
  });

  testWidgets('stays locked across hidden and paused, not only inactive', (
    tester,
  ) async {
    // All three states are named in the widget's guard and only `inactive` was
    // ever pumped. They cannot be driven independently — Flutter's binding
    // enforces resumed → inactive → hidden → paused and silently drops a jump —
    // so what is pinned here is that the lock SURVIVES the whole descent. A
    // guard that dropped `paused`/`hidden` would still lock on `inactive`, so
    // only walking the sequence catches it.
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    when(() => biometrics.authenticate(any())).thenAnswer((_) async => true);
    await pumpLock(tester);
    expect(isLocked(tester), isFalse, reason: 'unlocked at start');

    when(() => biometrics.authenticate(any())).thenAnswer((_) async => false);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      _lifecycle(state);
      await tester.pumpAndSettle();
      expect(isLocked(tester), isTrue, reason: 'locked at $state');
    }
  });

  testWidgets(
    'resume re-prompts and unlocks a session locked by backgrounding',
    (tester) async {
      // The full round trip an ordinary app switch takes, which no test drove
      // end to end: unlocked → backgrounded → locked → resumed → unlocked.
      when(() => storage.readFlag(any())).thenAnswer((_) async => true);
      when(() => biometrics.authenticate(any())).thenAnswer((_) async => true);
      await pumpLock(tester);
      expect(isLocked(tester), isFalse);

      when(() => biometrics.authenticate(any())).thenAnswer((_) async => false);
      _lifecycle(AppLifecycleState.inactive);
      _lifecycle(AppLifecycleState.hidden);
      _lifecycle(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(isLocked(tester), isTrue);

      when(() => biometrics.authenticate(any())).thenAnswer((_) async => true);
      _lifecycle(AppLifecycleState.hidden);
      _lifecycle(AppLifecycleState.inactive);
      _lifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(isLocked(tester), isFalse);
    },
  );

  testWidgets('a thrown biometric prompt does not escape the zone handler', (
    tester,
  ) async {
    when(() => storage.readFlag(any())).thenAnswer((_) async => true);
    when(() => biometrics.authenticate(any())).thenThrow(Exception('plugin'));
    await pumpLock(tester);

    expect(isLocked(tester), isTrue);
    expect(tester.takeException(), isNull);
  });
}
