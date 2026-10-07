import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/storage/secure_storage_service.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

/// Outcome of a sign-in attempt, or of resuming a session right after setup.
sealed class SignInOutcome {
  const SignInOutcome();
}

/// Signed in with an active, provisioned account — route into the app.
class SignInSuccess extends SignInOutcome {
  const SignInSuccess(this.employee);
  final EmployeeRecord employee;
}

/// Auth accepted the request but returned no user.
class SignInInvalidCredentials extends SignInOutcome {
  const SignInInvalidCredentials();
}

/// No provisioned `users` doc for this uid; the session was already signed out.
class SignInNoProfile extends SignInOutcome {
  const SignInNoProfile();
}

/// The `users` doc is not active; the session was already signed out.
class SignInAccountDisabled extends SignInOutcome {
  const SignInAccountDisabled();
}

/// Post-signup resume only: there is no authenticated session to resume.
class SignInNoSession extends SignInOutcome {
  const SignInNoSession();
}

/// Post-setup resume only: the activated `users` doc isn't readable yet.
class SignInProfilePending extends SignInOutcome {
  const SignInProfilePending();
}

/// Signed in against a never-set-up account; the session is KEPT for setup.
class SignInNeedsAccountSetup extends SignInOutcome {
  const SignInNeedsAccountSetup({
    required this.firstName,
    required this.lastName,
  });
  final String firstName;
  final String lastName;
}

/// Signed in against an active account an admin has reset; the session is KEPT for Change password.
class SignInNeedsPasswordChange extends SignInOutcome {
  const SignInNeedsPasswordChange();
}

/// The attempt failed; [failure] is already mapped for localized display.
class SignInError extends SignInOutcome {
  const SignInError(this.failure);
  final AuthFailure failure;
}

/// Busy flag for the sign-in flow.
@immutable
class SignInState {
  const SignInState({this.inProgress = false});

  final bool inProgress;

  @override
  bool operator ==(Object other) =>
      other is SignInState && other.inProgress == inProgress;

  @override
  int get hashCode => inProgress.hashCode;
}

/// Orchestrates sign-in and the post-setup resume; the screen owns form state and navigation.
class SignInController extends Notifier<SignInState> {
  @override
  SignInState build() => const SignInState();

  Future<void> _bestEffortSignOut(
    AuthService auth,
    AppLogger logger, {
    required String label,
  }) async {
    try {
      await auth.signOut();
    } catch (error, stackTrace) {
      logger.warn(label, error, stackTrace);
    }
  }

  /// Credential sign-in; stays in-progress on success and resets on any failure.
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    // Resolved before the first await: a disposed notifier's Ref throws.
    final auth = ref.read(authServiceProvider);
    final employees = ref.read(employeesRepositoryProvider);
    final authCache = ref.read(authCacheProvider);
    final storage = ref.read(secureStorageServiceProvider);
    final logger = ref.read(loggerProvider);

    state = const SignInState(inProgress: true);
    try {
      final credential = await auth.signIn(email: email, password: password);
      final user = credential.user;
      if (user == null) {
        _settle();
        return const SignInInvalidCredentials();
      }

      final userDoc = await retryAsync(() => employees.findUserByUid(user.uid));

      if (userDoc == null) {
        // Signed in, but no profile doc — not a provisioned account.
        await _bestEffortSignOut(
          auth,
          logger,
          label: 'AUTH-SIGNIN no-profile signOut failed',
        );
        _settle();
        return const SignInNoProfile();
      }

      final employee = EmployeeRecord.fromMap(userDoc.id, userDoc.data);

      // Invited keeps the session and is checked before the active gate (root CLAUDE.md).
      if (employee.isInvited) {
        _settle();
        return SignInNeedsAccountSetup(
          firstName: employee.firstName,
          lastName: employee.lastName,
        );
      }

      if (!employee.isActive) {
        await _bestEffortSignOut(
          auth,
          logger,
          label: 'AUTH-SIGNIN inactive signOut failed',
        );
        _settle();
        return const SignInAccountDisabled();
      }

      if (employee.passwordResetRequired) {
        // A stale identity cache would let a cold start fast-path past the change.
        await authCache.clear().catchError((Object e, StackTrace st) {
          logger.warn('AUTH-SIGNIN identity cache clear failed', e, st);
        });
        _settle();
        return const SignInNeedsPasswordChange();
      }

      // Best-effort and unawaited: neither may delay or fail the sign-in.
      unawaited(
        authCache.save(employee).catchError((Object e, StackTrace st) {
          logger.warn('AUTH-SIGNIN identity cache save failed', e, st);
        }),
      );
      unawaited(
        storage
            .write(SecureStorageKeys.rememberedEmail, normalizeEmail(email))
            .catchError((Object e, StackTrace st) {
              logger.warn('AUTH-SIGNIN remember email failed', e, st);
            }),
      );

      return SignInSuccess(employee);
    } catch (error, stackTrace) {
      final failure = AuthErrorMapper.map(error);
      logger.authFailure(
        'AUTH-SIGNIN sign-in failed',
        failure,
        error,
        stackTrace,
      );
      _settle();
      return SignInError(failure);
    }
  }

  /// Routes a just-activated, still-signed-in person straight into the app.
  Future<SignInOutcome> resumeAfterSignUp() async {
    final auth = ref.read(authServiceProvider);
    final employees = ref.read(employeesRepositoryProvider);
    final authCache = ref.read(authCacheProvider);
    final logger = ref.read(loggerProvider);
    final user = auth.currentUser;
    if (user == null) return const SignInNoSession();
    try {
      final userDoc = await retryAsync(() => employees.findUserByUid(user.uid));
      if (userDoc == null) return const SignInProfilePending();
      final employee = EmployeeRecord.fromMap(userDoc.id, userDoc.data);
      // A stale read can still show `invited` here (root CLAUDE.md, Auth).
      if (!employee.isActive || employee.passwordResetRequired) {
        return const SignInProfilePending();
      }
      unawaited(
        authCache.save(employee).catchError((Object e, StackTrace st) {
          logger.warn('AUTH-SETUP resume identity cache save failed', e, st);
        }),
      );
      return SignInSuccess(employee);
    } catch (error, stackTrace) {
      // Already active server-side; a normal sign-in recovers.
      logger.warn('AUTH-SETUP resume after setup failed', error, stackTrace);
      return const SignInProfilePending();
    }
  }

  void _settle() {
    if (ref.mounted) state = const SignInState();
  }
}

final signInControllerProvider =
    NotifierProvider.autoDispose<SignInController, SignInState>(
      SignInController.new,
    );
