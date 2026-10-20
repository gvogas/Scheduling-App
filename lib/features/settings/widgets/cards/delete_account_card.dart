import 'package:flutter/material.dart';

import 'package:scheduling/features/settings/widgets/cards/settings_tiles.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The one destructive row in Settings, kept last and on its own so it is
/// never one tap away from Log out.
class DeleteAccountCard extends StatelessWidget {
  const DeleteAccountCard({
    required this.onDeleteAccount,
    this.isBusy = false,
    super.key,
  });

  final VoidCallback onDeleteAccount;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsSectionCard(
      child: SettingsTile(
        iconBg: scheme.errorContainer,
        icon: Icons.delete_forever_rounded,
        iconColor: scheme.error,
        label: context.l10n.settings_deleteAccount,
        labelColor: scheme.error,
        onTap: isBusy ? null : onDeleteAccount,
      ),
    );
  }
}
