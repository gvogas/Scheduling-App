import 'package:flutter/material.dart';

import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/calendar/data/appointment_image_upload_service.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

Future<PendingPhotoExit?> confirmPendingPhotoExit(
  BuildContext context,
  AppointmentImageUploadService uploads,
  SessionFence session,
) async {
  final lease = session.capture();
  if (lease == null) return null;
  final pending = await uploads.prepareForExit();
  var approved = false;
  try {
    if (!context.mounted || !lease.isCurrent || !pending.isCurrent) return null;
    if (pending.pendingCount > 0) {
      final discard = await showConfirmDialog(
        context,
        title: context.l10n.account_pendingPhotosTitle,
        message: context.l10n.account_pendingPhotosBody(pending.pendingCount),
        cancelLabel: context.l10n.account_stayAndRetryPhotos,
        confirmLabel: context.l10n.account_discardPhotosAndContinue,
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
