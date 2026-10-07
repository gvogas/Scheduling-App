import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Body content for the delete-account confirm dialog.
class DeleteAccountWarningContent extends StatelessWidget {
  const DeleteAccountWarningContent({required this.isAdmin, super.key});

  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.settings_deleteAccountConfirmBody),
        if (isAdmin) ...[
          const SizedBox(height: AppSpacing.sp12),
          Text(
            context.l10n.settings_deleteAccountAdminWarning,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}
