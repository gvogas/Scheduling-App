// Firestore sealed types need boundary mocks without a live Firebase app.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_async/fake_async.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/core/notifications/push_notification_service.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/notifications/data/fcm_token_repository.dart';

class _MockAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockPushService extends Mock implements PushNotificationService {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockFcmRepo extends Mock implements FcmTokenRepository {}

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockDoc extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

class _MockSnapshot extends Mock
    implements DocumentSnapshot<Map<String, dynamic>> {}

void main() {
  late _MockAuth auth;
  late _MockUser user;
  late _MockPushService service;
  late _MockEmployeesRepo employees;
  late _MockFcmRepo fcm;

  setUp(() {
    auth = _MockAuth();
    user = _MockUser();
    service = _MockPushService();
    employees = _MockEmployeesRepo();
    fcm = _MockFcmRepo();

    when(() => user.uid).thenReturn('uid-1');
    when(() => auth.currentUser).thenReturn(user);
    when(
      () => service.authorizationStatus(),
    ).thenAnswer((_) async => AuthorizationStatus.authorized);
    when(() => service.requestPermission()).thenAnswer((_) async => true);
    when(
      () => service.configureForegroundPresentation(),
    ).thenAnswer((_) async {});
    when(() => service.currentToken()).thenAnswer((_) async => 'tok-1');
    when(() => service.onTokenRefresh).thenAnswer((_) => const Stream.empty());
    when(
      () => employees.findUserByUid(any()),
    ).thenAnswer((_) async => const UserUidMatch(id: 'doc-1', data: {}));
    when(
      () => fcm.upsertToken(
        userDocId: any(named: 'userDocId'),
        token: any(named: 'token'),
        platform: any(named: 'platform'),
        locale: any(named: 'locale'),
        uid: any(named: 'uid'),
      ),
    ).thenAnswer((_) async {});
  });

  ProviderContainer makeContainer(
    Map<String, dynamic> userDoc, {
    FcmTokenRepository? repository,
  }) {
    return ProviderContainer(
      overrides: [
        sessionFenceProvider.overrideWithValue(
          SessionFence(readUid: () => auth.currentUser?.uid),
        ),
        currentUserDocProvider.overrideWith((ref) => Stream.value(userDoc)),
        pushNotificationServiceProvider.overrideWithValue(service),
        employeesRepositoryProvider.overrideWithValue(employees),
        fcmTokenRepositoryProvider.overrideWithValue(repository ?? fcm),
        pushRegistrationControllerProvider.overrideWith((ref) {
          final controller = PushRegistrationController(ref, auth: auth);
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
  }

  // Keeps the overridden stream provider alive and flushes its first emission
  // into `.value` (the shape `sync()` reads).
  Future<void> settleDoc(ProviderContainer container) async {
    final sub = container.listen(currentUserDocProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
  }

  test('signed-out user is a no-op — never touches the push service', () async {
    when(() => auth.currentUser).thenReturn(null);
    final container = makeContainer(const {});
    addTearDown(container.dispose);
    await settleDoc(container);

    await container.read(pushRegistrationControllerProvider).sync();

    verifyNever(() => service.authorizationStatus());
    verifyNever(() => service.requestPermission());
    verifyNever(() => employees.findUserByUid(any()));
  });

  test(
    'a throwing account gate is contained, not escaped as a fatal',
    () async {
      // Shipped as a FATAL on 2026-08-31 and fixed by opening the try ABOVE the
      // gate read.
      when(() => auth.currentUser).thenThrow(StateError('auth blew up'));
      final container = makeContainer(const {
        'role': 'employee',
        'status': 'active',
      });
      addTearDown(container.dispose);
      await settleDoc(container);

      await expectLater(
        container.read(pushRegistrationControllerProvider).sync(),
        completes,
      );
      verifyNever(() => service.authorizationStatus());
      verifyNever(() => service.requestPermission());
    },
  );

  test('inactive employee does not register', () async {
    final container = makeContainer(const {
      'role': 'employee',
      'status': 'invited',
    });
    addTearDown(container.dispose);
    await settleDoc(container);

    await container.read(pushRegistrationControllerProvider).sync();

    verifyNever(() => service.authorizationStatus());
    verifyNever(() => service.requestPermission());
    verifyNever(() => employees.findUserByUid(any()));
  });

  test('a loading account doc does not register yet', () async {
    final docs = StreamController<Map<String, dynamic>>();
    final container = ProviderContainer(
      overrides: [
        sessionFenceProvider.overrideWithValue(
          SessionFence(readUid: () => auth.currentUser?.uid),
        ),
        currentUserDocProvider.overrideWith((ref) => docs.stream),
        pushNotificationServiceProvider.overrideWithValue(service),
        employeesRepositoryProvider.overrideWithValue(employees),
        fcmTokenRepositoryProvider.overrideWithValue(fcm),
        pushRegistrationControllerProvider.overrideWith((ref) {
          final controller = PushRegistrationController(ref, auth: auth);
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    addTearDown(docs.close);
    addTearDown(container.dispose);

    await container.read(pushRegistrationControllerProvider).sync();

    verifyNever(() => service.authorizationStatus());
    verifyNever(() => service.requestPermission());
    verifyNever(() => employees.findUserByUid(any()));
  });

  test('active employee registers once; second sync fast-paths', () async {
    final container = makeContainer(const {
      'role': 'employee',
      'status': 'active',
    });
    addTearDown(container.dispose);
    await settleDoc(container);

    final controller = container.read(pushRegistrationControllerProvider);
    await controller.sync();
    // Same uid + locale + live refresh subscription → the second sync must skip
    // the findUserByUid query and the token upsert entirely.
    await controller.sync();

    verify(() => employees.findUserByUid('uid-1')).called(1);
    verify(
      () => fcm.upsertToken(
        userDocId: 'doc-1',
        token: 'tok-1',
        platform: any(named: 'platform'),
        locale: 'en',
        uid: 'uid-1',
      ),
    ).called(1);
  });

  test(
    'a real repository failure leaves an identical token retryable',
    () async {
      registerFallbackValue(SetOptions(merge: true));
      registerFallbackValue(<String, dynamic>{});
      final firestore = _MockFirestore();
      final users = _MockCollection();
      final userDoc = _MockDoc();
      final tokens = _MockCollection();
      final tokenDoc = _MockDoc();
      final snapshot = _MockSnapshot();
      when(() => firestore.collection('users')).thenReturn(users);
      when(() => users.doc('doc-1')).thenReturn(userDoc);
      when(() => userDoc.collection('fcmTokens')).thenReturn(tokens);
      when(() => tokens.doc('tok-1')).thenReturn(tokenDoc);
      when(tokenDoc.get).thenAnswer((_) async => snapshot);
      when(() => snapshot.exists).thenReturn(false);
      var writes = 0;
      when(() => tokenDoc.set(any(), any())).thenAnswer((_) async {
        if (++writes == 1) throw Exception('network');
      });
      final container = makeContainer(const {
        'role': 'employee',
        'status': 'active',
      }, repository: FcmTokenRepository(firestore: firestore));
      addTearDown(container.dispose);
      await settleDoc(container);
      final controller = container.read(pushRegistrationControllerProvider);
      await controller.sync();
      await controller.sync();
      await controller.sync();
      expect(writes, 2);
      verifyNever(() => service.requestPermission());
    },
  );

  testWidgets(
    'a transient registration retries after five seconds without prompting',
    (tester) async {
      var writes = 0;
      when(
        () => fcm.upsertToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
          platform: any(named: 'platform'),
          locale: any(named: 'locale'),
          uid: any(named: 'uid'),
        ),
      ).thenAnswer((_) async {
        if (++writes == 1) throw Exception('network');
      });
      final container = makeContainer(const {
        'role': 'employee',
        'status': 'active',
      });
      await tester.pump();
      container.listen(currentUserDocProvider, (_, _) {});
      await tester.pump();
      final controller = container.read(pushRegistrationControllerProvider);
      await controller.sync();
      expect(writes, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(writes, 2);
      verifyNever(() => service.requestPermission());
      container.dispose();
    },
  );

  group('retry backoff', () {
    const active = {'role': 'employee', 'status': 'active'};

    // A null native token re-schedules on every attempt: 5, 10, 20, 40, 60 s.
    int Function() countTokenReads() {
      var reads = 0;
      when(() => service.currentToken()).thenAnswer((_) async {
        reads++;
        return null;
      });
      return () => reads;
    }

    test('stops after five retries', () {
      fakeAsync((async) {
        final reads = countTokenReads();
        final container = makeContainer(active);
        final docSub = container.listen(currentUserDocProvider, (_, _) {});
        async.flushMicrotasks();
        unawaited(container.read(pushRegistrationControllerProvider).sync());
        async.elapse(const Duration(minutes: 10));
        expect(reads(), 6);
        docSub.close();
        container.dispose();
      });
    });

    test('retryRegistration restarts an exhausted backoff at five seconds', () {
      fakeAsync((async) {
        final reads = countTokenReads();
        final container = makeContainer(active);
        final docSub = container.listen(currentUserDocProvider, (_, _) {});
        async.flushMicrotasks();
        final controller = container.read(pushRegistrationControllerProvider);
        unawaited(controller.sync());
        async.elapse(const Duration(minutes: 10));
        unawaited(controller.retryRegistration());
        async.elapse(const Duration(seconds: 5));
        expect(reads(), 8);
        docSub.close();
        container.dispose();
      });
    });
  });

  test(
    'a failed native rotation blocks registration until a retry rotates',
    () {
      fakeAsync((async) {
        var deletes = 0;
        when(() => service.deleteToken()).thenAnswer((_) async {
          if (++deletes <= 2) throw Exception('apns');
        });
        when(
          () => fcm.deleteToken(
            userDocId: any(named: 'userDocId'),
            token: any(named: 'token'),
          ),
        ).thenAnswer((_) async {});
        final container = makeContainer(const {
          'role': 'employee',
          'status': 'active',
        });
        final docSub = container.listen(currentUserDocProvider, (_, _) {});
        async.flushMicrotasks();
        final controller = container.read(pushRegistrationControllerProvider);
        unawaited(controller.sync());
        async.flushMicrotasks();
        unawaited(controller.unregisterCurrentDevice());
        async.flushMicrotasks();
        final nextUser = _MockUser();
        when(() => nextUser.uid).thenReturn('uid-2');
        when(() => auth.currentUser).thenReturn(nextUser);
        when(
          () => employees.findUserByUid('uid-2'),
        ).thenAnswer((_) async => const UserUidMatch(id: 'doc-2', data: {}));
        when(() => service.currentToken()).thenAnswer((_) async => 'tok-2');
        final upserts = <String>[];
        when(
          () => fcm.upsertToken(
            userDocId: any(named: 'userDocId'),
            token: any(named: 'token'),
            platform: any(named: 'platform'),
            locale: any(named: 'locale'),
            uid: any(named: 'uid'),
          ),
        ).thenAnswer(
          (call) async => upserts.add(call.namedArguments[#token] as String),
        );
        unawaited(controller.sync());
        async.flushMicrotasks();
        expect(upserts, isEmpty, reason: 'a failed rotation only re-rotates');
        async.elapse(const Duration(seconds: 5));
        expect(upserts, ['tok-2']);
        docSub.close();
        container.dispose();
      });
    },
  );

  test(
    'a token refresh landing mid-upsert keeps the refreshed token registered',
    () async {
      when(
        () => fcm.deleteToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
        ),
      ).thenAnswer((_) async {});
      when(() => service.deleteToken()).thenAnswer((_) async {});
      final refresh = StreamController<String>.broadcast(sync: true);
      addTearDown(refresh.close);
      when(() => service.onTokenRefresh).thenAnswer((_) => refresh.stream);
      final staleWrite = Completer<void>();
      final staleWriteStarted = Completer<void>();
      when(
        () => fcm.upsertToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
          platform: any(named: 'platform'),
          locale: any(named: 'locale'),
          uid: any(named: 'uid'),
        ),
      ).thenAnswer((call) {
        switch (call.namedArguments[#token]) {
          // Fails, so the next sync misses the fast path.
          case 'tok-2':
            return Future.error(Exception('network'));
          case 'tok-stale':
            staleWriteStarted.complete();
            return staleWrite.future;
          default:
            return Future.value();
        }
      });
      final container = makeContainer(const {
        'role': 'employee',
        'status': 'active',
      });
      addTearDown(container.dispose);
      await settleDoc(container);
      final controller = container.read(pushRegistrationControllerProvider);
      await controller.sync();
      refresh.add('tok-2');
      await pumpEventQueue();
      when(() => service.currentToken()).thenAnswer((_) async => 'tok-stale');
      final pending = controller.sync();
      await staleWriteStarted.future;
      refresh.add('tok-3');
      await pumpEventQueue();
      staleWrite.complete();
      await pending;

      await controller.unregisterCurrentDevice();

      verify(
        () => fcm.deleteToken(userDocId: 'doc-1', token: 'tok-3'),
      ).called(1);
    },
  );

  group('unregisterCurrentDevice', () {
    setUp(() {
      when(
        () => fcm.deleteToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
        ),
      ).thenAnswer((_) async {});
      when(() => service.deleteToken()).thenAnswer((_) async {});
    });

    test(
      'replacement registration waits for the old native token rotation',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        when(service.deleteToken).thenAnswer((_) {
          started.complete();
          return release.future;
        });
        final container = makeContainer(const {
          'role': 'employee',
          'status': 'active',
        });
        addTearDown(container.dispose);
        await settleDoc(container);
        final controller = container.read(pushRegistrationControllerProvider);
        await controller.sync();
        final exit = controller.unregisterCurrentDevice();
        await started.future;
        final nextUser = _MockUser();
        when(() => nextUser.uid).thenReturn('uid-2');
        when(() => auth.currentUser).thenReturn(nextUser);
        when(
          () => employees.findUserByUid('uid-2'),
        ).thenAnswer((_) async => const UserUidMatch(id: 'doc-2', data: {}));
        when(service.currentToken).thenAnswer((_) async => 'tok-2');
        await controller.sync();
        verifyNever(() => employees.findUserByUid('uid-2'));
        release.complete();
        await exit;
        await pumpEventQueue();
        verify(
          () => fcm.upsertToken(
            userDocId: 'doc-2',
            token: 'tok-2',
            platform: any(named: 'platform'),
            locale: 'en',
            uid: 'uid-2',
          ),
        ).called(1);
        verify(service.deleteToken).called(1);
      },
    );

    test(
      'a registration acknowledgement after teardown cannot reinstall refresh',
      () async {
        final writeStarted = Completer<void>();
        final releaseWrite = Completer<void>();
        final refresh = StreamController<String>.broadcast(sync: true);
        addTearDown(refresh.close);
        when(() => service.onTokenRefresh).thenAnswer((_) => refresh.stream);
        when(
          () => fcm.upsertToken(
            userDocId: any(named: 'userDocId'),
            token: any(named: 'token'),
            platform: any(named: 'platform'),
            locale: any(named: 'locale'),
            uid: any(named: 'uid'),
          ),
        ).thenAnswer((_) {
          writeStarted.complete();
          return releaseWrite.future;
        });
        final container = makeContainer(const {
          'role': 'employee',
          'status': 'active',
        });
        addTearDown(container.dispose);
        await settleDoc(container);
        final controller = container.read(pushRegistrationControllerProvider);
        final pending = controller.sync();
        await writeStarted.future;
        await controller.unregisterCurrentDevice();
        releaseWrite.complete();
        await pending;
        expect(refresh.hasListener, isFalse);
      },
    );

    test('refresh is fenced while remote token removal is stalled', () async {
      final deleteStarted = Completer<void>();
      final releaseDelete = Completer<void>();
      final refresh = StreamController<String>.broadcast(sync: true);
      addTearDown(refresh.close);
      when(() => service.onTokenRefresh).thenAnswer((_) => refresh.stream);
      final writes = <String>[];
      when(
        () => fcm.upsertToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
          platform: any(named: 'platform'),
          locale: any(named: 'locale'),
          uid: any(named: 'uid'),
        ),
      ).thenAnswer(
        (call) async => writes.add(call.namedArguments[#token] as String),
      );
      when(
        () => fcm.deleteToken(userDocId: 'doc-1', token: 'tok-1'),
      ).thenAnswer((_) {
        deleteStarted.complete();
        return releaseDelete.future;
      });
      final container = makeContainer(const {
        'role': 'employee',
        'status': 'active',
      });
      addTearDown(container.dispose);
      await settleDoc(container);
      final controller = container.read(pushRegistrationControllerProvider);
      await controller.sync();
      final pending = controller.unregisterCurrentDevice();
      await deleteStarted.future;
      refresh.add('tok-late');
      await pumpEventQueue();
      releaseDelete.complete();
      await pending;
      expect(writes, ['tok-1']);
    });

    test(
      'old teardown cannot delete or detach the new user registration',
      () async {
        final deleteStarted = Completer<void>();
        final releaseDelete = Completer<void>();
        final refresh = StreamController<String>.broadcast(sync: true);
        addTearDown(refresh.close);
        when(() => service.onTokenRefresh).thenAnswer((_) => refresh.stream);
        when(
          () => fcm.deleteToken(userDocId: 'doc-1', token: 'tok-1'),
        ).thenAnswer((_) {
          deleteStarted.complete();
          return releaseDelete.future;
        });
        final container = makeContainer(const {
          'role': 'employee',
          'status': 'active',
        });
        addTearDown(container.dispose);
        await settleDoc(container);
        final controller = container.read(pushRegistrationControllerProvider);
        await controller.sync();
        final pending = controller.unregisterCurrentDevice();
        await deleteStarted.future;
        final nextUser = _MockUser();
        when(() => nextUser.uid).thenReturn('uid-2');
        when(() => auth.currentUser).thenReturn(nextUser);
        when(
          () => employees.findUserByUid('uid-2'),
        ).thenAnswer((_) async => const UserUidMatch(id: 'doc-2', data: {}));
        when(() => service.currentToken()).thenAnswer((_) async => 'tok-2');
        await controller.sync();
        releaseDelete.complete();
        await pending;
        verify(() => service.deleteToken()).called(1);
        expect(refresh.hasListener, isTrue);
        clearInteractions(employees);
        await controller.sync();
        verifyNever(() => employees.findUserByUid(any()));
        controller.dispose();
      },
    );

    test(
      'a session that never registered still deletes the stale row',
      () async {
        // `_registeredDocId`/`_registeredToken` are set only on a
        // fully-successful sync, so an incomplete session left one `fcmTokens`
        // row per device that the server keeps pushing to - `syncUsersByUid`
        // purges those on DISABLE, not on sign-out, so they just accumulate.
        when(
          () => service.authorizationStatus(),
        ).thenAnswer((_) async => AuthorizationStatus.denied);
        final container = makeContainer(const {
          'role': 'employee',
          'status': 'active',
        });
        addTearDown(container.dispose);
        await settleDoc(container);
        final controller = container.read(pushRegistrationControllerProvider);
        await controller.sync();

        await controller.unregisterCurrentDevice();

        verifyNever(() => service.requestPermission());
        verify(
          () => fcm.deleteToken(userDocId: 'doc-1', token: 'tok-1'),
        ).called(1);
        verify(() => service.deleteToken()).called(1);
      },
    );

    test('deletes nothing when the device has no token at all', () async {
      when(() => service.currentToken()).thenAnswer((_) async => null);
      when(() => auth.currentUser).thenReturn(null);
      final container = makeContainer(const {});
      addTearDown(container.dispose);
      await settleDoc(container);

      await container
          .read(pushRegistrationControllerProvider)
          .unregisterCurrentDevice();

      verifyNever(
        () => fcm.deleteToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
        ),
      );
    });

    test('a sync resuming mid-teardown does not re-register the device', () async {
      // Teardown runs BEFORE signOut(), so the resumed body still holds a valid
      // credential: FCM would mint a fresh token (the old one just invalidated)
      // and this would upsert it, leaving a signed-out device registered and
      // still receiving that account's pushes - and the write SUCCEEDS, so
      // nothing logs an error.
      final release = Completer<UserUidMatch?>();
      var call = 0;
      when(() => employees.findUserByUid(any())).thenAnswer((_) {
        call++;
        return call == 1
            ? release.future
            : Future<UserUidMatch?>.value(
                const UserUidMatch(id: 'doc-1', data: {}),
              );
      });

      final container = makeContainer(const {
        'role': 'employee',
        'status': 'active',
      });
      addTearDown(container.dispose);
      await settleDoc(container);
      final controller = container.read(pushRegistrationControllerProvider);

      final inFlight = controller.sync();
      await pumpEventQueue();

      await controller.unregisterCurrentDevice();
      release.complete(const UserUidMatch(id: 'doc-1', data: {}));
      await inFlight;
      await pumpEventQueue();

      verifyNever(
        () => fcm.upsertToken(
          userDocId: any(named: 'userDocId'),
          token: any(named: 'token'),
          platform: any(named: 'platform'),
          locale: any(named: 'locale'),
          uid: any(named: 'uid'),
        ),
      );
    });
  });
}
