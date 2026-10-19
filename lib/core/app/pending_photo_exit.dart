import 'package:flutter/material.dart';

import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

/// Returns null when the exit should quietly not proceed.
Future<PendingPhotoExit?> confirmPendingPhotoExit(
  BuildContext context,
  AppointmentImageUploadService uploads,
  SessionFence session,
) async {
  final lease = session.capture();
  if (lease == null) return null;
  final pending = await uploads.prepareForExit();
  if (pending == null) return null;
  var approved = false;
  try {
    if (!context.mounted || !lease.isCurrent || !pending.isCurrent) return null;
    if (pending.pendingCount > 0) {
      final discard = await showConfirmDialog(
        context,
        title: context.l10n.auth_pendingPhotosTitle,
        message: context.l10n.auth_pendingPhotosBody(pending.pendingCount),
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
