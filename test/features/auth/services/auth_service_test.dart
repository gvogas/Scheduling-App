import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

class _MockUser extends Mock implements User {}

class _MockEmployeesRepository extends Mock implements EmployeesRepository {}

class _FakeAuthCredential extends Fake implements AuthCredential {}

class _FakeUserCredential extends Fake implements UserCredential {}

void main() {
  late _MockFirebaseAuth auth;
  late _MockEmployeesRepository employees;
  late _MockUser user;
  late AuthService service;

  setUpAll(() => registerFallbackValue(_FakeAuthCredential()));

  setUp(() {
    auth = _MockFirebaseAuth();
    employees = _MockEmployeesRepository();
    user = _MockUser();
    service = AuthService(firebaseAuth: auth, employeesRepository: employees);
    when(() => user.uid).thenReturn('uid-001');
    when(() => user.email).thenReturn('ada@example.com');
    when(() => auth.currentUser).thenReturn(user);
    when(() => auth.signOut()).thenAnswer((_) async {});
    when(() => user.updatePassword(any())).thenAnswer((_) async {});
    // The DEFAULT is the ordinary case: the typed password is not the
    // account's current one, so the starting-password check refuses to
    // reauthenticate and setup proceeds. Stubbed here rather than per test
    // so every existing case exercises the check instead of skipping it.
    var reauthCalls = 0;
    when(() => user.reauthenticateWithCredential(any())).thenAnswer((_) async {
      if (reauthCalls++ == 0) {
        throw FirebaseAuthException(code: 'wrong-password');
      }
      return _FakeUserCredential();
    });
  });

  /// Mocktail compares the whole invocation, so the stub has to name every
  /// argument the call site passes.
  When<Future<void>> stubSetup() => when(
    () => employees.completeEmployeeSetup(
      newPassword: any(named: 'newPassword'),
      firstName: any(named: 'firstName'),
      lastName: any(named: 'lastName'),
      phone: any(named: 'phone'),
      termsAccepted: any(named: 'termsAccepted'),
      locationConsent: any(named: 'locationConsent'),
    ),
  );

  group('completeAccountSetup against an OLD backend', () {
    test(
      'maps email-not-verified to an expected, actionable failure',
      () async {
        // The guard is gone from the live backend; this only fires if one is
        // rolled back under a shipped app build (docs/DEPLOYMENT.md section 3).
        stubSetup().thenThrow(
          FirebaseFunctionsException(
            code: 'failed-precondition',
            message: 'email-not-verified',
          ),
        );

        await expectLater(
          service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
          throwsA(isA<AuthFailureSetupNotAvailableYet>()),
        );
      },
    );

    test('files no non-fatal for a state the person cannot fix', () {
      // The whole point of the mapping: without it this is
      // AuthFailureUnknown, and every retry by someone permanently stuck
      // records a Crashlytics issue.
      expect(const AuthFailureSetupNotAvailableYet().isExpected, isTrue);
    });
  });

  group('completeAccountSetup starting-password check', () {
    test('refuses the starting password and never rotates it', () async {
      stubSetup().thenAnswer((_) async {});
      // Reauth SUCCEEDING means the typed value is still the account's
      // current password, i.e. they retyped what the admin issued.
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenAnswer((_) async => _FakeUserCredential());

      await expectLater(
        service.completeAccountSetup(newPassword: 'Wh4tTheyGave'),
        throwsA(isA<AuthFailureStartingPasswordReused>()),
      );

      // The half that matters: refused BEFORE the write, so the account is
      // left `invited` rather than activated on a password the admin holds.
      verifyNever(() => user.updatePassword(any()));
      verifyNever(
        () => employees.completeEmployeeSetup(
          newPassword: any(named: 'newPassword'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
          phone: any(named: 'phone'),
          termsAccepted: any(named: 'termsAccepted'),
          locationConsent: any(named: 'locationConsent'),
        ),
      );
    });

    test('is an expected failure, so it files no non-fatal', () {
      // A person choosing the password they were just handed is ordinary,
      // not a defect worth a Crashlytics record.
      expect(const AuthFailureStartingPasswordReused().isExpected, isTrue);
    });

    test('checks the password it is about to SET, trimmed', () async {
      stubSetup().thenAnswer((_) async {});

      await service.completeAccountSetup(newPassword: '  N3wPassw0rd  ');

      // Checking an untrimmed value while storing a trimmed one would test a
      // different string from the one that ends up on the account.
      final captured = verify(
        () => user.reauthenticateWithCredential(captureAny()),
      ).captured.first;
      expect((captured as EmailAuthCredential).password, 'N3wPassw0rd');
      verifyNever(() => user.updatePassword(any()));
    });

    for (final code in [
      'wrong-password',
      'invalid-credential',
      'invalid-login-credentials',
    ]) {
      test('treats $code as "different password" and proceeds', () async {
        stubSetup().thenAnswer((_) async {});
        var calls = 0;
        when(() => user.reauthenticateWithCredential(any())).thenAnswer((
          _,
        ) async {
          if (calls++ == 0) throw FirebaseAuthException(code: code);
          return _FakeUserCredential();
        });

        await service.completeAccountSetup(newPassword: 'N3wPassw0rd!');

        verifyNever(() => user.updatePassword(any()));
      });
    }

    test('surfaces an unrelated reauth error instead of passing', () async {
      stubSetup().thenAnswer((_) async {});
      // The dangerous shape is treating any failure as "looks different":
      // a network blip would then wave through the case this check exists
      // for. It must fail loudly rather than silently permit.
      when(
        () => user.reauthenticateWithCredential(any()),
      ).thenThrow(FirebaseAuthException(code: 'network-request-failed'));

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailure>()),
      );

      verifyNever(() => user.updatePassword(any()));
    });

    test('skips the check when the account carries no email', () async {
      stubSetup().thenAnswer((_) async {});
      when(() => user.email).thenReturn(null);

      await service.completeAccountSetup(newPassword: 'N3wPassw0rd!');

      // Nothing to build a credential from, so setup must still complete
      // rather than dead-end on a check it cannot perform.
      verifyNever(() => user.reauthenticateWithCredential(any()));
      verifyNever(() => user.updatePassword(any()));
    });
  });

  group('completeAccountSetup', () {
    test('replaces the password, then activates the account', () async {
      stubSetup().thenAnswer((_) async {});

      await service.completeAccountSetup(
        newPassword: 'N3wPassw0rd!',
        firstName: 'Zoé',
        lastName: 'Roy',
        phone: '(514) 555-1234',
        termsAccepted: true,
        locationConsent: true,
      );

      verifyInOrder([
        () => employees.completeEmployeeSetup(
          newPassword: 'N3wPassw0rd!',
          firstName: 'Zoé',
          lastName: 'Roy',
          phone: '(514) 555-1234',
          termsAccepted: true,
          locationConsent: true,
        ),
      ]);
      verify(() => user.reauthenticateWithCredential(any())).called(2);
      verifyNever(() => user.updatePassword(any()));
    });

    test('trims the profile it sends', () async {
      stubSetup().thenAnswer((_) async {});

      await service.completeAccountSetup(
        newPassword: '  N3wPassw0rd!  ',
        firstName: '  Zoé  ',
        lastName: '  Roy  ',
        phone: '  (514) 555-1234  ',
      );

      verifyNever(() => user.updatePassword(any()));
      verify(
        () => employees.completeEmployeeSetup(
          newPassword: 'N3wPassw0rd!',
          firstName: 'Zoé',
          lastName: 'Roy',
          phone: '(514) 555-1234',
          termsAccepted: false,
          locationConsent: false,
        ),
      ).called(1);
    });

    test(
      'maps server password validation without a client Auth write',
      () async {
        stubSetup().thenThrow(
          FirebaseFunctionsException(
            code: 'invalid-argument',
            message: 'invalid-newPassword',
          ),
        );
        await expectLater(
          service.completeAccountSetup(newPassword: 'abc'),
          throwsA(isA<AuthFailureWeakPassword>()),
        );
        verifyNever(() => user.updatePassword(any()));
      },
    );

    test('fails when there is no signed-in user to act on', () async {
      when(() => auth.currentUser).thenReturn(null);

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailureSessionExpired>()),
      );
      verifyNever(() => user.updatePassword(any()));
    });

    test('maps an already-active account to its own failure', () async {
      stubSetup().thenThrow(
        FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'setup-not-pending',
        ),
      );

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailureSetupAlreadyComplete>()),
      );
    });

    test('maps a missing users doc to its own failure', () async {
      stubSetup().thenThrow(
        FirebaseFunctionsException(
          code: 'not-found',
          message: 'account-not-found',
        ),
      );

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailureNoAccountRecord>()),
      );
    });

    test('maps a rate-limit refusal', () async {
      stubSetup().thenThrow(
        FirebaseFunctionsException(code: 'resource-exhausted', message: 'slow'),
      );

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailureTooManyRequests>()),
      );
    });

    test('maps an unavailable backend to a network failure', () async {
      stubSetup().thenThrow(
        FirebaseFunctionsException(code: 'unavailable', message: 'offline'),
      );

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailureNetwork>()),
      );
    });

    test('never asks the user about email verification', () async {
      stubSetup().thenAnswer((_) async {});

      await service.completeAccountSetup(
        newPassword: 'Passw0rdAbc',
        firstName: 'Sam',
        lastName: 'Lee',
        termsAccepted: true,
        locationConsent: true,
      );

      // The gate is gone: no reload, no forced token refresh, no verification
      // send anywhere on the setup path.
      verifyNever(() => user.reload());
      verifyNever(() => user.sendEmailVerification());
      verifyNever(() => user.getIdToken(any()));
      // Mocktail matches positional arity, so the one-arg form above does
      // not cover a re-added bare getIdToken().
      verifyNever(() => user.getIdToken());
    });

    test('does NOT sign out or revert the password on failure', () async {
      // The new password is the one the person just chose and typed twice.
      // Reverting it to the temporary default would be strictly worse than
      // leaving them `invited` with a password that works.
      stubSetup().thenThrow(
        FirebaseFunctionsException(code: 'internal', message: 'boom'),
      );

      await expectLater(
        service.completeAccountSetup(newPassword: 'N3wPassw0rd!'),
        throwsA(isA<AuthFailureUnknown>()),
      );
      verifyNever(() => auth.signOut());
    });
  });

  group('signOut', () {
    test(
      'swallows a local sign-out failure once auth state is already cleared',
      () async {
        when(() => auth.signOut()).thenThrow(Exception('ios signOut failed'));
        when(() => auth.currentUser).thenReturn(null);

        await service.signOut();

        verify(() => auth.signOut()).called(1);
      },
    );

    test(
      'rethrows a local sign-out failure when the session is still live',
      () async {
        when(() => auth.signOut()).thenThrow(Exception('ios signOut failed'));
        when(() => auth.currentUser).thenReturn(user);

        await expectLater(service.signOut(), throwsException);
      },
    );
  });
}
