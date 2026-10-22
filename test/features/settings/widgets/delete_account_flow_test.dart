import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/pending_photo_exit.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/account_deletion_service.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/presence/application/presence_sync_controller.dart';
import 'package:scheduling/features/settings/widgets/views/delete_account_flow.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../../support/account_exit_stubs.dart';

class _MockDeletionService extends Mock implements AccountDeletionService {}

class _MockAuthService extends Mock implements AuthService {}

class _MockPush extends Mock implements PushRegistrationController {}

class _MockPresence extends Mock implements PresenceSyncController {}

class _MockLiveActivity extends Mock
    implements LiveActivityRegistrationController {}

/// The provider overrides every account-exit path needs, in one list so the
/// three tests below cannot drift on it.
List<Override> _exitOverrides({
  required AuthService auth,
  required PushRegistrationController push,
  required PresenceSyncController presence,
  required LiveActivityRegistrationController liveActivity,
  PendingPhotoExit? pendingPhotos,
}) => [
  isOfflineProvider.overrideWithValue(false),
  authServiceProvider.overrideWithValue(auth),
  pushRegistrationControllerProvider.overrideWithValue(push),
  presenceSyncControllerProvider.overrideWithValue(presence),
  liveActivityRegistrationControllerProvider.overrideWithValue(liveActivity),
  ...accountExitStubOverrides(pendingPhotos: pendingPhotos),
];

/// The smallest host the mixin needs — Settings itself carries app-lock
/// lifecycle and the notification toggles, none of which this exercises.
class _Host extends ConsumerStatefulWidget {
  const _Host({required this.service});

  final AccountDeletionService service;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with DeleteAccountFlow<_Host> {
  @override
  AccountDeletionService get deletionService => widget.service;

  @override
  bool get isAdminAccount => false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: signOut, child: const Text('sign out')),
          TextButton(
            onPressed: confirmDeleteAccount,
            child: const Text('delete'),
          ),
        ],
      ),
    ),
  );
}

