import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_pill.dart';

/// "Archived", as a neutral pill — on the list row and the detail profile card.
class ArchivedPill extends StatelessWidget {
  const ArchivedPill({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StatusPill(
      label: context.l10n.clients_filterArchived,
      background: scheme.surfaceContainerHighest,
      foreground: scheme.onSurfaceVariant,
      radius: AppRadius.r8,
    );
  }
}
