import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_back_button.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// What the sheet hands back: the filter, plus the street of a picked address
/// so the caller can label its chip without watching the building scan.
typedef ClientsFilterPick = ({ClientsFilter filter, String? buildingLabel});

/// The clients list's one filter surface: Type and Shared address as a single
/// radio group.
///
/// ONE group across two sections because [ClientsFilter] is a sealed one-of —
/// picking an address clears a type and vice versa. That constraint was always
/// there; the chip row hid it behind controls that looked independent.
///
/// This is also the ONLY watcher of [clientBuildingsProvider]. Keeping it here
/// rather than in `ClientsListView` is what takes the ~700-doc `orderBy('name')`
/// scan off the clients-tab open — see that provider's own doc comment.
class ClientsFilterSheet extends ConsumerWidget {
  const ClientsFilterSheet({
    required this.selected,
    required this.onChanged,
    required this.onBack,
    super.key,
  });

  final ClientsFilter selected;
  final ValueChanged<ClientsFilterPick> onChanged;

  /// Leaves the sheet reporting NOTHING, so the caller keeps the filter, the
  /// chip label and the list position it already had.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final buildings = ref.watch(clientBuildingsProvider);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: AppSpacing.sp8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sp8,
                AppSpacing.sp4,
                AppSpacing.sp16,
                AppSpacing.sp8,
              ),
              child: Row(
                spacing: AppSpacing.sp8,
                children: [
                  _GhostBack(onTap: onBack),
                  Expanded(
                    child: Text(
                      l10n.clients_filterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineLarge
                          ?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                    ),
                  ),
                ],
              ),
            ),
            _Option(
              label: l10n.clients_filterAll,
              value: const ClientsFilterAll(),
              selected: selected,
              onChanged: onChanged,
            ),
            _SectionHeading(l10n.clients_filterSectionType),
            // Every PICKABLE type, not a hand-listed two: dropping one would
            // make those clients unreachable by filter while their own edit
            // sheet still labels them with it.
            for (final type in ClientType.pickable)
              _Option(
                label: clientTypeLabel(l10n, type),
                value: ClientsFilterType(type),
                selected: selected,
                onChanged: onChanged,
              ),
            _Option(
              label: l10n.clients_filterArchived,
              value: const ClientsFilterArchived(),
              selected: selected,
              onChanged: onChanged,
            ),
            ...buildings.when(
              // The sheet opens immediately; the scan fills this section in.
              loading: () => [
                _SectionHeading(l10n.clients_filterSectionAddress),
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.sp16),
                  child: Center(child: CircularProgressIndicator.adaptive()),
                ),
              ],
              // A failed scan hides the section rather than showing a broken
              // control — the type options above still work.
              error: (_, _) => const <Widget>[],
              data: (list) => list.isEmpty
                  ? const <Widget>[]
                  : [
                      _SectionHeading(l10n.clients_filterSectionAddress),
                      for (final building in list)
                        _Option(
                          label: building.street,
                          secondary: building.city.isEmpty
                              ? null
                              : building.city,
                          trailing: '${building.clientCount}',
                          value: ClientsFilterBuilding(building.key),
                          selected: selected,
                          onChanged: onChanged,
                        ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The sheet's dismiss control, painted as the header's ghost tile.
class _GhostBack extends StatelessWidget {
  const _GhostBack({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GhostControl.wrapping(
      onTap: onTap,
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: scheme.onSurface,
            iconSize: 18,
            padding: EdgeInsets.zero,
            minimumSize: const Size(kGhostTile, kGhostTile),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        child: AppBackButton(onTap: onTap),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.sp16,
      AppSpacing.sp16,
      AppSpacing.sp16,
      AppSpacing.sp4,
    ),
    child: SectionLabel(label),
  );
}

/// One row of the single radio group.
class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.value,
    required this.selected,
    required this.onChanged,
    this.secondary,
    this.trailing,
  });

  final String label;
  final String? secondary;
  final String? trailing;
  final ClientsFilter value;
  final ClientsFilter selected;
  final ValueChanged<ClientsFilterPick> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = selected == value;
    // The chip row's vocabulary at row width: ink fill and a page-colour label
    // when picked, a ghost outline otherwise.
    final ink = isSelected ? theme.scaffoldBackgroundColor : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp16,
        vertical: AppSpacing.sp4,
      ),
      child: Material(
        color: isSelected ? scheme.onSurface : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.rFull),
          side: isSelected
              ? BorderSide.none
              : BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onChanged((
            filter: value,
            buildingLabel: value is ClientsFilterBuilding ? label : null,
          )),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kGhostTapTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: AppSpacing.sp8,
              ),
              child: Row(
                spacing: AppSpacing.sp12,
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isSelected ? ink : theme.palette.textMuted,
                  ),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kFontSans,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: ink,
                          ),
                        ),
                        if (secondary != null)
                          Text(
                            secondary!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isSelected ? ink : scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null)
                    Text(
                      trailing!,
                      style: theme.monoType.data.copyWith(
                        color: isSelected ? ink : theme.palette.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the filter sheet and returns the pick, or null if dismissed.
Future<ClientsFilterPick?> showClientsFilterSheet(
  BuildContext context, {
  required ClientsFilter selected,
}) => showModalBottomSheet<ClientsFilterPick>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) => ClientsFilterSheet(
    selected: selected,
    onChanged: (pick) => Navigator.of(sheetContext).pop(pick),
    onBack: () => Navigator.of(sheetContext).pop(),
  ),
);
