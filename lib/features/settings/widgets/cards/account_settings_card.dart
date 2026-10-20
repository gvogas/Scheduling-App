import 'package:flutter/material.dart';

import 'package:scheduling/features/settings/widgets/cards/settings_tiles.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The sign-out row, styled as an ordinary action: a daily step, not a danger.
/// Deleting the account lives in `DeleteAccountCard` at the foot of Settings.
class AccountSettingsCard extends StatelessWidget {
  const AccountSettingsCard({
    required this.onSignOut,
    this.isBusy = false,
    super.key,
  });

  final VoidCallback onSignOut;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsSectionCard(
      child: SettingsTile(
        iconBg: scheme.primaryContainer,
        icon: Icons.logout_rounded,
        iconColor: scheme.primary,
        label: context.l10n.settings_logOut,
        onTap: isBusy ? null : onSignOut,
      ),
    );
  }
}
