import 'package:fake_async/fake_async.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/storage/secure_storage_service.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/auth/application/sign_in_controller.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

class _MockAuthService extends Mock implements AuthService {}

class _MockEmployeesRepo extends Mock implements EmployeesRepository {}

class _MockAuthCache extends Mock implements AuthCache {}

class _MockSecureStorage extends Mock implements SecureStorageService {}

class _MockUserCredential extends Mock implements UserCredential {}

class _MockUser extends Mock implements User {}

const _activeDoc = UserUidMatch(
  id: 'doc1',
  data: <String, dynamic>{
    'name': 'Active User',
    'email': 'user@test.com',
    'status': 'active',
    'role': 'admin',
    'uid': 'u1',
  },
);

const _disabledDoc = UserUidMatch(
  id: 'doc1',
  data: <String, dynamic>{
    'name': 'Disabled User',
    'email': 'user@test.com',
    'status': 'disabled',
    'role': 'employee',
    'uid': 'u1',
  },
);

const _invitedDoc = UserUidMatch(
  id: 'doc1',
  data: <String, dynamic>{
    'name': 'Invited User',
    'firstName': 'Invited',
    'lastName': 'User',
    'email': 'user@test.com',
    'status': 'invited',
    'role': 'employee',
    'uid': 'u1',
  },
);

/// A status the app has never written. It must NOT take the invited branch —
/// the carve-out is an exact match, so anything unknown still signs out.
const _unknownStatusDoc = UserUidMatch(
  id: 'doc1',
  data: <String, dynamic>{
    'name': 'Odd User',
    'email': 'user@test.com',
    'status': '',
    'role': 'employee',
    'uid': 'u1',
  },
);

const _flaggedDoc = UserUidMatch(
  id: 'doc1',
  data: <String, dynamic>{
    'name': 'Reset User',
    'email': 'user@test.com',
    'status': 'active',
    'role': 'employee',
    'uid': 'u1',
    'passwordResetRequired': true,
  },
);

