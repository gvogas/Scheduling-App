import 'package:flutter/material.dart';

import 'package:scheduling/core/analytics/analytics_service.dart';
import 'package:scheduling/core/app/device_deregistration.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/auth/services/auth_service.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

/// Asks whether to discard [pendingCount] unsaved photos; true = discard.
typedef PendingPhotoPrompt = Future<bool> Function(int pendingCount);

/// Returns null when the exit should quietly not proceed; [prompt] replaces
/// the dialog for a surface that must ask inline (the app-lock overlay).
Future<PendingPhotoExit?> confirmPendingPhotoExit(
  BuildContext context,
  AppointmentImageUploadService uploads,
  SessionFence session, {
  PendingPhotoPrompt? prompt,
}) async {
  final lease = session.capture();
  if (lease == null) return null;
  final pending = await uploads.prepareForExit();
  if (pending == null) return null;
  var approved = false;
  try {
    if (!context.mounted || !lease.isCurrent || !pending.isCurrent) return null;
    if (pending.pendingCount > 0) {
      final discard = prompt != null
          ? await prompt(pending.pendingCount)
          : await showConfirmDialog(
              context,
              title: context.l10n.auth_pendingPhotosTitle,
              message: context.l10n.auth_pendingPhotosBody(
                pending.pendingCount,
              ),
              cancelLabel: context.l10n.auth_stayAndRetryPhotos,
              confirmLabel: context.l10n.auth_discardPhotosAndContinue,
            );
      if (!discard ||
          !context.mounted ||
          !lease.isCurrent ||
          !pending.isCurrent) {
        return null;
      }
    }
    approved = true;
    return pending;
  } finally {
    if (!approved) pending.resume();
  }
}

/// The photo hold the caller releases after its exit.
typedef CheckedDeviceExit = ({PendingPhotoExit? pendingExit});

/// Photo check, then [deregisterThisDevice]; null (hold released) on any bail-out.
Future<CheckedDeviceExit?> exitDevicesAfterPhotoCheck(
  BuildContext context,
  DeviceDeregistrationDeps devices,
) async {
  final pendingExit = await confirmPendingPhotoExit(
    context,
    devices.imageUploads,
    devices.session!,
  );
  if (pendingExit == null || !pendingExit.isCurrent) {
    pendingExit?.resume();
    return null;
  }
  var handedOver = false;
  try {
    await deregisterThisDevice(devices);
    if (!devices.isCurrentExit) return null;
    handedOver = true;
    return (pendingExit: pendingExit);
  } finally {
    if (!handedOver) pendingExit.resume();
  }
}

/// Runs a voluntary exit's teardown exclusively; false when another exit holds it.
typedef ExitTeardownGuard =
    Future<bool> Function(Future<void> Function() teardown);

Future<bool> _unguarded(Future<void> Function() teardown) async {
  await teardown();
  return true;
}

/// The photo choice stays OUTSIDE [guard], so a forced exit arriving while the
/// person decides still runs. A failed `signOut` restores the device INSIDE
/// [guard], before any forced exit it blocked replays, and is rethrown for the
/// caller's `ACCT-SIGNOUT` log and notice.
Future<bool> signOutAfterPhotoCheck(
  BuildContext context,
  DeviceDeregistrationDeps devices,
  AuthService auth,
  AnalyticsService analytics, {
  bool checkPendingPhotos = true,
  PendingPhotoPrompt? prompt,
  ExitTeardownGuard guard = _unguarded,
}) async {
  PendingPhotoExit? pendingExit;
  if (checkPendingPhotos) {
    pendingExit = await confirmPendingPhotoExit(
      context,
      devices.imageUploads,
      devices.session!,
      prompt: prompt,
    );
    if (pendingExit == null || !pendingExit.isCurrent) {
      pendingExit?.resume();
      return false;
    }
  }
  var signedOut = false;
  try {
    final ran = await guard(() async {
      await deregisterThisDevice(devices);
      if (!devices.isCurrentExit) return;
      try {
        await auth.signOut();
      } catch (_) {
        await restoreThisDevice(devices);
        rethrow;
      }
      signedOut = auth.currentUser == null;
    });
    if (!ran || !signedOut) return false;
    // Never `resetAnalyticsData`; clear `user_role` instead (ADR-0165).
    analytics
      ..logSignOut()
      ..setUserRole(null);
    return true;
  } finally {
    pendingExit?.resume();
  }
}

/// An exit's hold on the upload queue, released by [resume].
class PendingPhotoExit {
  const PendingPhotoExit({
    required this.pendingCount,
    this.onResume,
    this.readCurrent,
  });

  final int pendingCount;
  final void Function()? onResume;
  final bool Function()? readCurrent;

  bool get isCurrent => readCurrent?.call() ?? true;

  void resume() => onResume?.call();
}
