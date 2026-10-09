import 'package:flutter/widgets.dart';

import 'package:scheduling/core/errors/failure.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/l10n/l10n.dart';

enum AuthErrorContext {
  login,
  register,
  forgotPassword,
  reauthentication,
  general,
}

sealed class AuthFailure extends Failure {
  const AuthFailure();

  @override
  String toLocalizedMessage(BuildContext context) =>
      toLocalizedMessageInContext(context, AuthErrorContext.general);

  String toLocalizedMessageInContext(
    BuildContext context,
    AuthErrorContext errorContext,
  );

  /// True when this is a routine, user-correctable outcome (mistyped password,
  /// a stale session, offline) rather than a defect. Catch sites log these as
  /// a breadcrumb instead of a Crashlytics error record — otherwise every user
  /// who fat-fingers a field files a non-fatal issue. The `false` cases are
  /// genuine misconfiguration or bugs and must keep surfacing.
  bool get isExpected => switch (this) {
    AuthFailureInvalidEmail() ||
    AuthFailureUserDisabled() ||
    AuthFailureUserNotFound() ||
    AuthFailureWrongCredentials() ||
    AuthFailureTooManyRequests() ||
    AuthFailureNetwork() ||
    AuthFailureEmailAlreadyInUse() ||
    AuthFailureWeakPassword() ||
    AuthFailureRequiresRecentLogin() ||
    AuthFailureNotAuthorized() ||
    // Both are races rather than defects: a replayed setup call, and a
    // credential that went stale mid-setup. Signing in again fixes either.
    AuthFailureSetupAlreadyComplete() ||
    AuthFailureSessionExpired() ||
    // Choosing the starting password again is an ordinary thing to try,
    // not a defect — the screen asks for a different one and they retype.
    AuthFailureStartingPasswordReused() => true,
    // Console misconfiguration, a rules rejection, an unmapped error, or a
    // signed-in uid with no users doc — all real defects worth a non-fatal.
    AuthFailureOperationNotAllowed() ||
    AuthFailurePermissionDenied() ||
    AuthFailureNoAccountRecord() ||
    AuthFailureUnknown() => false,
  };
}

/// Files an auth failure at the severity [AuthFailure.isExpected] implies:
/// a breadcrumb when expected, a Crashlytics non-fatal otherwise.
extension AuthFailureLogging on AppLogger {
  void authFailure(
    String label,
    AuthFailure failure,
    Object error,
    StackTrace stackTrace,
  ) {
    if (failure.isExpected) {
      breadcrumb('$label (${failure.runtimeType})');
    } else {
      warn(label, error, stackTrace);
    }
  }
}

class AuthFailureInvalidEmail extends AuthFailure {
  const AuthFailureInvalidEmail();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.validation_pleaseEnterAValidEmailAddress;
}

class AuthFailureUserDisabled extends AuthFailure {
  const AuthFailureUserDisabled();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_thisAccountHasBeenDisabled;
}

class AuthFailureUserNotFound extends AuthFailure {
  const AuthFailureUserNotFound();
  @override
  String toLocalizedMessageInContext(
    BuildContext c,
    AuthErrorContext errorContext,
  ) => errorContext == AuthErrorContext.reauthentication
      ? c.l10n.auth_pleaseLogInAgainAndRetry
      : c.l10n.error_noAccountFoundWithThisEmail;
}

class AuthFailureWrongCredentials extends AuthFailure {
  const AuthFailureWrongCredentials();
  @override
  String toLocalizedMessageInContext(
    BuildContext c,
    AuthErrorContext errorContext,
  ) => errorContext == AuthErrorContext.reauthentication
      ? c.l10n.auth_pleaseLogInAgainAndRetry
      : c.l10n.error_invalidEmailOrPassword;
}

class AuthFailureTooManyRequests extends AuthFailure {
  const AuthFailureTooManyRequests();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_tooManyAttemptsPleaseTryAgainLater;
}

class AuthFailureNetwork extends AuthFailure {
  const AuthFailureNetwork();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_networkErrorCheckYourConnectionAndTryAgain;
}

class AuthFailureEmailAlreadyInUse extends AuthFailure {
  const AuthFailureEmailAlreadyInUse();
  @override
  String toLocalizedMessageInContext(
    BuildContext c,
    AuthErrorContext errorContext,
  ) => errorContext == AuthErrorContext.register
      ? c.l10n.error_anAccountWithThisEmailAlreadyExistsSignInOrContactAdmin
      : c.l10n.error_anAccountWithThisEmailAlreadyExists;
}

