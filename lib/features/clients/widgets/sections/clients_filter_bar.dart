import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// How wide the active building chip's label may grow before it ellipsizes. An
/// unbounded street ("1200 Rue Sherbrooke Ouest") would otherwise push the
/// scrolling chips off the row entirely.
const double _maxChipLabelWidth = 160;

/// The Filter button, pinned FIRST and outside the scroller, then the filter
/// chips scrolling horizontally beside it.
///
/// Pinned because the button is the only way to reach the addresses and the
/// full sheet, so it must never be the control that scrolls off. The chips
/// cover the fixed vocabulary — [ClientType.pickable] plus Archived — which is
/// short enough to scroll through; an address is discovered from the data and
/// there can be dozens, so a [ClientsFilterBuilding] shows as one removable
/// chip instead of getting a chip of its own.
class ClientsFilterBar extends StatelessWidget {
  const ClientsFilterBar({
    required this.selected,
    required this.onOpen,
    required this.onClear,
    required this.onSelect,
    this.activeBuildingLabel,
    super.key,
  });

  final ClientsFilter selected;
  final VoidCallback onOpen;

  /// Clears the active filter — the building chip's only action.
  final VoidCallback onClear;

  /// Picks one of the chip filters. Addresses stay the sheet's to offer.
  final ValueChanged<ClientsFilter> onSelect;

  /// Street of the active [ClientsFilterBuilding], remembered by the caller
  /// when it was picked — this bar never watches the building scan.
  final String? activeBuildingLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final gutter = context.isCompact ? AppSpacing.sp8 : AppSpacing.sp16;
    final building = selected is ClientsFilterBuilding
        ? (activeBuildingLabel ?? l10n.clients_filterByAddress)
        : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        AppSpacing.sp4,
        gutter,
        AppSpacing.sp8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : (MediaQuery.sizeOf(context).width - gutter * 2).clamp(
                  0.0,
                  double.infinity,
                );
          return SizedBox(
            width: width,
            child: Row(
              spacing: AppSpacing.sp8,
              children: [
                _FilterButton(
                  isActive: selected is! ClientsFilterAll,
                  onPressed: onOpen,
                  tooltip: l10n.clients_filter,
                ),
                if (building != null)
                  Flexible(
                    child: _BuildingChip(label: building, onClear: onClear),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: AppSpacing.sp8,
                      children: _chips(l10n),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _chips(AppLocalizations l10n) => [
    _FilterChip(
      label: l10n.clients_filterAll,
      selected: selected is ClientsFilterAll,
      onTap: () => onSelect(const ClientsFilterAll()),
    ),
    for (final type in ClientType.pickable)
      _FilterChip(
        label: clientTypeLabel(l10n, type),
        selected: selected == ClientsFilterType(type),
        onTap: () => onSelect(ClientsFilterType(type)),
      ),
    _FilterChip(
      label: l10n.clients_filterArchived,
      selected: selected is ClientsFilterArchived,
      onTap: () => onSelect(const ClientsFilterArchived()),
    ),
  ];
}

/// The round ghost control that opens the filter sheet, dotted while any
/// filter is on.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.isActive,
    required this.onPressed,
    required this.tooltip,
  });

  final bool isActive;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => GhostControl.icon(
    onTap: onPressed,
    icon: Icons.tune,
    tooltip: tooltip,
    tone: GhostTone.accent,
    iconSize: 18,
    showBadge: isActive,
  );
}

/// One scrolling filter chip: ink fill with a page-colour label when it is the
/// active one, a ghost outline otherwise.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GhostControl.pill(
    onTap: onTap,
    label: label,
    tone: selected ? GhostTone.selected : GhostTone.ghost,
  );
}

/// The active address filter, as a tinted chip whose only action is to clear.
class _BuildingChip extends StatelessWidget {
  const _BuildingChip({required this.label, required this.onClear});

  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kGhostTapTarget),
      child: Center(
        child: Material(
          color: scheme.primaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.rFull),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: AppSpacing.sp4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _maxChipLabelWidth,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kFontSans,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onClear,
                  tooltip: context.l10n.clients_clearFilter,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  color: scheme.onPrimaryContainer,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