void main() {
  /// Drives the flow to the re-auth step and returns the notice it pushed.
  Future<String> noticeFor(WidgetTester tester, AuthFailure failure) async {
    final service = _MockDeletionService();
    when(
      () => service.reauthenticateWithPassword(any()),
    ).thenAnswer((_) async => throw failure);

    final container = ProviderContainer(
      overrides: [
        isOfflineProvider.overrideWithValue(false),
        sessionFenceProvider.overrideWithValue(
          SessionFence(readUid: () => 'test-uid'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notices = <AppNotice>[];
    final sub = container
        .read(noticeServiceProvider)
        .stream
        .listen(notices.add);
    addTearDown(sub.cancel);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: _Host(service: service),
        ),
      ),
    );

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    // The confirm dialog, then the re-auth prompt — both label their primary
    // action "Delete permanently", so they are dismissed in order.
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hunter2');
    // The submit button is null-gated on a non-empty password, so the rebuild
    // that enables it has to land before the tap.
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(notices, hasLength(1));
    return notices.single.message;
  }

  setUpAll(() {
    registerFallbackValue('');
  });

  testWidgets(
    'a missing account during re-auth asks the user to log in again',
    (tester) async {
      // The whole point of the reauthentication context: without it this reads
      // "No account found with this email", naming an address the person never
      // typed on a screen that only asked for their password.
      expect(
        await noticeFor(tester, const AuthFailureUserNotFound()),
        'Please log in again and retry',
      );
    },
  );

  testWidgets('a wrong password during re-auth asks the user to log in again', (
    tester,
  ) async {
    expect(
      await noticeFor(tester, const AuthFailureWrongCredentials()),
      'Please log in again and retry',
    );
  });

  testWidgets('double-tapping delete opens only one confirm flow', (
    tester,
  ) async {
    final service = _MockDeletionService();
    when(
      () => service.reauthenticateWithPassword(any()),
    ).thenAnswer((_) async => throw const AuthFailureWrongCredentials());

    final container = ProviderContainer(
      overrides: [
        isOfflineProvider.overrideWithValue(false),
        sessionFenceProvider.overrideWithValue(
          SessionFence(readUid: () => 'test-uid'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: _Host(service: service),
        ),
      ),
    );

    await tester.tap(find.text('delete'));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete account?'), findsOneWidget);
  });

  testWidgets(
    'a sign-out that fails after the host unmounted still restores the '
    'device registrations',
    (tester) async {
      // B6: the rollback used to read its three controllers off `ref` inside
      // the catch — after de-registration and the sign-out round-trip. If
      // Settings unmounted in that window, Riverpod 3 threw a StateError over
      // the real failure, skipping the restore, the notice and the busy reset.
      final service = _MockDeletionService();
      final auth = _MockAuthService();
      final push = _MockPush();
      final presence = _MockPresence();
      final liveActivity = _MockLiveActivity();
      final signOutCompleter = Completer<void>();

      when(auth.signOut).thenAnswer((_) => signOutCompleter.future);
      when(push.unregisterCurrentDevice).thenAnswer((_) async {});
      when(presence.unregister).thenAnswer((_) async => true);
      when(liveActivity.unregister).thenAnswer((_) async {});
      when(push.sync).thenAnswer((_) async {});
      when(presence.sync).thenAnswer((_) async {});
      when(liveActivity.sync).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: _exitOverrides(
          auth: auth,
          push: push,
          presence: presence,
          liveActivity: liveActivity,
        ),
      );
      addTearDown(container.dispose);

      Widget app(Widget home) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: home,
        ),
      );

      await tester.pumpWidget(app(_Host(service: service)));
      await tester.tap(find.text('sign out'));
      await tester.pump();
      await tester.pump();

      // Leave Settings while sign-out is still in flight.
      await tester.pumpWidget(app(const SizedBox.shrink()));
      signOutCompleter.completeError(Exception('boom'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      verify(push.sync).called(1);
      verify(presence.sync).called(1);
      verify(liveActivity.sync).called(1);
    },
  );

  /// Drives the delete flow through both dialogs with the device controllers
  /// wired, so the failure lands AFTER de-registration.
  Future<List<AppNotice>> deleteFailingAfterTeardown(
    WidgetTester tester, {
    required Object error,
    required PushRegistrationController push,
    required PresenceSyncController presence,
    required LiveActivityRegistrationController liveActivity,
    PendingPhotoExit? pendingPhotos,
  }) async {
    final service = _MockDeletionService();
    when(
      () => service.reauthenticateWithPassword(any()),
    ).thenAnswer((_) async {});
    when(service.deleteAccount).thenAnswer((_) => Future<void>.error(error));

    final container = ProviderContainer(
      overrides: _exitOverrides(
        auth: _MockAuthService(),
        push: push,
        presence: presence,
        liveActivity: liveActivity,
        pendingPhotos: pendingPhotos,
      ),
    );
    addTearDown(container.dispose);
    final notices = <AppNotice>[];
    final sub = container
        .read(noticeServiceProvider)
        .stream
        .listen(notices.add);
    addTearDown(sub.cancel);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          home: _Host(service: service),
        ),
      ),
    );

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();
    return notices;
  }

  /// The three controllers, stubbed for both directions of the teardown.
  ({
    PushRegistrationController push,
    PresenceSyncController presence,
    LiveActivityRegistrationController liveActivity,
  })
  wiredControllers() {
    final push = _MockPush();
    final presence = _MockPresence();
    final liveActivity = _MockLiveActivity();
    when(push.unregisterCurrentDevice).thenAnswer((_) async {});
    when(presence.unregister).thenAnswer((_) async => true);
    when(liveActivity.unregister).thenAnswer((_) async {});
    when(push.sync).thenAnswer((_) async {});
    when(presence.sync).thenAnswer((_) async {});
    when(liveActivity.sync).thenAnswer((_) async {});
    return (push: push, presence: presence, liveActivity: liveActivity);
  }

  testWidgets(
    'pending photos can cancel account deletion after reauthentication',
    (tester) async {
      final c = wiredControllers();
      final notices = await deleteFailingAfterTeardown(
        tester,
        error: Exception('deletion must not run'),
        push: c.push,
        presence: c.presence,
        liveActivity: c.liveActivity,
        pendingPhotos: const PendingPhotoExit(pendingCount: 1),
      );
      expect(find.text('Photos waiting to save'), findsOneWidget);
      await tester.tap(find.text('Stay and retry'));
      await tester.pumpAndSettle();

      expect(notices, isEmpty);
      verifyNever(c.push.unregisterCurrentDevice);
      expect(find.text('delete'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final discard in [false, true]) {
    testWidgets(
      'logout with pending photos requires explicit discard: $discard',
      (tester) async {
        final auth = _MockAuthService();
        final deletion = _MockDeletionService();
        final c = wiredControllers();
        when(auth.signOut).thenAnswer((_) async {});
        final container = ProviderContainer(
          overrides: _exitOverrides(
            auth: auth,
            push: c.push,
            presence: c.presence,
            liveActivity: c.liveActivity,
            pendingPhotos: const PendingPhotoExit(pendingCount: 2),
          ),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: lightTheme(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routes: {
                '/login': (_) => const Scaffold(body: Text('login screen')),
              },
              home: _Host(service: deletion),
            ),
          ),
        );
        await tester.tap(find.text('sign out'));
        await tester.pumpAndSettle();
        verifyNever(auth.signOut);
        verifyNever(c.push.unregisterCurrentDevice);
        await tester.tap(
          find.text(discard ? 'Discard photos and continue' : 'Stay and retry'),
        );
        await tester.pumpAndSettle();

        if (discard) {
          expect(find.text('login screen'), findsOneWidget);
          verify(auth.signOut).called(1);
        } else {
          expect(find.text('sign out'), findsOneWidget);
          verifyNever(auth.signOut);
          verifyNever(c.push.unregisterCurrentDevice);
          await tester.tap(find.text('sign out'));
          await tester.pumpAndSettle();
          expect(find.text('Photos waiting to save'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a deletion that fails AFTER de-registration puts the device back',
    (tester) async {
      // The arm no test reached. Every existing case fails during RE-AUTH,
      // which happens before `deregisterThisDevice` runs — so `deregistered`
      // is null and the rollback short-circuits. Failing at `deleteAccount()`
      // is the real hazard: the user is still signed in, but this device has
      // already dropped its push token, its presence row and its Live Activity
      // registration, so they silently stop receiving anything and vanish off
      // the admin's live map with nothing on screen to say so.
      final c = wiredControllers();
      final notices = await deleteFailingAfterTeardown(
        tester,
        error: Exception('server said no'),
        push: c.push,
        presence: c.presence,
        liveActivity: c.liveActivity,
      );

      verify(c.push.sync).called(1);
      verify(c.presence.sync).called(1);
      verify(c.liveActivity.sync).called(1);
      expect(notices, hasLength(1));
      expect(notices.single.message, contains("Couldn't delete your account"));
    },
  );

  testWidgets(
    'a typed AuthFailure after de-registration also puts the device back',
    (tester) async {
      // The `on AuthFailure` arm has its own copy of the rollback, so it needs
      // its own case — the generic `catch` below it never runs for these.
      final c = wiredControllers();
      final notices = await deleteFailingAfterTeardown(
        tester,
        error: const AuthFailureRequiresRecentLogin(),
        push: c.push,
        presence: c.presence,
        liveActivity: c.liveActivity,
      );

      verify(c.push.sync).called(1);
      verify(c.presence.sync).called(1);
      verify(c.liveActivity.sync).called(1);
      expect(notices, hasLength(1));
    },
  );

  testWidgets(
    'delete flow cannot start while sign-out is already in progress',
    (tester) async {
      final service = _MockDeletionService();
      final auth = _MockAuthService();
      final push = _MockPush();
      final presence = _MockPresence();
      final liveActivity = _MockLiveActivity();
      final signOutCompleter = Completer<void>();
      Future<void> waitForSignOut(_) => signOutCompleter.future;

      when(auth.signOut).thenAnswer(waitForSignOut);
      when(push.unregisterCurrentDevice).thenAnswer((_) async {});
      when(presence.unregister).thenAnswer((_) async => true);
      when(liveActivity.unregister).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: _exitOverrides(
          auth: auth,
          push: push,
          presence: presence,
          liveActivity: liveActivity,
        ),
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: lightTheme(),
            home: _Host(service: service),
          ),
        ),
      );

      await tester.tap(find.text('sign out'));
      await tester.pump();

      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();

      expect(find.text('Delete account?'), findsNothing);
      verifyNever(() => service.reauthenticateWithPassword(any()));

      signOutCompleter.complete();
    },
  );
}
