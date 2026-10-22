import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/account_deletion_service.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult extends Mock
    implements HttpsCallableResult<dynamic> {}

class _MockUserCredential extends Mock implements UserCredential {}

class _MockAuthCache extends Mock implements AuthCache {}

class _FakeAuthCredential extends Fake implements AuthCredential {}

class _FakeHttpsCallableOptions extends Fake implements HttpsCallableOptions {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(_FakeAuthCredential());
    registerFallbackValue(_FakeHttpsCallableOptions());
  });

  late _MockFirebaseAuth auth;
  late _MockUser user;
  late _MockFirebaseFunctions functions;
  late _MockHttpsCallable callable;
  late _MockAuthCache authCache;
  late AccountDeletionService service;

  setUp(() {
    auth = _MockFirebaseAuth();
    user = _MockUser();
    functions = _MockFirebaseFunctions();
    callable = _MockHttpsCallable();
    authCache = _MockAuthCache();
    service = AccountDeletionService(
      firebaseAuth: auth,
      functions: functions,
      authCache: authCache,
    );
    when(() => auth.currentUser).thenReturn(user);
    when(() => user.email).thenReturn('owner@example.com');
    when(() => authCache.clear()).thenAnswer((_) async {});
    when(
      () => functions.httpsCallable(
        any(that: equals('deleteAccount')),
        options: any(named: 'options'),
      ),
    ).thenReturn(callable);
  });

  test(
    'an old deletion acknowledgement cannot sign out or clear the new account',
    () async {
      final release = Completer<HttpsCallableResult<dynamic>>();
      when(() => user.uid).thenReturn('A');
      final session = SessionFence(readUid: () => auth.currentUser?.uid);
      when(() => callable.call<dynamic>()).thenAnswer((_) => release.future);
      final guarded = AccountDeletionService(
        firebaseAuth: auth,
        functions: functions,
        authCache: authCache,
        sessionForExit: () => session,
      );
      final pending = guarded.deleteAccount();
      final next = _MockUser();
      when(() => next.uid).thenReturn('B');
      when(() => auth.currentUser).thenReturn(next);
      release.complete(_MockHttpsCallableResult());
      await pending;
      verifyNever(auth.signOut);
      verifyNever(authCache.clear);
    },
  );

  group('reauthenticateWithPassword', () {
    test('normalizes email before reauth', () async {
      when(() => user.email).thenReturn('  OWNER@EXAMPLE.COM  ');
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenAnswer((_) async => _MockUserCredential());

      await service.reauthenticateWithPassword(' pw ');

      final captured =
          verify(
                () => user.reauthenticateWithCredential(captureAny()),
              ).captured.single
              as EmailAuthCredential;
      expect(captured.email, 'owner@example.com');
      expect(captured.password, 'pw');
    });

    test(
      'throws AuthFailureRequiresRecentLogin when no current user',
      () async {
        when(() => auth.currentUser).thenReturn(null);

        await expectLater(
          service.reauthenticateWithPassword('pw'),
          throwsA(isA<AuthFailureRequiresRecentLogin>()),
        );
      },
    );

    test('maps FirebaseAuthException via AuthErrorMapper', () async {
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenThrow(FirebaseAuthException(code: 'wrong-password'));

      await expectLater(
        service.reauthenticateWithPassword('pw'),
        throwsA(isA<AuthFailureWrongCredentials>()),
      );
    });
  });

  group('deleteAccount', () {
    test('signs out after the callable succeeds', () async {
      when(
        () => callable.call<dynamic>(),
      ).thenAnswer((_) async => _MockHttpsCallableResult());
      when(() => auth.signOut()).thenAnswer((_) async {});

      await service.deleteAccount();

      verify(() => callable.call<dynamic>()).called(1);
      verify(() => auth.signOut()).called(1);
      verify(() => authCache.clear()).called(1);
    });

    test('swallows a local sign-out failure after server deletion', () async {
      when(
        () => callable.call<dynamic>(),
      ).thenAnswer((_) async => _MockHttpsCallableResult());
      when(() => auth.signOut()).thenThrow(Exception('ios signOut failed'));

      await service.deleteAccount();

      verify(() => auth.signOut()).called(1);
      verify(() => authCache.clear()).called(1);
    });

    test(
      'maps unauthenticated callable error to requires-recent-login',
      () async {
        when(() => callable.call<dynamic>()).thenThrow(
          FirebaseFunctionsException(
            message: 'no-auth',
            code: 'unauthenticated',
          ),
        );

        await expectLater(
          service.deleteAccount(),
          throwsA(isA<AuthFailureRequiresRecentLogin>()),
        );
        verifyNever(() => auth.signOut());
      },
    );

    test('maps other callable errors to AuthFailureUnknown', () async {
      when(() => callable.call<dynamic>()).thenThrow(
        FirebaseFunctionsException(message: 'boom', code: 'internal'),
      );

      await expectLater(
        service.deleteAccount(),
        throwsA(isA<AuthFailureUnknown>()),
      );
      verifyNever(() => auth.signOut());
    });

    test('maps callable throttling to too-many-requests', () async {
      when(() => callable.call<dynamic>()).thenThrow(
        FirebaseFunctionsException(
          message: 'quota',
          code: 'resource-exhausted',
        ),
      );

      await expectLater(
        service.deleteAccount(),
        throwsA(isA<AuthFailureTooManyRequests>()),
      );
      verifyNever(() => auth.signOut());
    });

    test('maps callable transport failure to network', () async {
      when(() => callable.call<dynamic>()).thenThrow(
        FirebaseFunctionsException(message: 'offline', code: 'unavailable'),
      );

      await expectLater(
        service.deleteAccount(),
        throwsA(isA<AuthFailureNetwork>()),
      );
      verifyNever(() => auth.signOut());
    });
  });
}
