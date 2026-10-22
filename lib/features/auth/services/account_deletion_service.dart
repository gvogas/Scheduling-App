import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/auth/data/auth_error_mapper.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';

/// App-wide [AccountDeletionService], wired through providers for testability.
final accountDeletionServiceProvider = Provider<AccountDeletionService>(
  (ref) => AccountDeletionService(
    firebaseAuth: ref.watch(firebaseAuthProvider),
    authCache: ref.watch(authCacheProvider),
    logger: ref.watch(loggerProvider),
    sessionForExit: () => ref.read(sessionFenceProvider),
  ),
);

class AccountDeletionService {
  AccountDeletionService({
    FirebaseAuth? firebaseAuth,
    FirebaseFunctions? functions,
    AuthCache? authCache,
    AppLogger? logger,
    SessionFence Function()? sessionForExit,
  }) : _auth = firebaseAuth ?? FirebaseAuth.instance,
       _functions = functions ?? FirebaseFunctions.instance,
       _authCache = authCache ?? AuthCache(),
       _logger = logger ?? AppLogger(),
       _sessionForExit = sessionForExit;

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;
  final AuthCache _authCache;
  final AppLogger _logger;
  final SessionFence Function()? _sessionForExit;

  Future<void> reauthenticateWithPassword(String password) async {
    final user = _auth.currentUser;
    final email = user?.email;
    if (user == null || email == null || email.isEmpty) {
      throw const AuthFailureRequiresRecentLogin();
    }
    try {
      final credential = EmailAuthProvider.credential(
        email: normalizeEmail(email),
        password: password.trim(),
      );
      await user.reauthenticateWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      throw AuthErrorMapper.map(e);
    }
  }

  Future<void> deleteAccount() async {
    final session = _sessionForExit?.call();
    final lease = session?.capture(duringExit: true);
    if (session != null && lease == null) {
      throw const AuthFailureRequiresRecentLogin();
    }
    try {
      await _functions
          .httpsCallable(
            'deleteAccount',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
          )
          .call<dynamic>();
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'unauthenticated') {
        throw const AuthFailureRequiresRecentLogin();
      }
      if (e.code == 'resource-exhausted') {
        throw const AuthFailureTooManyRequests();
      }
      if (e.code == 'unavailable' || e.code == 'deadline-exceeded') {
        throw const AuthFailureNetwork();
      }
      _logger.warn('ACCT-DEL deleteAccount callable failed', e, e.stackTrace);
      throw const AuthFailureUnknown();
    } catch (e, st) {
      _logger.warn('ACCT-DEL deleteAccount failed', e, st);
      throw const AuthFailureUnknown();
    }
    if (lease != null && !lease.isCurrent) return;
    try {
      await _auth.signOut();
    } catch (e, st) {
      // The server-side deletion already landed. A local sign-out failure must
      // not turn that into "delete failed" or leave Settings trying to
      // restore registrations for an account that no longer exists.
      _logger.warn('ACCT-DEL local signOut failed after deletion', e, st);
    } finally {
      if (lease == null || _auth.currentUser == null || lease.isCurrent) {
        try {
          await _authCache.clear();
        } catch (e, st) {
          _logger.warn('ACCT-DEL auth cache clear failed', e, st);
        }
      }
    }
  }
}
