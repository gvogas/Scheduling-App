import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/application/duplicate_phone_check.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/l10n/l10n.dart';

/// "Already on file: Jane Doe — Open / Use anyway", under the add-client phone
/// field while [DuplicatePhoneCheck] holds an unanswered match.
class DuplicatePhoneNotice extends StatelessWidget {
  const DuplicatePhoneNotice({
    required this.check,
    required this.onOpen,
    super.key,
  });

  final DuplicatePhoneCheck check;
  final ValueChanged<ClientRecord> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: check,
      builder: (context, _) {
        final match = check.match;
        if (match == null || check.acknowledged) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final status = theme.statusColors;
        final l10n = context.l10n;
        return Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sp8),
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sp12,
              AppSpacing.sp8,
              AppSpacing.sp8,
              AppSpacing.sp8,
            ),
            decoration: BoxDecoration(
              color: status.warningContainer,
              borderRadius: BorderRadius.circular(AppRadius.r12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.person_search_outlined,
                  size: 16,
                  color: status.onWarningContainer,
                ),
                const SizedBox(width: AppSpacing.sp8),
                Expanded(
                  child: Text(
                    l10n.clients_alreadyOnFile(match.displayName),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: status.onWarningContainer,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => onOpen(match),
                  child: Text(l10n.clients_openExistingClient),
                ),
                TextButton(
                  onPressed: check.useAnyway,
                  child: Text(l10n.clients_useAnyway),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
