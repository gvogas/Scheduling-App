import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_action_sheet.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/launchers/external_uri_launcher.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Bottom-sheet chooser for composing email (system mail app, Gmail, or Outlook).
class EmailComposeLauncher {
  const EmailComposeLauncher._();

  static Future<void> showEmailChoices(
    BuildContext context,
    WidgetRef ref, {
    required String email,
  }) async {
    final address = email.trim();
    if (address.isEmpty) return;
    final encoded = Uri.encodeComponent(address);

    final options = <_EmailOption>[
      _EmailOption(
        label: context.l10n.clients_defaultMailApp,
        icon: Icons.mail_outline,
        uri: Uri(scheme: 'mailto', path: address),
      ),
      _EmailOption(
        label: context.l10n.clients_gmail,
        icon: Icons.email_outlined,
        uri: Uri.parse(
          'https://mail.google.com/mail/?view=cm&fs=1&to=$encoded',
        ),
      ),
      _EmailOption(
        label: context.l10n.clients_outlook,
        icon: Icons.email_outlined,
        uri: Uri.parse(
          'https://outlook.office.com/mail/deeplink/compose?to=$encoded',
        ),
      ),
    ];

    final errorMessage = context.l10n.error_couldNotOpenEmail;

    final chosen = await showAdaptiveActionSheet<Uri>(
      context,
      title: context.l10n.clients_emailWith,
      message: address,
      actions: [
        for (final option in options)
          AdaptiveSheetAction(
            value: option.uri,
            label: option.label,
            icon: option.icon,
          ),
      ],
    );

    if (chosen == null || !context.mounted) return;
    await launchExternalUri(
      context,
      ref,
      chosen,
      tag: 'LAUNCH-EMAIL',
      analyticsAction: AnalyticsContactActions.email,
      errorMessage: errorMessage,
    );
  }
}

class _EmailOption {
  const _EmailOption({
    required this.label,
    required this.icon,
    required this.uri,
  });
  final String label;
  final IconData icon;
  final Uri uri;
}
