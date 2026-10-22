// `AccountExitListeners` is the only runtime session-kill path in the app, and
// nothing exercised it: the file next to this one imports
// `account_exit_controller.dart` and tests the TEARDOWN, never the three
// listeners that decide when to run it.
//
// Two decisions live here and nowhere else, and both fail silently:
//
//  * the admin-demotion rule, with its empty-string carve-out. An empty role
//    means the doc was deleted, not that the person was demoted — the deletion
//    listener owns that. Drop the carve-out and an invited employee is signed
//    out mid-activation; drop the rule and a demoted admin keeps an admin
//    session for the rest of the day.
//  * the populated→empty transition that `isAccountDeletionSignal` needs. A
//    first-seen empty doc is a bootstrap window (a fresh sign-in whose uid has
//    not resolved, or an invited account signed in before
//    `completeEmployeeSetup` activates its doc), NOT a deletion — which is why
//    `previous` is passed through from the `ref.listen`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/app/account_exit_controller.dart';
import 'package:scheduling/core/app/account_exit_listeners.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Records which exit was asked for instead of tearing a session down — the
/// teardown itself is already covered by `account_exit_listeners_test.dart`.
class _RecordingExit implements AccountExitController {
  final List<String Function(AppLocalizations)> requests = [];

  @override
  Future<void> exitAccount({
    required String Function(AppLocalizations) selectMessage,
    required GlobalKey<NavigatorState> navigatorKey,
    required GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey,
    required bool Function() isMounted,
  }) async {
    requests.add(selectMessage);
  }

  @override
  Future<bool> runVoluntaryTeardown(Future<void> Function() teardown) =>
      throw UnimplementedError();
}

/// The warm-cache probe that separates a cold-start DELETION from an invited
/// account whose doc has not been activated yet. Written right after sign-in,
/// cleared on sign-out — so a hit means "this device saw a real session".
class _StubCache implements AuthCache {
  _StubCache({required this.hit});

  final bool hit;

  @override
  Future<EmployeeRecord?> loadIfMatch(String uid) async => hit
      ? EmployeeRecord(id: 'doc-1', uid: uid, name: 'Ada', status: 'active')
      : null;

  @override
  Future<void> save(EmployeeRecord record) async {}

  @override
  Future<void> clear() async {}
}

