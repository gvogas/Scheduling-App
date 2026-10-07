import 'package:fake_async/fake_async.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/splash/application/splash_controller.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockRepo extends Mock implements EmployeesRepository {}

class _MockAuthCache extends Mock implements AuthCache {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const EmployeeRecord(id: '_')));

  group('splashDestinationProvider — disabled account', () {
    late _MockFirebaseAuth mockAuth;
    late _MockUser mockUser;
    late _MockRepo mockRepo;
    late _MockAuthCache mockCache;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      mockAuth = _MockFirebaseAuth();
      mockUser = _MockUser();
      mockRepo = _MockRepo();
      mockCache = _MockAuthCache();
      when(() => mockCache.save(any())).thenAnswer((_) async {});
      when(() => mockAuth.currentUser).thenReturn(mockUser);
      when(() => mockUser.uid).thenReturn('uid1');
      when(() => mockAuth.signOut()).thenAnswer((_) async {});
    });

    test(
      'returns SplashGoToLogin and signs out for a disabled employee',
      () async {
        when(() => mockRepo.findUserByUid('uid1')).thenAnswer(
          (_) async => const UserUidMatch(
            id: 'doc1',
            data: {
              'uid': 'uid1',
              'role': 'employee',
              'status': 'disabled',
              'name': 'Jane',
              'email': 'jane@example.com',
              'phone': '',
              'colorValue': '4280391411',
            },
          ),
        );

        final container = ProviderContainer(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            employeesRepositoryProvider.overrideWithValue(mockRepo),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(splashDestinationProvider.future);

        expect(result, isA<SplashGoToLogin>());
        verify(() => mockAuth.signOut()).called(1);
      },
    );

    test('returns SplashGoToCalendar for an active employee', () async {
      when(() => mockRepo.findUserByUid('uid1')).thenAnswer(
        (_) async => const UserUidMatch(
          id: 'doc1',
          data: {
            'uid': 'uid1',
            'role': 'employee',
            'status': 'active',
            'name': 'Jane',
            'email': 'jane@example.com',
            'phone': '',
            'colorValue': '4280391411',
          },
        ),
      );

      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          employeesRepositoryProvider.overrideWithValue(mockRepo),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToCalendar>());
      verifyNever(() => mockAuth.signOut());
    });

    test('routes an invited user to setup and KEEPS the session', () async {
      // Deliberate change from the code-flow era, which signed invited users
      // out here. An admin-created account is mid-setup, not unauthorized:
      // the credential they just signed in with is exactly the one the setup
      // screen needs, so signing them out makes setup unreachable. The
      // account stays `invited`, so firestore.rules still grants it nothing.
      when(() => mockRepo.findUserByUid('uid1')).thenAnswer(
        (_) async => const UserUidMatch(
          id: 'doc1',
          data: {
            'uid': 'uid1',
            'role': 'employee',
            'status': 'invited',
            'name': 'Jane Doe',
            'firstName': 'Jane',
            'lastName': 'Doe',
            'email': 'jane@example.com',
            'phone': '',
            'colorValue': '4280391411',
          },
        ),
      );

      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          employeesRepositoryProvider.overrideWithValue(mockRepo),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToAccountSetup>());
      expect((result as SplashGoToAccountSetup).firstName, 'Jane');
      verifyNever(() => mockAuth.signOut());
    });

    test('returns SplashGoToLogin for a doc with empty status', () async {
      // C1 edge case: empty status must also fail the gate, not just
      // exact-match 'disabled'. This is why the setup branch above tests
      // `isInvited` (an exact match) rather than `!isActive` — widening it
      // would route an empty or unknown status into setup instead of out.
      when(() => mockRepo.findUserByUid('uid1')).thenAnswer(
        (_) async => const UserUidMatch(
          id: 'doc1',
          data: {
            'uid': 'uid1',
            'role': 'employee',
            'status': '',
            'name': 'Jane',
            'email': 'jane@example.com',
            'phone': '',
            'colorValue': '4280391411',
          },
        ),
      );

      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          employeesRepositoryProvider.overrideWithValue(mockRepo),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToLogin>());
      verify(() => mockAuth.signOut()).called(1);
    });

    test(
      'returns SplashGoToLogin for a missing doc even if sign-out throws',
      () async {
        when(
          () => mockRepo.findUserByUid('uid1'),
        ).thenAnswer((_) async => null);
        when(
          () => mockAuth.signOut(),
        ).thenThrow(Exception('ios signOut failed'));

        final container = ProviderContainer(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            employeesRepositoryProvider.overrideWithValue(mockRepo),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(splashDestinationProvider.future);

        expect(result, isA<SplashGoToLogin>());
        verify(() => mockAuth.signOut()).called(1);
      },
    );

    test(
      'returns SplashGoToLogin for a disabled employee even if sign-out throws',
      () async {
        when(() => mockRepo.findUserByUid('uid1')).thenAnswer(
          (_) async => const UserUidMatch(
            id: 'doc1',
            data: {
              'uid': 'uid1',
              'role': 'employee',
              'status': 'disabled',
              'name': 'Jane',
              'email': 'jane@example.com',
              'phone': '',
              'colorValue': '4280391411',
            },
          ),
        );
        when(
          () => mockAuth.signOut(),
        ).thenThrow(Exception('ios signOut failed'));

        final container = ProviderContainer(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            employeesRepositoryProvider.overrideWithValue(mockRepo),
          ],
        );
        addTearDown(container.dispose);

        final result = await container.read(splashDestinationProvider.future);

        expect(result, isA<SplashGoToLogin>());
        verify(() => mockAuth.signOut()).called(1);
      },
    );

    test('rethrows when findUserByUid throws (transient errors)', () async {
      // M8: transient Firestore failures must rethrow, not sign out, so the splash UI can surface an error and retry.
      when(
        () => mockRepo.findUserByUid('uid1'),
      ).thenThrow(Exception('network down'));

      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          employeesRepositoryProvider.overrideWithValue(mockRepo),
        ],
        // Match the app's ProviderScope: retry disabled so the transient
        // error propagates instead of being retried in the background.
        retry: (retryCount, error) => null,
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(splashDestinationProvider.future),
        throwsA(isA<Exception>()),
      );
      verifyNever(() => mockAuth.signOut());
    });

    test('a permission-denied walks the SHARED ladder before surfacing', () {
      // The splash budget, pinned. This call site used to pass
      // `const [500ms, 1500ms]`; it now inherits `kAuthPropagationDelays`
      // (400/1200/2500) as `error-handling.md` requires — three retries rather
      // than two, and up to 4.1 s of backoff rather than 2.0 s before a
      // deleted or deactivated account is signed out. That is the one
      // user-VISIBLE consequence of the single-ladder rule: a cold start on
      // such an account sits on the splash screen ~2.1 s longer. Deliberate,
      // but nothing pinned it, so a change to the shared ladder could move a
      // launch-path delay with no test saying so.
      fakeAsync((async) {
        var attempts = 0;
        when(() => mockRepo.findUserByUid('uid1')).thenAnswer((_) async {
          attempts++;
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
          );
        });

        final container = ProviderContainer(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            employeesRepositoryProvider.overrideWithValue(mockRepo),
          ],
          retry: (retryCount, error) => null,
        );
        addTearDown(container.dispose);

        Object? surfaced;
        container
            .read(splashDestinationProvider.future)
            .then<void>((_) {}, onError: (Object e) => surfaced = e);

        async.flushMicrotasks();
        expect(attempts, 1, reason: 'the first read is not a retry');

        for (final delay in kAuthPropagationDelays) {
          expect(surfaced, isNull, reason: 'must not surface mid-ladder');
          async.elapse(delay);
        }

        expect(attempts, kAuthPropagationDelays.length + 1);
        expect(async.elapsed, const Duration(milliseconds: 4100));
        expect(surfaced, isA<FirebaseException>());
        verifyNever(() => mockAuth.signOut());
      });
    });

    ProviderContainer containerFor(Map<String, dynamic> data) {
      when(
        () => mockRepo.findUserByUid('uid1'),
      ).thenAnswer((_) async => UserUidMatch(id: 'doc1', data: data));
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(mockAuth),
          employeesRepositoryProvider.overrideWithValue(mockRepo),
          authCacheProvider.overrideWithValue(mockCache),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'routes a reset account to Change password and KEEPS the session',
      () async {
        final container = containerFor({
          'uid': 'uid1',
          'role': 'employee',
          'status': 'active',
          'name': 'Jane',
          'passwordResetRequired': true,
        });

        final result = await container.read(splashDestinationProvider.future);

        expect(result, isA<SplashGoToChangePassword>());
        verifyNever(() => mockAuth.signOut());
        verifyNever(() => mockCache.save(any()));
      },
    );

    test('an invited doc carrying the flag still goes to setup', () async {
      final container = containerFor({
        'uid': 'uid1',
        'role': 'employee',
        'status': 'invited',
        'firstName': 'Jane',
        'passwordResetRequired': true,
      });

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToAccountSetup>());
    });

    test('a disabled doc carrying the flag is still signed out', () async {
      final container = containerFor({
        'uid': 'uid1',
        'role': 'employee',
        'status': 'disabled',
        'passwordResetRequired': true,
      });

      final result = await container.read(splashDestinationProvider.future);

      expect(result, isA<SplashGoToLogin>());
      verify(() => mockAuth.signOut()).called(1);
    });
  });
}
