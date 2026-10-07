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

/// Outcome of a sign-in attempt (or of resuming a session right after signup);
/// the login screen only maps these to banner messages/navigation, and the
/// orchestration lives in [SignInController].
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

/// Signed in, but no provisioned `users` doc exists for this uid — the
/// session was signed out again before this outcome was returned.
class SignInNoProfile extends SignInOutcome {
  const SignInNoProfile();
}

/// The account's `users` doc is not active (disabled staff) — the session
/// was signed out again before this outcome was returned.
class SignInAccountDisabled extends SignInOutcome {
  const SignInAccountDisabled();
}

/// Post-signup resume only: there is no authenticated session to resume.
class SignInNoSession extends SignInOutcome {
  const SignInNoSession();
}

/// Post-setup resume only: signed in but the freshly activated `users` doc
/// isn't readable yet — ask the user to sign in normally.
class SignInProfilePending extends SignInOutcome {
  const SignInProfilePending();
}

/// Signed in against an account whose setup has never been completed.
///
/// The session is deliberately KEPT — it is the credential the setup screen
/// needs. This is the only non-active status that isn't signed out.
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

/// Busy flag for the sign-in flow — drives the button spinner and disables
/// the form fields while the attempt is in flight.
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

/// Orchestrates the sign-in flow shared by the login form and the
/// return-from-signup path, returning a [SignInOutcome]; the screen owns form
/// state and navigation.
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

  /// Runs a full credential sign-in — on success it stays in-progress, and on
  /// any failure it resets itself so the form re-enables.
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
  }) async {
    // Grab these dependencies before the first await — in Riverpod 3, reading
    // ref after the notifier is disposed throws.
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

      // Every account has a doc keyed by uid from the moment the admin
      // creates it — including one that has never been set up.
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

      // First sign-in on an admin-created account: route to setup and KEEP the
      // session. Signing out here would make setup unreachable, since the
      // credential they just used is the one it needs. Checked before the
      // active gate, and an exact `invited` match — an empty or unknown status
      // still falls through to the sign-out below.
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

      // The identity cache and remembered email are best-effort — neither
      // should delay or fail the sign-in, so we fire them off unawaited and
      // just log if they fail.
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

  /// Account setup activates the account while the person is already signed
  /// in, so resolve their profile and let the screen route straight into the
  /// app instead of asking them to sign in again.
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
      // Mirror signIn's gate. This runs immediately after activation, so the
      // doc is normally `active` — but a stale read (offline persistence, or
      // the permission-denied retry served from cache) would otherwise walk an
      // still-`invited` person into the hub, where every rules gate denies them
      // and nothing routes them back to setup.
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
      // The account is already created and active server-side, so we just
      // report "pending" here — the user can recover by signing in normally.
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
