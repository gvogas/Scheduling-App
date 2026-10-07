import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Cancel/confirm dialog — Cupertino on iOS, Material on Android.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String? message,
  Widget? content,
  bool destructive = true,
  String? cancelLabel,
}) async {
  assert(message != null || content != null, 'message or content is required');
  final bool? result;
  if (context.isCupertino) {
    result = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: content ?? Text(message!),
        actions: [
          CupertinoDialogAction(
            // On iOS, destructive actions default focus to the Cancel
            // button — that's the platform convention.
            isDefaultAction: destructive,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel ?? ctx.l10n.common_cancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  } else {
    result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final palette = Theme.of(ctx).palette;
        return AlertDialog(
          title: Text(title),
          content: content ?? Text(message!),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(cancelLabel ?? ctx.l10n.common_cancel),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      // Not scheme.error — in dark that is the lifted
                      // foreground red, unusable as a white-text fill.
                      backgroundColor: palette.dangerFill,
                      foregroundColor: palette.onDangerFill,
                    )
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }
  final confirmed = result ?? false;
  // Haptic feedback for destructive confirms.
  if (confirmed && destructive) unawaited(HapticFeedback.mediumImpact());
  return confirmed;
}
