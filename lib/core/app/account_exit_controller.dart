import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:scheduling/shared/widgets/feedback/error_snack_bar.dart';

final accountExitControllerProvider = Provider<AccountExitController>(
  (ref) => AccountExitController(
    logger: ref.read(loggerProvider),
    authService: ref.read(authServiceProvider),
    deregisterDevice: () =>
        deregisterThisDevice(DeviceDeregistrationDeps.from(ref.read)),
    isSignedIn: () => ref.read(firebaseAuthProvider).currentUser != null,
    sessionForExit: () => ref.read(sessionFenceProvider),
    pendingPhotoCount: () => ref
        .read(photoUploadNotifierProvider)
        .pending
        .value
        .values
        .fold<int>(0, (sum, count) => sum + count),
  ),
);

/// Orchestrates a forced sign-out caused by server-side account changes.
///
/// Detection stays in listeners; teardown, navigation, and the reentrancy guard
/// live here so every forced-exit path shares one owner.
class AccountExitController {
  AccountExitController({
    required AppLogger logger,
    required AuthService authService,
    required Future<void> Function() deregisterDevice,
    required bool Function() isSignedIn,
    SessionFence Function()? sessionForExit,
    int Function()? pendingPhotoCount,
  }) : _logger = logger,
       _authService = authService,
       _deregisterDevice = deregisterDevice,
       _isSignedIn = isSignedIn,
       _sessionForExit = sessionForExit,
       _pendingPhotoCount = pendingPhotoCount;

  final AppLogger _logger;
  final AuthService _authService;
  final Future<void> Function() _deregisterDevice;
  final bool Function() _isSignedIn;
  final SessionFence Function()? _sessionForExit;
  final int Function()? _pendingPhotoCount;
  bool _isHandlingAccountExit = false;
  bool _isVoluntaryTeardown = false;
  Future<void> Function()? _blockedForcedExit;

  /// Holds the forced-exit guard across a voluntary exit's [teardown], so the
  /// two never interleave; false (nothing run) when an exit already holds it.
  /// A forced exit it blocked replays afterwards: its signal never re-fires.
  Future<bool> runVoluntaryTeardown(Future<void> Function() teardown) async {
    if (_isHandlingAccountExit) return false;
    _isHandlingAccountExit = true;
    _isVoluntaryTeardown = true;
    try {
      await teardown();
      return true;
    } finally {
      _isHandlingAccountExit = false;
      _isVoluntaryTeardown = false;
      final blocked = _blockedForcedExit;
      _blockedForcedExit = null;
      if (blocked != null && _isSignedIn()) unawaited(blocked());
    }
  }

  /// De-registers this device, signs out, and lands on login with a notice.
  ///
  /// The order matters: push, presence and Live Activity registration are all
  /// torn down BEFORE `signOut()`, because each needs the credential that
  /// sign-out revokes. Each is best-effort; a failure there must not block the
  /// sign-out, which is the part that actually protects the user.
  Future<void> exitAccount({
    required String Function(AppLocalizations) selectMessage,
    required GlobalKey<NavigatorState> navigatorKey,
    required GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey,
    required bool Function() isMounted,
  }) async {
    if (_isHandlingAccountExit) {
      if (_isVoluntaryTeardown) {
        _blockedForcedExit = () => exitAccount(
          selectMessage: selectMessage,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          isMounted: isMounted,
        );
      }
      return;
    }
    if (!_isSignedIn()) return;

    final navContext = navigatorKey.currentContext;
    if (navContext == null) return;
    _isHandlingAccountExit = true;

    var exitScheduled = false;
    SessionFence? session;
    SessionLease? lease;
    try {
      final l10n = AppLocalizations.of(navContext);
      final message = [
        selectMessage(l10n),
        if ((_pendingPhotoCount?.call() ?? 0) > 0) l10n.auth_forcedExitPhotos,
      ].join(' ');
      session = _sessionForExit?.call();
      lease = session?.beginExit();
      await _deregisterDevice();
      if (lease != null && !lease.isCurrent) return;
      await _authService.signOut();
      if (!isMounted() || _authService.currentUser != null) return;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!isMounted() || _authService.currentUser != null) {
          _isHandlingAccountExit = false;
          return;
        }
        final messengerContext = scaffoldMessengerKey.currentContext;
        navigatorKey.currentState?.pushNamedAndRemoveUntil(
          AppRoutes.login,
          (_) => false,
        );
        scaffoldMessengerKey.currentState?.showSnackBar(
          errorSnackBar(messengerContext ?? navContext, message),
        );
        _isHandlingAccountExit = false;
      });
      WidgetsBinding.instance.scheduleFrame();
      exitScheduled = true;
    } catch (e, st) {
      _logger.warn('ACCOUNT-EXIT sign-out failed', e, st);
      if (lease?.isCurrent == true) session?.resume();
    } finally {
      if (!exitScheduled) _isHandlingAccountExit = false;
    }
  }
}