class AuthFailureWeakPassword extends AuthFailure {
  const AuthFailureWeakPassword();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.validation_passwordIsTooWeakUseAtLeast6Characters;
}

class AuthFailureOperationNotAllowed extends AuthFailure {
  const AuthFailureOperationNotAllowed();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_signInIsTemporarilyUnavailable;
}

class AuthFailureRequiresRecentLogin extends AuthFailure {
  const AuthFailureRequiresRecentLogin();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.auth_pleaseLogInAgainAndRetry;
}

class AuthFailureNotAuthorized extends AuthFailure {
  const AuthFailureNotAuthorized();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_thisEmailIsNotAuthorizedToSignUp;
}

// The account is already `active` — a replayed setup call, or two devices
// finishing at once. Distinct from a real error because the password change
// that precedes it DID land, so the person is not stuck.
class AuthFailureSetupAlreadyComplete extends AuthFailure {
  const AuthFailureSetupAlreadyComplete();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_yourAccountIsAlreadySetUp;
}

// Signed in, but no users doc resolves to this uid. An admin deleted the
// account mid-setup, or provisioning half-failed — either way the person can
// only be helped by their admin.
class AuthFailureNoAccountRecord extends AuthFailure {
  const AuthFailureNoAccountRecord();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_noAccountRecordContactAdmin;
}

// The password they chose IS the starting password the admin issued.
// Detected by [AuthService.completeAccountSetup] reauthenticating with the
// typed value: if that SUCCEEDS it is still the current credential, so
// setup would leave the account active on a password the admin holds.
// Surfaced as a field error on the password, never a banner — it names the
// one field the person has to change.
class AuthFailureStartingPasswordReused extends AuthFailure {
  const AuthFailureStartingPasswordReused();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.validation_passwordMustDifferFromStarting;
}

// The credential went stale mid-setup (token expired, or the write needed a
// recent login). Signing in again is the whole fix.
class AuthFailureSessionExpired extends AuthFailure {
  const AuthFailureSessionExpired();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_sessionExpiredSignInAgain;
}

class AuthFailurePermissionDenied extends AuthFailure {
  const AuthFailurePermissionDenied();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_signInIsTemporarilyUnavailable;
}

class AuthFailureUnknown extends AuthFailure {
  const AuthFailureUnknown();
  @override
  String toLocalizedMessageInContext(BuildContext c, AuthErrorContext _) =>
      c.l10n.error_somethingWentWrongPleaseTryAgain;
}

extension AuthFailureForgotPassword on AuthFailure {
  /// The message to show on the forgot-password screen, or `null` to show the
  /// "check your inbox" panel instead.
  ///
  /// **`null` means "report success", so every member has to be listed.** The
  /// call site treats a null as a sent email, and this switch previously ended
  /// in `_ => null` — which quietly told anyone hitting
  /// `operation-not-allowed` or `permission-denied` that mail was on the way
  /// that would never arrive, and would have swallowed every future member of
  /// the family the same way. Being exhaustive is the point: the compiler now
  /// forces a decision when a member is added.
  String? toForgotPasswordMessage(BuildContext context) {
    return switch (this) {
      // Deliberate silence: naming an address we have no account for turns
      // this screen into an account-existence oracle.
      AuthFailureUserNotFound() => null,
      // Real, actionable outcomes — the reset mail is genuinely not coming.
      AuthFailureInvalidEmail() ||
      AuthFailureUserDisabled() ||
      AuthFailureTooManyRequests() ||
      AuthFailureNetwork() ||
      AuthFailureOperationNotAllowed() ||
      AuthFailureNotAuthorized() ||
      AuthFailurePermissionDenied() => toLocalizedMessageInContext(
        context,
        AuthErrorContext.forgotPassword,
      ),
      // Not reachable from a password-reset request — but "not reachable"
      // must still fail loudly rather than render as a sent email.
      AuthFailureWrongCredentials() ||
      AuthFailureEmailAlreadyInUse() ||
      AuthFailureWeakPassword() ||
      AuthFailureRequiresRecentLogin() ||
      AuthFailureSetupAlreadyComplete() ||
      AuthFailureNoAccountRecord() ||
      AuthFailureSessionExpired() ||
      AuthFailureStartingPasswordReused() ||
      AuthFailureUnknown() =>
        context.l10n.error_somethingWentWrongPleaseTryAgain,
    };
  }
}