void main() {
  setUpAll(() {
    registerFallbackValue(const EmployeeRecord(id: '_', name: '_'));
  });

  late _MockAuthService auth;
  late _MockEmployeesRepo repo;
  late _MockAuthCache cache;
  late _MockSecureStorage storage;
  late ProviderContainer container;

  setUp(() {
    auth = _MockAuthService();
    repo = _MockEmployeesRepo();
    cache = _MockAuthCache();
    storage = _MockSecureStorage();

    when(() => cache.save(any())).thenAnswer((_) async {});
    when(() => cache.clear()).thenAnswer((_) async {});
    when(() => storage.write(any(), any())).thenAnswer((_) async {});
    when(() => auth.signOut()).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(auth),
        employeesRepositoryProvider.overrideWithValue(repo),
        authCacheProvider.overrideWithValue(cache),
        secureStorageServiceProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(container.dispose);
  });

  SignInController notifier() =>
      container.read(signInControllerProvider.notifier);

  SignInState state() => container.read(signInControllerProvider);

  void stubSignedIn({String uid = 'u1'}) {
    final credential = _MockUserCredential();
    final user = _MockUser();
    when(() => user.uid).thenReturn(uid);
    when(() => credential.user).thenReturn(user);
    when(
      () => auth.signIn(
        email: any(named: 'email'),
        password: any(named: 'password'),
      ),
    ).thenAnswer((_) async => credential);
  }

  group('signIn', () {
    test(
      'routes a reset account to Change password and KEEPS the session',
      () async {
        stubSignedIn();
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _flaggedDoc);

        final outcome = await notifier().signIn(
          email: 'user@test.com',
          password: 'Tmp2pass!wd9',
        );

        expect(outcome, isA<SignInNeedsPasswordChange>());
        verifyNever(() => auth.signOut());
        expect(state().inProgress, isFalse);
      },
    );

    test(
      'clears the identity cache so a cold start cannot skip the change',
      () async {
        stubSignedIn();
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _flaggedDoc);

        await notifier().signIn(
          email: 'user@test.com',
          password: 'Tmp2pass!wd9',
        );

        verify(() => cache.clear()).called(1);
        verifyNever(() => cache.save(any()));
      },
    );

    test('a failing cache clear still routes to Change password', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _flaggedDoc);
      when(
        () => cache.clear(),
      ).thenAnswer((_) async => throw Exception('keystore'));

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'Tmp2pass!wd9',
      );

      expect(outcome, isA<SignInNeedsPasswordChange>());
    });

    test('an invited doc carrying the flag still goes to setup', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer(
        (_) async => UserUidMatch(
          id: 'doc1',
          data: {..._invitedDoc.data, 'passwordResetRequired': true},
        ),
      );

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInNeedsAccountSetup>());
    });

    test('returns success with the resolved employee and caches it', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _activeDoc);

      final outcome = await notifier().signIn(
        email: ' User@Test.com ',
        password: 'password123',
      );

      expect(outcome, isA<SignInSuccess>());
      final employee = (outcome as SignInSuccess).employee;
      expect(employee.id, 'doc1');
      expect(employee.name, 'Active User');
      expect(employee.isAdmin, isTrue);
      verify(() => cache.save(any())).called(1);
      verify(
        () => storage.write(SecureStorageKeys.rememberedEmail, 'user@test.com'),
      ).called(1);
      // Stays busy on success, since the screen keeps its spinner while routing.
      expect(state().inProgress, isTrue);
    });

    test('retries the profile read once on auth-propagation '
        'permission-denied', () async {
      stubSignedIn();
      var reads = 0;
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async {
        reads++;
        if (reads == 1) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
          );
        }
        return _activeDoc;
      });

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInSuccess>());
      expect(reads, 2);
    });

    test('signs out and reports no-profile when the users doc is '
        'missing', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => null);

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInNoProfile>());
      verify(() => auth.signOut()).called(1);
      verifyNever(() => cache.save(any()));
      expect(state().inProgress, isFalse);
    });

    test(
      'a failing signOut still reports no-profile instead of turning into a generic error',
      () async {
        stubSignedIn();
        when(() => repo.findUserByUid('u1')).thenAnswer((_) async => null);
        when(() => auth.signOut()).thenThrow(Exception('ios signOut failed'));

        final outcome = await notifier().signIn(
          email: 'user@test.com',
          password: 'password123',
        );

        expect(outcome, isA<SignInNoProfile>());
        expect(state().inProgress, isFalse);
      },
    );

    test('signs out and reports disabled for an inactive account', () async {
      stubSignedIn();
      when(
        () => repo.findUserByUid('u1'),
      ).thenAnswer((_) async => _disabledDoc);

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInAccountDisabled>());
      verify(() => auth.signOut()).called(1);
      verifyNever(() => cache.save(any()));
      expect(state().inProgress, isFalse);
    });

    test(
      'a failing signOut still reports disabled for an inactive account',
      () async {
        stubSignedIn();
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _disabledDoc);
        when(() => auth.signOut()).thenThrow(Exception('ios signOut failed'));

        final outcome = await notifier().signIn(
          email: 'user@test.com',
          password: 'password123',
        );

        expect(outcome, isA<SignInAccountDisabled>());
        expect(state().inProgress, isFalse);
      },
    );

    test('routes an invited account to setup and KEEPS the session', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _invitedDoc);

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInNeedsAccountSetup>());
      // The credential they just used is the one setup needs — signing them
      // out here makes the setup screen permanently unreachable.
      verifyNever(() => auth.signOut());
      expect(state().inProgress, isFalse);
    });

    test('carries the stored name halves into the setup outcome', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _invitedDoc);

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(
        outcome,
        isA<SignInNeedsAccountSetup>()
            .having((o) => o.firstName, 'firstName', 'Invited')
            .having((o) => o.lastName, 'lastName', 'User'),
      );
    });

    test(
      'signs out for an unknown status — the invited test is exact',
      () async {
        stubSignedIn();
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _unknownStatusDoc);

        final outcome = await notifier().signIn(
          email: 'user@test.com',
          password: 'password123',
        );

        expect(outcome, isA<SignInAccountDisabled>());
        verify(() => auth.signOut()).called(1);
      },
    );

    test('reports invalid credentials when auth returns no user', () async {
      final credential = _MockUserCredential();
      when(() => credential.user).thenReturn(null);
      when(
        () => auth.signIn(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer((_) async => credential);

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      expect(outcome, isA<SignInInvalidCredentials>());
      expect(state().inProgress, isFalse);
    });

    test('tolerates a failing identity-cache save', () async {
      stubSignedIn();
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async => _activeDoc);
      when(
        () => cache.save(any()),
      ).thenAnswer((_) async => throw Exception('keystore flake'));
      when(
        () => storage.write(any(), any()),
      ).thenAnswer((_) async => throw Exception('keystore flake'));

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'password123',
      );

      // The unawaited best-effort writes must not turn a completed sign-in
      // into an error outcome (nor leak an unhandled async error).
      expect(outcome, isA<SignInSuccess>());
      await Future<void>.delayed(Duration.zero);
    });

    test('maps thrown auth errors to a localizable failure', () async {
      when(
        () => auth.signIn(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenThrow(FirebaseAuthException(code: 'wrong-password'));

      final outcome = await notifier().signIn(
        email: 'user@test.com',
        password: 'nope',
      );

      expect(outcome, isA<SignInError>());
      expect(
        (outcome as SignInError).failure,
        isA<AuthFailureWrongCredentials>(),
      );
      expect(state().inProgress, isFalse);
    });
  });

  group('resumeAfterSignUp', () {
    void stubResumeUser() {
      final user = _MockUser();
      when(() => user.uid).thenReturn('u1');
      when(() => auth.currentUser).thenReturn(user);
    }

    /// Runs the resume under a fake clock, walking the whole shared ladder.
    SignInOutcome resumeThroughLadder(FakeAsync async) {
      SignInOutcome? outcome;
      notifier().resumeAfterSignUp().then((o) => outcome = o);
      async.flushMicrotasks();
      for (final delay in kAuthPropagationDelays) {
        expect(outcome, isNull, reason: 'must not give up mid-ladder');
        async.elapse(delay);
      }
      async.flushMicrotasks();
      return outcome!;
    }

    test(
      'a still-flagged doc reports a pending profile, never success',
      () => fakeAsync((async) {
        stubResumeUser();
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _flaggedDoc);

        expect(resumeThroughLadder(async), isA<SignInProfilePending>());
        verifyNever(() => cache.save(any()));
      }),
    );

    test('reports no session when nobody is signed in', () async {
      when(() => auth.currentUser).thenReturn(null);

      expect(await notifier().resumeAfterSignUp(), isA<SignInNoSession>());
    });

    test(
      'a missing doc walks the SHARED ladder before reporting pending (U10)',
      () => fakeAsync((async) {
        // The activation just landed, so the read can lag the write for a few
        // seconds; giving up on the first null read signed people out to Login
        // with no explanation. Same `kAuthPropagationDelays` as the
        // permission-denied race — no local delay list (ADR-0035).
        stubResumeUser();
        var reads = 0;
        when(() => repo.findUserByUid('u1')).thenAnswer((_) async {
          reads++;
          return null;
        });

        expect(resumeThroughLadder(async), isA<SignInProfilePending>());
        expect(reads, kAuthPropagationDelays.length + 1);
        expect(async.elapsed, const Duration(milliseconds: 4100));
      }),
    );

    test('a doc that turns active mid-ladder resolves to success', () async {
      stubResumeUser();
      var reads = 0;
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async {
        reads++;
        return reads == 1 ? _invitedDoc : _activeDoc;
      });

      final outcome = await notifier().resumeAfterSignUp();

      expect(outcome, isA<SignInSuccess>());
      expect(reads, 2);
      verify(() => cache.save(any())).called(1);
    });

    test('resolves the signed-in employee, retrying on '
        'permission-denied', () async {
      final user = _MockUser();
      when(() => user.uid).thenReturn('u1');
      when(() => auth.currentUser).thenReturn(user);
      var reads = 0;
      when(() => repo.findUserByUid('u1')).thenAnswer((_) async {
        reads++;
        if (reads == 1) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
          );
        }
        return _activeDoc;
      });

      final outcome = await notifier().resumeAfterSignUp();

      expect(outcome, isA<SignInSuccess>());
      expect((outcome as SignInSuccess).employee.id, 'doc1');
      expect(reads, 2);
      verify(() => cache.save(any())).called(1);
    });

    test(
      'a still-invited doc reports a pending profile, never success',
      () => fakeAsync((async) {
        // Mirrors signIn's gate. A stale read (offline persistence, or the
        // permission-denied retry served from cache) would otherwise walk an
        // invited person into the hub, where every rules gate denies them.
        stubResumeUser();
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _invitedDoc);

        expect(resumeThroughLadder(async), isA<SignInProfilePending>());
        verifyNever(() => cache.save(any()));
      }),
    );

    test(
      'tolerates a failing identity-cache save after setup resume',
      () async {
        final user = _MockUser();
        when(() => user.uid).thenReturn('u1');
        when(() => auth.currentUser).thenReturn(user);
        when(
          () => repo.findUserByUid('u1'),
        ).thenAnswer((_) async => _activeDoc);
        when(
          () => cache.save(any()),
        ).thenAnswer((_) async => throw Exception('keystore flake'));

        final outcome = await notifier().resumeAfterSignUp();

        expect(outcome, isA<SignInSuccess>());
        await Future<void>.delayed(Duration.zero);
      },
    );

    test(
      'maps a throwing profile read to a pending profile instead of '
      'escaping to the zone handler',
      () => fakeAsync((async) {
        stubResumeUser();
        // Every read is denied: the ladder absorbs three, the fourth rethrows.
        // The account was already created, though, so the user needs the "sign
        // in normally" path here, not a silent crash.
        when(() => repo.findUserByUid('u1')).thenThrow(
          FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
          ),
        );

        expect(resumeThroughLadder(async), isA<SignInProfilePending>());
      }),
    );

    test('a non-retryable read failure reports pending at once', () async {
      stubResumeUser();
      when(() => repo.findUserByUid('u1')).thenThrow(Exception('offline'));

      expect(await notifier().resumeAfterSignUp(), isA<SignInProfilePending>());
    });
  });
}
