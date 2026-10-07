import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_activities/live_activities.dart';
import 'package:live_activities/models/activity_update.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/live_activity/application/live_activity_preference.dart';
import 'package:scheduling/features/live_activity/application/live_activity_registration_controller.dart';
import 'package:scheduling/features/live_activity/data/live_activity_token_repository.dart';
import 'package:scheduling/features/live_activity/domain/live_activity_token.dart';
import 'package:shared_preferences/shared_preferences.dart';

FeatureFlags _flags({bool liveAct = true}) => FeatureFlags(
  addressAutocomplete: true,
  presence: true,
  liveActivities: liveAct,
  waveSync: true,
  minSupportedBuild: 0,
);

class _MockAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockTokenRepo extends Mock implements LiveActivityTokenRepository {}

class _MockPlugin extends Mock implements LiveActivities {}

class _FlagsController extends Notifier<FeatureFlags> {
  @override
  FeatureFlags build() => _flags();

  void liveActivities({required bool on}) => state = _flags(liveAct: on);
}

final _flagsSource = NotifierProvider<_FlagsController, FeatureFlags>(
  _FlagsController.new,
);

// NOTE ON COVERAGE
// The iOS gate is now an INJECTED `isIosPlatform` predicate rather than a bare
// `dart:io Platform.isIOS`, so `sync()`'s pre-plugin branches are reachable
// from this host — see the "on-iOS" group below. What stays device-only is
// everything past `_ensurePlugin()`: the ActivityKit probes and the two token
// streams have no seam and are not faked here.
void main() {
  late _MockAuth auth;
  late _MockUser user;
  late _MockEmployeesRepo employees;
  late _MockTokenRepo tokenRepo;

  setUpAll(() {
    registerFallbackValue(LiveActivityTokenKind.pushToStart);
    registerFallbackValue(DateTime(2026));
  });

  setUp(() {
    auth = _MockAuth();
    user = _MockUser();
    employees = _MockEmployeesRepo();
    tokenRepo = _MockTokenRepo();

    when(() => user.uid).thenReturn('uid-1');
    when(() => auth.currentUser).thenReturn(user);
    when(
      () => employees.findUserByUid(any()),
    ).thenAnswer((_) async => const UserUidMatch(id: 'doc-1', data: {}));
    when(
      () => tokenRepo.deleteTokensOfKind(
        userDocId: any(named: 'userDocId'),
        kind: LiveActivityTokenKind.pushToStart,
      ),
    ).thenAnswer((_) async {});
  });

  ProviderContainer makeContainer({
    bool onIos = false,
    Map<String, dynamic>? accountDoc,
  }) {
    final container = ProviderContainer(
      overrides: [
        employeesRepositoryProvider.overrideWithValue(employees),
        featureFlagsProvider.overrideWithValue(_flags()),
        liveActivityTokenRepositoryProvider.overrideWithValue(tokenRepo),
        if (accountDoc != null)
          currentUserDocProvider.overrideWith(
            (ref) => Stream<Map<String, dynamic>>.value(accountDoc),
          ),
        liveActivityRegistrationControllerProvider.overrideWith(
          (ref) => LiveActivityRegistrationController(
            ref,
            auth: auth,
            isIosPlatform: () => onIos,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  LiveActivityRegistrationController controllerOf(ProviderContainer c) =>
      c.read(liveActivityRegistrationControllerProvider);

  group('unregister', () {
    test(
      'resolves the users-doc id itself and deletes push-to-start rows by kind '
      'even when sync() never ran',
      () async {
        final controller = controllerOf(makeContainer());

        // sync() has never run, so `_docId` is unset — unregister must resolve
        // the id from the signed-in uid on its own.
        await controller.unregister();

        verify(() => employees.findUserByUid('uid-1')).called(1);
        verify(
          () => tokenRepo.deleteTokensOfKind(
            userDocId: 'doc-1',
            kind: LiveActivityTokenKind.pushToStart,
          ),
        ).called(1);
      },
    );

    test('signed-out session deletes nothing', () async {
      when(() => auth.currentUser).thenReturn(null);
      final controller = controllerOf(makeContainer());

      await controller.unregister();

      verifyNever(() => employees.findUserByUid(any()));
      verifyNever(
        () => tokenRepo.deleteTokensOfKind(
          userDocId: any(named: 'userDocId'),
          kind: any(named: 'kind'),
        ),
      );
    });

    test('swallows a token-repo delete failure and never throws', () async {
      when(
        () => tokenRepo.deleteTokensOfKind(
          userDocId: any(named: 'userDocId'),
          kind: LiveActivityTokenKind.pushToStart,
        ),
      ).thenThrow(Exception('rules'));
      final controller = controllerOf(makeContainer());

      await expectLater(controller.unregister(), completes);
    });

    test('swallows a users-doc lookup failure and deletes nothing', () async {
      when(() => employees.findUserByUid(any())).thenThrow(Exception('denied'));
      final controller = controllerOf(makeContainer());

      await expectLater(controller.unregister(), completes);
      verifyNever(
        () => tokenRepo.deleteTokensOfKind(
          userDocId: any(named: 'userDocId'),
          kind: any(named: 'kind'),
        ),
      );
    });
  });

  group('on-iOS, before the plugin', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('a stored opt-out deletes the stale push-to-start rows', () async {
      // `:117-125`, and untested until the platform gate became injectable: a
      // stored opt-out is AUTHORITATIVE, so a sync reconciles by actively
      // removing rows an interrupted previous opt-out left behind. Skip it and
      // the server goes on push-starting cards on a device that opted out.
      SharedPreferences.setMockInitialValues({'live_activity_enabled': false});
      final container = makeContainer(onIos: true)
        ..listen(liveActivityEnabledProvider, (_, _) {});
      await container.read(liveActivityEnabledProvider.notifier).ready;

      await controllerOf(container).sync();

      verify(
        () => tokenRepo.deleteTokensOfKind(
          userDocId: 'doc-1',
          kind: LiveActivityTokenKind.pushToStart,
        ),
      ).called(1);
    });

    test(
      'an unsettled account doc registers nothing and deletes nothing',
      () async {
        // Null from `readAccountGateInputs` means "we don't know yet" — leaving
        // the registration alone, NOT tearing it down. A transient stream error
        // must never de-register a live device.
        final container = makeContainer(onIos: true)
          ..listen(liveActivityEnabledProvider, (_, _) {});
        await container.read(liveActivityEnabledProvider.notifier).ready;

        await controllerOf(container).sync();

        verifyNever(
          () => tokenRepo.deleteTokensOfKind(
            userDocId: any(named: 'userDocId'),
            kind: any(named: 'kind'),
          ),
        );
        verifyNever(() => employees.findUserByUid(any()));
      },
    );

    test(
      'a disabled account is refused by the gate, without a teardown',
      () async {
        // The `shouldRegisterLiveActivity` arm: cancel local streams and stop.
        // It must NOT delete server rows — that is the opt-out path's job, and
        // a deactivated account has its rows purged server-side by
        // `syncUsersByUid` instead.
        final container =
            makeContainer(
                onIos: true,
                accountDoc: const {'role': 'employee', 'status': 'disabled'},
              )
              ..listen(liveActivityEnabledProvider, (_, _) {})
              ..listen(currentUserDocProvider, (_, _) {});
        await container.read(liveActivityEnabledProvider.notifier).ready;
        await container.read(currentUserDocProvider.future);

        await controllerOf(container).sync();

        verifyNever(
          () => tokenRepo.deleteTokensOfKind(
            userDocId: any(named: 'userDocId'),
            kind: any(named: 'kind'),
          ),
        );
        verifyNever(() => employees.findUserByUid(any()));
      },
    );
  });

  group('remote pause (feature_live_activities off)', () {
    late _MockPlugin plugin;
    late StreamController<String> pushToStart;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      plugin = _MockPlugin();
      pushToStart = StreamController<String>.broadcast();
      addTearDown(pushToStart.close);
      when(plugin.areActivitiesSupported).thenAnswer((_) async => true);
      when(plugin.areActivitiesEnabled).thenAnswer((_) async => true);
      when(plugin.allowsPushStart).thenAnswer((_) async => true);
      when(
        () => plugin.init(appGroupId: any(named: 'appGroupId')),
      ).thenAnswer((_) async {});
      when(
        () => plugin.pushToStartTokenUpdateStream,
      ).thenAnswer((_) => pushToStart.stream);
      when(
        () => plugin.activityUpdateStream,
      ).thenAnswer((_) => const Stream<ActivityUpdate>.empty());
      when(plugin.endAllActivities).thenAnswer((_) async {});
      when(
        () => tokenRepo.upsertToken(
          userDocId: any(named: 'userDocId'),
          docId: any(named: 'docId'),
          token: any(named: 'token'),
          kind: any(named: 'kind'),
          locale: any(named: 'locale'),
          uid: any(named: 'uid'),
          expiresAt: any(named: 'expiresAt'),
        ),
      ).thenAnswer((_) async {});
    });

    Future<ProviderContainer> registered() async {
      final container = ProviderContainer(
        overrides: [
          employeesRepositoryProvider.overrideWithValue(employees),
          featureFlagsProvider.overrideWith((ref) => ref.watch(_flagsSource)),
          liveActivityTokenRepositoryProvider.overrideWithValue(tokenRepo),
          currentUserDocProvider.overrideWith(
            (ref) => Stream<Map<String, dynamic>>.value(const {
              'role': 'employee',
              'status': 'active',
            }),
          ),
          liveActivityRegistrationControllerProvider.overrideWith(
            (ref) => LiveActivityRegistrationController(
              ref,
              auth: auth,
              plugin: plugin,
              isIosPlatform: () => true,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container
        ..listen(liveActivityEnabledProvider, (_, _) {})
        ..listen(currentUserDocProvider, (_, _) {})
        ..listen(_flagsSource, (_, _) {});
      await container.read(liveActivityEnabledProvider.notifier).ready;
      await container.read(currentUserDocProvider.future);
      await controllerOf(container).sync();
      pushToStart.add('token-a');
      await pumpEventQueue();
      return container;
    }

    void pause(ProviderContainer c, {required bool on}) =>
        c.read(_flagsSource.notifier).liveActivities(on: !on);

    test('keeps the push-to-start rows and token stream', () async {
      final container = await registered();

      pause(container, on: true);
      await controllerOf(container).sync();

      verifyNever(
        () => tokenRepo.deleteTokensOfKind(
          userDocId: any(named: 'userDocId'),
          kind: any(named: 'kind'),
        ),
      );
      expect(pushToStart.hasListener, isTrue);
    });

    test('ends local cards once per pause, not on every sync', () async {
      final container = await registered();

      pause(container, on: true);
      await controllerOf(container).sync();
      await controllerOf(container).sync();
      await controllerOf(container).sync();

      verify(plugin.endAllActivities).called(1);
    });

    test('re-enabling re-arms the guard for the next pause', () async {
      final container = await registered();
      final controller = controllerOf(container);

      pause(container, on: true);
      await controller.sync();
      pause(container, on: false);
      await controller.sync();
      pause(container, on: true);
      await controller.sync();

      verify(plugin.endAllActivities).called(2);
    });

    test('a failed card end is retried on the next paused sync', () async {
      final container = await registered();
      var calls = 0;
      when(plugin.endAllActivities).thenAnswer((_) async {
        if (calls++ == 0) throw Exception('ActivityKit');
      });

      pause(container, on: true);
      await controllerOf(container).sync();
      await controllerOf(container).sync();
      await controllerOf(container).sync();

      expect(calls, 2);
    });

    test('resuming needs no token re-emission to stay registered', () async {
      final container = await registered();
      final controller = controllerOf(container);

      pause(container, on: true);
      await controller.sync();
      pause(container, on: false);
      await controller.sync();

      verify(() => plugin.pushToStartTokenUpdateStream).called(1);
    });
  });

  group('off-iOS gates (this host cannot host a card)', () {
    test(
      'sync() is a no-op — never resolves a doc or upserts a token',
      () async {
        final controller = controllerOf(makeContainer());

        await controller.sync();

        verifyNever(() => employees.findUserByUid(any()));
        verifyNever(
          () => tokenRepo.upsertToken(
            userDocId: any(named: 'userDocId'),
            docId: any(named: 'docId'),
            token: any(named: 'token'),
            kind: any(named: 'kind'),
            locale: any(named: 'locale'),
            uid: any(named: 'uid'),
            expiresAt: any(named: 'expiresAt'),
          ),
        );
      },
    );

    test('canHostCards() returns false without probing the plugin', () async {
      final controller = controllerOf(makeContainer());
      expect(await controller.canHostCards(), isFalse);
    });

    test('endLocalCards() is a no-op and never throws', () async {
      final controller = controllerOf(makeContainer());
      await expectLater(controller.endLocalCards(), completes);
    });
  });
}
