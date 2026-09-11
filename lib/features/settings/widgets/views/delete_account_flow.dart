import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/features/auth/services/account_deletion_service.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/settings/widgets/dialogs/delete_account_dialog.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

/// The two account-exit flows Settings owns: sign out, and the irreversible
/// account deletion behind its confirm + re-auth pair.
///
/// They share a teardown order that must not drift — [deregisterThisDevice]
/// while the credential is still live, then the exit itself, then
/// `pushNamedAndRemoveUntil` to login — so they live together, off a screen
/// State that already carries app-lock lifecycle and the notification toggles.
mixin DeleteAccountFlow<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The service the deletion runs through — injectable by the host so a test
  /// can hand in a fake.
  AccountDeletionService get deletionService;

  /// Whether the signed-in person is an admin; only the warning copy differs.
  bool get isAdminAccount;

  bool _isSigningOut = false;
  bool _isConfirmingDeleteAccount = false;
  bool _isDeletingAccount = false;

  /// True while the irreversible deletion runs — the host blocks the UI on it.
  bool get isDeletingAccount => _isDeletingAccount;
  bool get isAccountExitBusy =>
      _isSigningOut || _isConfirmingDeleteAccount || _isDeletingAccount;

  Future<void> signOut() async {
    if (isAccountExitBusy) return;
    // Resolved before the de-registration round-trips: `ref.read` throws on an
    // unmounted consumer (Riverpod 3), and this catch is what guarantees the
    // user still reaches login rather than being stranded signed in.
    final logger = ref.read(loggerProvider);
    final authService = ref.read(authServiceProvider);
    final notices = ref.read(noticeServiceProvider);
    final analytics = ref.read(analyticsServiceProvider);
    setState(() => _isSigningOut = true);
    // Holds the deps once the teardown has actually run, so the rollback in
    // the catch below reuses THEM instead of reading `ref` again — see
    // [restoreThisDevice]. Non-null is exactly "there is something to roll
    // back", which is why it replaces a separate bool.
    DeviceDeregistrationDeps? deregistered;
    try {
      // Clean up this device's push token, presence, and Live Activity state
      // — best effort, so a failure here doesn't block sign-out. The ORDER is
      // owned by `deregisterThisDevice`; all three exits share it.
      final devices = DeviceDeregistrationDeps.from(ref.read);
      await deregisterThisDevice(devices);
      deregistered = devices;
      await authService.signOut();
      // After the sign-out lands — the catch below rolls the device state back
      // and leaves the person signed IN, which is not a sign-out.
      //
      // `resetAnalyticsData` is deliberately NOT called: it would mint a new
      // app instance id, and retention ("do people come back?") is measured
      // against that id. `user_role` is cleared instead — here rather than
      // waiting for `AnalyticsIdentityListener`, so nothing logged between
      // this call and the doc emptying carries the old role.
      analytics
        ..logSignOut()
        ..setUserRole(null);
    } catch (e, st) {
      logger.warn('ACCT-SIGNOUT signOut failed', e, st);
      if (deregistered != null) await restoreThisDevice(deregistered);
      if (!mounted) return;
      setState(() => _isSigningOut = false);
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introSignOut,
          error: e,
        ),
      );
      return;
    }
    if (!mounted) return;
    try {
      await Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.login,
        (_) => false,
      );
    } catch (e, st) {
      logger.warn('ACCT-SIGNOUT navigation failed', e, st);
      if (!mounted) return;
      setState(() => _isSigningOut = false);
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introSignOut,
          error: e,
        ),
      );
    }
  }

  Future<void> confirmDeleteAccount() async {
    if (isAccountExitBusy) return;
    // Bail out early if we're offline — otherwise the call just hangs for ~30s.
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introDeleteAccount,
    )) {
      return;
    }
    _isConfirmingDeleteAccount = true;
    try {
      final result = await showConfirmDialog(
        context,
        title: context.l10n.settings_deleteAccountConfirmTitle,
        confirmLabel: context.l10n.settings_deletePermanently,
        content: DeleteAccountWarningContent(isAdmin: isAdminAccount),
      );
      if (!result || !mounted) return;

      // Match the platform presentation of the adaptive confirm dialog shown before this.
      final password = context.isCupertino
          ? await showCupertinoDialog<String>(
              context: context,
              builder: (dialogContext) => const DeleteAccountReauthDialog(),
            )
          : await showDialog<String>(
              context: context,
              builder: (dialogContext) => const DeleteAccountReauthDialog(),
            );
      if (password == null || password.isEmpty || !mounted) return;

      await _runDeletion(password);
    } finally {
      _isConfirmingDeleteAccount = false;
    }
  }

  Future<void> _runDeletion(String password) async {
    setState(() => _isDeletingAccount = true);
    final notices = ref.read(noticeServiceProvider);
    final logger = ref.read(loggerProvider);
    // See [restoreThisDevice]: holding the deps is what lets both catch arms
    // roll back without touching `ref` after these round-trips.
    DeviceDeregistrationDeps? deregistered;
    try {
      await deletionService.reauthenticateWithPassword(password);
      // Drop this device's registrations while still authenticated, before
      // deleteAccount revokes access — same shared order as the other exits.
      final devices = DeviceDeregistrationDeps.from(ref.read);
      await deregisterThisDevice(devices);
      deregistered = devices;
      await deletionService.deleteAccount();
    } on AuthFailure catch (e, st) {
      // Logged before the mounted guard: this fires AFTER push, presence and
      // the Live Activity have already de-registered, so a half-torn-down
      // account must leave a trace. `authFailure` keeps a user-correctable
      // wrong password a breadcrumb and records the rest.
      logger.authFailure('ACCT-DEL settings.delete_account', e, e, st);
      if (deregistered != null) await restoreThisDevice(deregistered);
      if (!mounted) return;
      setState(() => _isDeletingAccount = false);
      // Reauthentication context, not the default: every AuthFailure that can
      // land here comes from `reauthenticateWithPassword`, where "no account
      // found with this email" describes an address the person never typed.
      // The re-auth leg says "please log in again and retry" instead.
      notices.error(
        e.toLocalizedMessageInContext(
          context,
          AuthErrorContext.reauthentication,
        ),
      );
      return;
    } catch (e, st) {
      logger.warn('ACCT-DEL settings.delete_account', e, st);
      if (deregistered != null) await restoreThisDevice(deregistered);
      if (!mounted) return;
      setState(() => _isDeletingAccount = false);
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introDeleteAccount,
          error: e,
        ),
      );
      return;
    }
    if (!mounted) return;
    final message = context.l10n.settings_accountDeleted;
    try {
      await Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.login,
        (_) => false,
      );
      notices.success(message);
    } catch (e, st) {
      // The account is already gone; only the route swap failed. Reporting an
      // error here would name a failure for an operation that committed, so
      // the honest notice is still the success one and the nav failure is
      // log-only.
      logger.warn('ACCT-DEL navigation failed', e, st);
      if (!mounted) return;
      setState(() => _isDeletingAccount = false);
      notices.success(message);
    }
  }
}
