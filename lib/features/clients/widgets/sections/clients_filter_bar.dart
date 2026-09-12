import 'package:flutter/material.dart';

import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// The round Filter button that opens the filter sheet, dotted while any
/// filter is on.
///
/// It had a row of its own carrying a per-type chip each (removed, owner call
/// 2026-09-11 — the sheet already offers every one of them) and then a chip
/// naming the active filter (removed with it): the button now sits in the
/// list header's row, where the count sentence beside it already names
/// whatever it has narrowed to and a ✕ clears it.
class ClientsFilterBar extends StatelessWidget {
  const ClientsFilterBar({
    required this.selected,
    required this.onOpen,
    super.key,
  });

  final ClientsFilter selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => GhostControl.icon(
    onTap: onOpen,
    icon: Icons.tune,
    tooltip: context.l10n.clients_filter,
    tone: GhostTone.accent,
    iconSize: 18,
    showBadge: selected is! ClientsFilterAll,
  );
}
