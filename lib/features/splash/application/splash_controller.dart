import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

sealed class SplashDestination {
  const SplashDestination();
}

class SplashGoToLogin extends SplashDestination {
  const SplashGoToLogin();
}

class SplashGoToCalendar extends SplashDestination {
  const SplashGoToCalendar({required this.isAdmin, required this.employeeId});
  final bool isAdmin;
  final String employeeId;
}

/// The account exists and the credential is good, but the person has never
/// finished setup — they are still on the password their admin handed them.
///
/// This is the ONE status that must not be signed out. Everything else
/// non-`active` (disabled, or a doc that vanished) still gets the boot: see
/// the invited-vs-disabled split in [splashDestinationProvider].
class SplashGoToAccountSetup extends SplashDestination {
  const SplashGoToAccountSetup({
    required this.firstName,
    required this.lastName,
  });
  final String firstName;
  final String lastName;
}

/// An active account an admin has reset: keep the session and force a new password.
class SplashGoToChangePassword extends SplashDestination {
  const SplashGoToChangePassword();
}

Future<SplashDestination> _signOutToLogin(
  Ref ref,
  AppLogger logger, {
  required String logContext,
}) async {
  try {
    await ref.read(authServiceProvider).signOut();
  } catch (e, st) {
    logger.warn(logContext, e, st);
  }
  return const SplashGoToLogin();
}

final splashDestinationProvider = FutureProvider<SplashDestination>((
  ref,
) async {
  final auth = ref.watch(firebaseAuthProvider);
  final user = auth.currentUser;
  if (user == null) return const SplashGoToLogin();

  final employeesRepo = ref.watch(employeesRepositoryProvider);
  final logger = ref.read(loggerProvider);
  final UserUidMatch? match;
  try {
    match = await retryAsync(
      () => employeesRepo.findUserByUid(user.uid),
      onRetry: (attempt, e, st) =>
          logger.warn('SPLASH findUserByUid retry $attempt', e, st),
    );
  } catch (e, st) {
    logger.warn('SPLASH findUserByUid failed after retries', e, st);
    rethrow;
  }
  if (match == null) {
    return await _signOutToLogin(
      ref,
      logger,
      logContext: 'SPLASH signOut failed after missing employee record',
    );
  }

  final authCache = ref.read(authCacheProvider);
  final employee = EmployeeRecord.fromMap(match.id, match.data);
  // `invited` keeps the session for setup; test exact `isInvited`, never `isDisabled` (ADR-0013).
  if (employee.isInvited) {
    return SplashGoToAccountSetup(
      firstName: employee.firstName,
      lastName: employee.lastName,
    );
  }
  if (!employee.isActive) {
    return await _signOutToLogin(
      ref,
      logger,
      logContext: 'SPLASH signOut failed for non-active employee',
    );
  }
  if (employee.passwordResetRequired) return const SplashGoToChangePassword();
  unawaited(
    authCache.save(employee).catchError((Object e, StackTrace st) {
      logger.warn('SPLASH auth cache save failed', e, st);
    }),
  );
  return SplashGoToCalendar(isAdmin: employee.isAdmin, employeeId: employee.id);
});