void main() {
  late StreamController<Map<String, dynamic>> docs;
  late _RecordingExit exit;

  setUp(() {
    docs = StreamController<Map<String, dynamic>>.broadcast();
    exit = _RecordingExit();
  });

  tearDown(() => docs.close());

  Future<ProviderContainer> containerFor({
    String? uid = 'u1',
    bool warmCache = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        currentUserDocProvider.overrideWith((ref) => docs.stream),
        authUidProvider.overrideWith((ref) => Stream<String?>.value(uid)),
        authCacheProvider.overrideWithValue(_StubCache(hit: warmCache)),
        accountExitControllerProvider.overrideWithValue(exit),
      ],
    )..listen(authUidProvider, (_, _) {});
    addTearDown(container.dispose);
    // The listener reads the uid SYNCHRONOUSLY; an unresolved one reads as
    // signed-out, so settle it before anything is emitted.
    await container.read(authUidProvider.future);
    return container;
  }

  Future<void> pumpListeners(
    WidgetTester tester, {
    String? uid = 'u1',
    bool warmCache = false,
    bool signedIn = true,
    bool mounted = true,
  }) async {
    final container = await containerFor(uid: uid, warmCache: warmCache);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              AccountExitListeners(
                ref: ref,
                navigatorKey: GlobalKey<NavigatorState>(),
                scaffoldMessengerKey: GlobalKey<ScaffoldMessengerState>(),
                isMounted: () => mounted,
                isSignedIn: () => signedIn,
              ).registerAll();
              return const Scaffold(body: SizedBox.shrink());
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> emit(WidgetTester tester, Map<String, dynamic> doc) async {
    docs.add(doc);
    await tester.pumpAndSettle();
  }

  Future<List<String>> messages() async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    return [for (final select in exit.requests) select(l10n)];
  }

  Future<String> revokedMessage() async =>
      (await AppLocalizations.delegate.load(
        const Locale('en'),
      )).error_yourAdminAccessWasRevoked;

  Future<String> disabledMessage() async =>
      (await AppLocalizations.delegate.load(
        const Locale('en'),
      )).error_thisAccountHasBeenDisabled;

  group('admin demotion', () {
    testWidgets('losing the admin role ends the session', (tester) async {
      await pumpListeners(tester);
      await emit(tester, const {'role': 'admin', 'status': 'active'});
      await emit(tester, const {'role': 'employee', 'status': 'active'});

      expect(await messages(), [await revokedMessage()]);
    });

    testWidgets('an EMPTY role is not a demotion — the carve-out', (
      tester,
    ) async {
      // A role that reads empty on a doc that still exists is not a demotion:
      // deletion is what empties it, and that listener owns the exit. Without
      // the carve-out an invited employee — whose doc is mid-activation — is
      // signed out of the setup screen they need.
      await pumpListeners(tester);
      await emit(tester, const {'role': 'admin', 'status': 'active'});
      await emit(tester, const {'status': 'active'});

      expect(exit.requests, isEmpty);
    });

    testWidgets('an emptied doc exits as a deletion, not as a demotion', (
      tester,
    ) async {
      // Both listeners see this transition. Only one may act, and the message
      // the user reads is how you tell which one did.
      await pumpListeners(tester);
      await emit(tester, const {'role': 'admin', 'status': 'active'});
      await emit(tester, const <String, dynamic>{});

      expect(await messages(), [await disabledMessage()]);
    });

    testWidgets('a promotion to admin never exits', (tester) async {
      await pumpListeners(tester);
      await emit(tester, const {'role': 'employee', 'status': 'active'});
      await emit(tester, const {'role': 'admin', 'status': 'active'});

      expect(exit.requests, isEmpty);
    });

    testWidgets('an unrelated edit on an admin doc never exits', (
      tester,
    ) async {
      await pumpListeners(tester);
      await emit(tester, const {'role': 'admin', 'status': 'active'});
      await emit(tester, const {
        'role': 'admin',
        'status': 'active',
        'name': 'Ada',
      });

      expect(exit.requests, isEmpty);
    });
  });

  group('account disabled', () {
    testWidgets('flipping status to disabled ends the session', (tester) async {
      await pumpListeners(tester);
      await emit(tester, const {'role': 'employee', 'status': 'active'});
      await emit(tester, const {'role': 'employee', 'status': 'disabled'});

      expect(await messages(), [await disabledMessage()]);
    });

    testWidgets('an already-active account is left alone', (tester) async {
      await pumpListeners(tester);
      await emit(tester, const {'role': 'employee', 'status': 'active'});

      expect(exit.requests, isEmpty);
    });
  });

  group('deleted account', () {
    testWidgets('a populated→empty transition ends the session', (
      tester,
    ) async {
      // Cold cache on purpose: the live transition must not depend on it.
      await pumpListeners(tester);
      await emit(tester, const {'role': 'employee', 'status': 'active'});
      await emit(tester, const <String, dynamic>{});

      expect(await messages(), [await disabledMessage()]);
    });

    testWidgets('a first-seen empty doc is a bootstrap window, not a deletion', (
      tester,
    ) async {
      // The invited-account case: signed in with the shared starting password,
      // doc not yet activated by completeEmployeeSetup. Simplifying
      // isAccountDeletionSignal back to `doc.isEmpty` kicks this person out
      // mid-activation, and the credential they just used is the one setup
      // needs.
      await pumpListeners(tester);
      await emit(tester, const <String, dynamic>{});

      expect(exit.requests, isEmpty);
    });

    testWidgets('an empty doc plus a warm cache IS a cold-start deletion', (
      tester,
    ) async {
      // The cache is written right after sign-in and cleared on sign-out, so a
      // hit means this device really did hold a session for that uid — which
      // an invited account being set up for the first time never has.
      await pumpListeners(tester, warmCache: true);
      await emit(tester, const <String, dynamic>{});

      expect(await messages(), [await disabledMessage()]);
    });

    testWidgets('a torn-down tree does not exit on the cold-start check', (
      tester,
    ) async {
      // The cold-start probe resolves asynchronously; by then the host State
      // may be gone.
      await pumpListeners(tester, warmCache: true, mounted: false);
      await emit(tester, const <String, dynamic>{});

      expect(exit.requests, isEmpty);
    });

    testWidgets('nothing fires while nobody is signed in', (tester) async {
      await pumpListeners(tester, signedIn: false, warmCache: true);
      await emit(tester, const {'role': 'employee', 'status': 'active'});
      await emit(tester, const <String, dynamic>{});

      expect(exit.requests, isEmpty);
    });

    testWidgets('an unresolved uid is a bootstrap window too', (tester) async {
      // The fresh-sign-in branch: the doc stream has already produced an empty
      // map while the uid is still null.
      await pumpListeners(tester, uid: null, warmCache: true);
      await emit(tester, const {'role': 'employee', 'status': 'active'});
      await emit(tester, const <String, dynamic>{});

      expect(exit.requests, isEmpty);
    });
  });
}
