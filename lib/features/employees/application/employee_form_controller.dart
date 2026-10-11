import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/account_deletion_service.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/domain/policies/employee_name_policy.dart';

/// Outcome of an employee save, whether an invite or an edit.
sealed class EmployeeSaveOutcome {
  const EmployeeSaveOutcome();
}

/// Edit persisted.
class EmployeeUpdated extends EmployeeSaveOutcome {
  const EmployeeUpdated();
}

/// The account was created (or re-provisioned); [credentials] are what the admin reads out.
class EmployeeAccountCreated extends EmployeeSaveOutcome {
  const EmployeeAccountCreated(this.credentials);
  final NewAccountCredentials credentials;
}

/// The email belongs to an account that finished setup — a field error, not a notice.
class EmployeeEmailInUse extends EmployeeSaveOutcome {
  const EmployeeEmailInUse(this.failure);
  final EmployeesFailureEmailAlreadyExists failure;
}

class EmployeeSaveFailed extends EmployeeSaveOutcome {
  const EmployeeSaveFailed(this.error);
  final Object error;
}

/// A write the reentrancy guard skipped; surfaces nothing.
class EmployeeSaveBusy extends EmployeeSaveOutcome {
  const EmployeeSaveBusy();
}

/// Outcome of a disable/enable toggle.
sealed class EmployeeStatusOutcome {
  const EmployeeStatusOutcome();
}

class EmployeeStatusChanged extends EmployeeStatusOutcome {
  const EmployeeStatusChanged();
}

class EmployeeStatusChangeFailed extends EmployeeStatusOutcome {
  const EmployeeStatusChangeFailed(this.error);
  final Object error;
}

/// A duplicate tap while a status toggle is in flight; surfaces nothing.
class EmployeeStatusBusy extends EmployeeStatusOutcome {
  const EmployeeStatusBusy();
}

/// Outcome of revoking a pending invite.
sealed class AccountDeleteOutcome {
  const AccountDeleteOutcome();
}

class AccountDeleted extends AccountDeleteOutcome {
  const AccountDeleted();
}

class AccountDeleteFailed extends AccountDeleteOutcome {
  const AccountDeleteFailed(this.error);
  final Object error;
}

/// A duplicate tap while this account removal is in flight; surfaces nothing.
class AccountDeleteBusy extends AccountDeleteOutcome {
  const AccountDeleteBusy();
}

/// Outcome of an admin resetting an active person's password.
sealed class PasswordResetOutcome {
  const PasswordResetOutcome();
}

/// The server issued a temporary password; [credentials] are what the admin reads out.
class PasswordResetIssued extends PasswordResetOutcome {
  const PasswordResetIssued(this.credentials);
  final NewAccountCredentials credentials;
}

class PasswordResetFailed extends PasswordResetOutcome {
  const PasswordResetFailed(this.error);
  final Object error;
}

/// A duplicate tap while a reset is in flight; surfaces nothing.
class PasswordResetBusy extends PasswordResetOutcome {
  const PasswordResetBusy();
}

/// Busy state for the employee surfaces, keyed by doc id (see `.claude/rules/employees.md`).
@immutable
class EmployeeFormActivity {
  const EmployeeFormActivity({
    this.savingIds = const {},
    this.deletingAccountIds = const {},
    this.isTogglingStatus = false,
    this.isResettingPassword = false,
  });

  final Set<String> savingIds;
  final Set<String> deletingAccountIds;
  final bool isTogglingStatus;
  final bool isResettingPassword;

  /// Is anything saving — read only by the two modal person sheets.
  bool get isSaving => savingIds.isNotEmpty;

  /// Test-only aggregate; a surface must ask [isDeletingAccountId].
  bool get isDeletingAccount => deletingAccountIds.isNotEmpty;

  /// Is THIS employee saving / being removed — what a roster row must ask.
  bool isSavingId(String docId) => savingIds.contains(docId);
  bool isDeletingAccountId(String docId) => deletingAccountIds.contains(docId);

  EmployeeFormActivity copyWith({
    Set<String>? savingIds,
    Set<String>? deletingAccountIds,
    bool? isTogglingStatus,
    bool? isResettingPassword,
  }) {
    return EmployeeFormActivity(
      savingIds: savingIds ?? this.savingIds,
      deletingAccountIds: deletingAccountIds ?? this.deletingAccountIds,
      isTogglingStatus: isTogglingStatus ?? this.isTogglingStatus,
      isResettingPassword: isResettingPassword ?? this.isResettingPassword,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EmployeeFormActivity &&
      setEquals(other.savingIds, savingIds) &&
      setEquals(other.deletingAccountIds, deletingAccountIds) &&
      other.isTogglingStatus == isTogglingStatus &&
      other.isResettingPassword == isResettingPassword;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(savingIds),
    Object.hashAllUnordered(deletingAccountIds),
    isTogglingStatus,
    isResettingPassword,
  );
}

/// Handles employee create/update/status for the form sheet and the details view.
class EmployeeFormController extends Notifier<EmployeeFormActivity> {
  @override
  EmployeeFormActivity build() => const EmployeeFormActivity();

