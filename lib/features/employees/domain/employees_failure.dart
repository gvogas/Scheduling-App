import 'package:flutter/widgets.dart';

import 'package:scheduling/core/errors/failure.dart';
import 'package:scheduling/l10n/l10n.dart';

sealed class EmployeesFailure extends Failure {
  const EmployeesFailure();
}

class EmployeesFailureEmailAlreadyExists extends EmployeesFailure {
  const EmployeesFailureEmailAlreadyExists();

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_anEmployeeWithThisEmailAlreadyExists;
}

/// `deleteEmployeeAccount` refused: the person finished setting up, or their
/// account was already removed, between the roster row rendering and the tap.
/// Both server rejections (`account-not-pending`, `account-not-found`) collapse
/// here — the admin needs the same thing said either way, and the live stream
/// has already dropped or flipped the row.
class EmployeesFailureAccountNoLongerPending extends EmployeesFailure {
  const EmployeesFailureAccountNoLongerPending();

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_thatAccountIsNoLongerPending;
}

/// `resetEmployeePassword` refused because the target holds the admin role.
class EmployeesFailureTargetIsAdmin extends EmployeesFailure {
  const EmployeesFailureTargetIsAdmin();

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.employees_resetPasswordAdminRefused;
}

/// `resetEmployeePassword` refused the caller's re-auth as too old.
class EmployeesFailureReauthRequired extends EmployeesFailure {
  const EmployeesFailureReauthRequired();

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.employees_resetPasswordReauthExpired;
}

class EmployeesFailureUnknown extends EmployeesFailure {
  const EmployeesFailureUnknown();

  @override
  String toLocalizedMessage(BuildContext context) =>
      context.l10n.error_somethingWentWrongPleaseTryAgain;
}
