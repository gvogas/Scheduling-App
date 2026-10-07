import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/employees_repository.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/domain/policies/employee_name_policy.dart';

/// Outcome of an employee save, whether an invite or an edit — the form maps
/// this to a notice, an error, or a navigation action.
sealed class EmployeeSaveOutcome {
  const EmployeeSaveOutcome();
}

/// Edit persisted.
class EmployeeUpdated extends EmployeeSaveOutcome {
  const EmployeeUpdated();
}

/// The account was created (or re-provisioned). [credentials] are what the
/// admin reads out — the email and the starting password the server set.
class EmployeeAccountCreated extends EmployeeSaveOutcome {
  const EmployeeAccountCreated(this.credentials);
  final NewAccountCredentials credentials;
}

/// The email already belongs to an account that has finished setup — a field
/// error, not a notice.
class EmployeeEmailInUse extends EmployeeSaveOutcome {
  const EmployeeEmailInUse(this.failure);
  final EmployeesFailureEmailAlreadyExists failure;
}

class EmployeeSaveFailed extends EmployeeSaveOutcome {
  const EmployeeSaveFailed(this.error);
  final Object error;
}

/// A write the reentrancy guard skipped because one is already in flight.
/// Nothing committed and nothing failed, so this surfaces NOTHING — no notice
/// either way. It used to be reported as `EmployeeSaveFailed(SocketException)`,
/// which `composeErrorNotice` classifies by TYPE and rendered as "you appear to
/// be offline" on a double-tap while perfectly online. Same shape as
/// EventDetailsActionBusy.
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

/// A duplicate tap while a status toggle is already in flight.
///
/// Same posture as [EmployeeSaveBusy]: nothing committed and nothing failed, so
/// callers should surface nothing.
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

/// A duplicate tap while this account removal is already in flight.
///
/// Silent by design: the first tap owns the outcome and a second tap is not a
/// new failure.
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

/// Busy state for the employee form/detail surfaces — these drive the Save
/// button and the status button spinners.
///
/// Saving and account-deletion are tracked as **sets of doc ids, not booleans**,
/// because this notifier is app-wide while its surfaces are not: the roster can
/// show several expanded `PendingInviteTile`s at once, each with its own Reset
/// and Remove. A single flag made every row claim to be busy when any one of
/// them was, and — worse — made the reentrancy guard refuse a *different* row's
/// action, which `EmployeeSaveBusy` then dropped silently.
///
/// A brand-new person has no doc id yet, so they key on `''`. That is correct
/// rather than a gap: the invite sheet is modal, so there is only ever one
/// unsaved person, and a double-tap on it collides with itself exactly as it
/// should.
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

  /// Is *anything* saving. The two person sheets are modal and own the only
  /// operation in flight when they are open, so they read this rather than
  /// keying by id.
  bool get isSaving => savingIds.isNotEmpty;

  /// The delete-account sibling of [isSaving] — but note the asymmetry:
  /// [isSaving] has real callers, this one has none in `lib/`. The only
  /// delete-account affordance lives on `PendingInviteTile`, which correctly
  /// asks the id-keyed [isDeletingAccountId]; this survives as the aggregate
  /// the tests assert against. **Don't wire a surface to it** without first
  /// checking that surface really is modal.
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

/// Handles employee create/update/status, shared by the form sheet and the
/// details view. The employees list streams straight from Firestore, so
/// there's no need for a refresh bump here like the paginated clients list
/// needs.
class EmployeeFormController extends Notifier<EmployeeFormActivity> {
  @override
  EmployeeFormActivity build() => const EmployeeFormActivity();

  /// Creates the employee's account. The credentials ride back on the outcome
  /// so the caller can show them to the admin.
  ///
  /// Takes the whole record on purpose. The server's re-provision branch
  /// UPDATES the pending doc's editable fields with whatever it is handed, so
  /// a call site that omits one silently wipes it — passing a record closes
  /// that trap at the CALL SITES, which is where it kept being sprung.
  ///
  /// It does not close it here: the destructuring below is still by hand, so a
  /// new pending-user field added to the server's update set has to be added
  /// to this one place too, with no compile error if it isn't. One place, not
  /// four — but not zero.
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

  /// Persists an edit to an existing employee.
  ///
  /// [emergency] rides along because it is a second write to a different path
  /// (`users/{id}/private/emergency`) that the one Save button owns — routing
  /// it through the same `_save` keeps one in-flight flag and one error path,
  /// so a failure on either write surfaces once. Pass null to leave it alone.
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

  /// Runs [write] for [docId], guarding reentrancy **per employee**.
  ///
  /// Keyed, not global: a second action on the SAME person is a double-tap and
  /// must be refused (the save already running owns that outcome), while one on
  /// a different person is a real action that has to proceed — refusing it
  /// returned `EmployeeSaveBusy`, which by design surfaces nothing, so the tap
  /// vanished with no spinner and no error.
  Future<EmployeeSaveOutcome> _save(
    String docId,
    Future<EmployeeSaveOutcome> Function(EmployeesRepository repo) write,
  ) async {
    // Synchronously first: the sheet's primary button only disables on the next
    // frame, so a double-tap otherwise starts a second concurrent write.
    if (state.isSavingId(docId)) {
      return const EmployeeSaveBusy();
    }
    // Resolve dependencies before the first await. The sheet can be
    // dismissed mid-save, and using the Ref of a disposed notifier throws in
    // Riverpod 3.
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
      // Remove only THIS key — a concurrent save for another employee is still
      // in flight and must keep its own.
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

  /// Deletes an account that has never been set up — the users doc and the
  /// Firebase Auth account both.
  ///
  /// A server refusal (the person finished setup while the admin was looking
  /// at the row) is a *failed* outcome, not a silent success — the live stream
  /// will have flipped the row to Active by the time the notice lands.
  Future<AccountDeleteOutcome> deleteAccount(String docId) async {
    if (state.isDeletingAccountId(docId)) {
      return const AccountDeleteBusy();
    }
    // Resolved before the first await — see _save.
    final repo = ref.read(employeesRepositoryProvider);
    final logger = ref.read(loggerProvider);
    // Keyed like _save: two expanded pending rows can each be removed, and one
    // row's removal must not disable the other's button.
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

  /// Issues a temporary password for an active person and forces a change at next sign-in.
  Future<PasswordResetOutcome> resetPassword(String docId) async {
    if (state.isResettingPassword) return const PasswordResetBusy();
    // Resolved before the first await — see _save.
    final repo = ref.read(employeesRepositoryProvider);
    final logger = ref.read(loggerProvider);
    state = state.copyWith(isResettingPassword: true);
    try {
      return PasswordResetIssued(await repo.resetEmployeePassword(docId));
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