  /// Creates the account; takes the whole record so re-provisioning cannot wipe a field.
  Future<EmployeeSaveOutcome> createAccount(EmployeeRecord employee) {
    return _save(
      employee.id,
      (repo) async => EmployeeAccountCreated(
        await repo.createEmployeeAccount(
          name: composeEmployeeName(
            firstName: employee.firstName,
            lastName: employee.lastName,
            fallback: employee.name,
          ),
          firstName: employee.firstName,
          lastName: employee.lastName,
          email: employee.email,
          phone: employee.phone,
          colorValue: employee.color.toARGB32().toString(),
          jobTitle: employee.jobTitle.raw,
        ),
      ),
    );
  }

  /// Persists an edit; a null [emergency] leaves the emergency contact alone.
  Future<EmployeeSaveOutcome> updateEmployee(
    EmployeeRecord employee, {
    EmergencyContact? emergency,
  }) {
    return _save(employee.id, (repo) async {
      await repo.updateEmployee(docId: employee.id, employee: employee);
      if (emergency != null) {
        await repo.saveEmergencyContact(employee.id, emergency);
      }
      return const EmployeeUpdated();
    });
  }

  /// Runs [write] for [docId], guarding reentrancy per employee.
  Future<EmployeeSaveOutcome> _save(
    String docId,
    Future<EmployeeSaveOutcome> Function(EmployeesRepository repo) write,
  ) async {
    if (state.isSavingId(docId)) {
      return const EmployeeSaveBusy();
    }
    // Resolved before the first await: a disposed notifier's Ref throws.
    final repo = ref.read(employeesRepositoryProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(savingIds: {...state.savingIds, docId});
    try {
      return await write(repo);
    } catch (e, st) {
      if (e is EmployeesFailureEmailAlreadyExists) {
        return EmployeeEmailInUse(e);
      }
      logger.warn('EMP-CREATE saveEmployee failed', e, st);
      return EmployeeSaveFailed(e);
    } finally {
      if (ref.mounted) {
        state = state.copyWith(savingIds: {...state.savingIds}..remove(docId));
      }
    }
  }

  /// Disables ([disable] true) or re-enables the employee's account.
  Future<EmployeeStatusOutcome> setEmployeeStatus({
    required String docId,
    required bool disable,
  }) async {
    if (state.isTogglingStatus) {
      return const EmployeeStatusBusy();
    }
    // Resolved before the first await — see _save.
    final repo = ref.read(employeesRepositoryProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(isTogglingStatus: true);
    try {
      if (disable) {
        await repo.deactivateEmployee(docId);
      } else {
        await repo.reactivateEmployee(docId);
      }
      return const EmployeeStatusChanged();
    } catch (e, st) {
      logger.warn('EMP-STATUS toggleEmployeeStatus failed', e, st);
      return EmployeeStatusChangeFailed(e);
    } finally {
      if (ref.mounted) state = state.copyWith(isTogglingStatus: false);
    }
  }

  /// Deletes a never-set-up account's users doc and Auth account; a server refusal is a failure.
  Future<AccountDeleteOutcome> deleteAccount(String docId) async {
    if (state.isDeletingAccountId(docId)) {
      return const AccountDeleteBusy();
    }
    // Resolved before the first await — see _save.
    final repo = ref.read(employeesRepositoryProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(
      deletingAccountIds: {...state.deletingAccountIds, docId},
    );
    try {
      await repo.deleteEmployeeAccount(docId);
      return const AccountDeleted();
    } catch (e, st) {
      logger.warn('EMP-DELETE deleteEmployeeAccount failed', e, st);
      return AccountDeleteFailed(e);
    } finally {
      if (ref.mounted) {
        state = state.copyWith(
          deletingAccountIds: {...state.deletingAccountIds}..remove(docId),
        );
      }
    }
  }

  /// Re-authenticates the admin with [password], then issues a temporary password.
  Future<PasswordResetOutcome> resetPassword(
    String docId, {
    required String password,
  }) async {
    if (state.isResettingPassword) return const PasswordResetBusy();
    // Resolved before the first await — see _save.
    final repo = ref.read(employeesRepositoryProvider);
    final reauth = ref.read(accountDeletionServiceProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(isResettingPassword: true);
    try {
      await reauth.reauthenticateWithPassword(password);
      return PasswordResetIssued(await repo.resetEmployeePassword(docId));
    } on AuthFailure catch (e, st) {
      logger.authFailure('EMP-RESETPW reauthenticate failed', e, e, st);
      return PasswordResetFailed(e);
    } catch (e, st) {
      logger.warn('EMP-RESETPW resetEmployeePassword failed', e, st);
      return PasswordResetFailed(e);
    } finally {
      if (ref.mounted) state = state.copyWith(isResettingPassword: false);
    }
  }
}

final employeeFormControllerProvider =
    NotifierProvider.autoDispose<EmployeeFormController, EmployeeFormActivity>(
      EmployeeFormController.new,
    );
