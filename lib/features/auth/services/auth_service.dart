import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/data/firebase_employees_repository.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';

/// App-wide [AuthService], wired through providers for testability.
final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(
    firebaseAuth: ref.watch(firebaseAuthProvider),
    employeesRepository: ref.watch(employeesRepositoryProvider),
    authCache: ref.watch(authCacheProvider),
    logger: ref.watch(loggerProvider),
  ),
);

class AuthService {
  AuthService({
    FirebaseAuth? firebaseAuth,
    EmployeesRepository? employeesRepository,
    AuthCache? authCache,
    AppLogger? logger,
  }) : _auth = firebaseAuth ?? FirebaseAuth.instance,
       _employees =
           employeesRepository ??
           FirebaseEmployeesRepository(FirebaseFirestore.instance),
       _authCache = authCache ?? AuthCache(),
       _logger = logger ?? AppLogger();

  final FirebaseAuth _auth;
  final EmployeesRepository _employees;
  final AuthCache _authCache;
  final AppLogger _logger;

  User? get currentUser => _auth.currentUser;

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return _auth.signInWithEmailAndPassword(
      email: normalizeEmail(email),
      password: password.trim(),
    );
  }

  Future<void> sendPasswordResetEmail(String email) {
    return _auth.sendPasswordResetEmail(email: normalizeEmail(email));
  }

  /// Replaces the starting password before activating the signed-in employee.
  Future<void> completeAccountSetup({
    required String newPassword,
    String firstName = '',
    String lastName = '',
    String phone = '',
    bool termsAccepted = false,
    bool locationConsent = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthFailureSessionExpired();

    await _refuseIfStillTheStartingPassword(user, newPassword.trim());

    try {
      await _employees.completeEmployeeSetup(
        newPassword: newPassword.trim(),
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        phone: phone.trim(),
        termsAccepted: termsAccepted,
        locationConsent: locationConsent,
      );
      // Admin SDK password changes invalidate refresh tokens. Replace this
      // session's credential before the setup screen resolves the profile.
      final email = user.email;
      if (email != null && email.isNotEmpty) {
        await user.reauthenticateWithCredential(
          EmailAuthProvider.credential(
            email: email,
            password: newPassword.trim(),
          ),
        );
      }
    } catch (e, st) {
      final failure = _mapSetupError(e);
      // Keep the chosen password even if activation fails.
      _logger.authFailure(
        'AUTH-SETUP completeAccountSetup: completeEmployeeSetup failed',
        failure,
        e,
        st,
      );
      throw failure;
    }
  }

  /// Refuses a setup password that is still the admin-issued credential.
  Future<void> _refuseIfStillTheStartingPassword(
    User user,
    String candidate,
  ) async {
    final email = user.email;
    if (email == null || email.isEmpty) return;
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: candidate),
      );
    } on FirebaseAuthException catch (e) {
      if (_isWrongPasswordCode(e.code)) return;
      final failure = _mapSetupError(e);
      _logger.authFailure(
        'AUTH-SETUP completeAccountSetup: starting-password check failed',
        failure,
        e,
        StackTrace.current,
      );
      throw failure;
    }
    // Reauth SUCCEEDED, so the password is unchanged.
    const failure = AuthFailureStartingPasswordReused();
    _logger.breadcrumb(
      'AUTH-SETUP completeAccountSetup: refused the starting password '
      '(${failure.runtimeType})',
    );
    throw failure;
  }

  /// Firebase codes that mean the candidate is not the current password.
  static bool _isWrongPasswordCode(String code) =>
      code == 'wrong-password' ||
      code == 'invalid-credential' ||
      code == 'invalid-login-credentials';

  /// Maps setup-only auth failures before falling back to the shared mapper.
  AuthFailure _mapSetupError(Object e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        // Mid-setup, these all mean the setup session is gone.
        case 'requires-recent-login':
        case 'user-token-expired':
        case 'user-not-found':
          return const AuthFailureSessionExpired();
      }
    }
    if (e is FirebaseFunctionsException) {
      if (e.message == 'invalid-newPassword') {
        return const AuthFailureWeakPassword();
      }
      if (e.message == 'account-operation-in-progress') {
        return const AuthFailureTooManyRequests();
      }
      if (e.message == 'setup-upgrade-required') {
        return const AuthFailureSetupNotAvailableYet();
      }

      // Replayed setup completion is already successful for the user.
      if (e.message == 'setup-not-pending') {
        return const AuthFailureSetupAlreadyComplete();
      }
      if (e.message == 'account-not-found') {
        return const AuthFailureNoAccountRecord();
      }
      // Old-backend compatibility for the setup availability guard.
      if (e.message == 'email-not-verified') {
        return const AuthFailureSetupNotAvailableYet();
      }
      if (e.code == 'resource-exhausted') {
        return const AuthFailureTooManyRequests();
      }
      if (e.code == 'unavailable' || e.code == 'deadline-exceeded') {
        return const AuthFailureNetwork();
      }
    }
    return AuthErrorMapper.map(e);
  }

  Future<void> signOut() async {
    Object? signOutError;
    StackTrace? signOutStack;
    try {
      await _auth.signOut();
    } catch (e, st) {
      signOutError = e;
      signOutStack = st;
    } finally {
      // Best-effort cache clear — if the keystore fails here it shouldn't fail
      // signOut too, since we check the cached uid again on next launch.
      try {
        await _authCache.clear();
      } catch (e, st) {
        _logger.warn('ACCT-SIGNOUT auth cache clear failed', e, st);
      }
    }
    if (signOutError == null) return;
    if (_auth.currentUser == null) {
      _logger.warn(
        'ACCT-SIGNOUT local signOut threw after auth state cleared',
        signOutError,
        signOutStack,
      );
      return;
    }
    Error.throwWithStackTrace(signOutError, signOutStack!);
  }
}
