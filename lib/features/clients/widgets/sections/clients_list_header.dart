import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// One line above the list: what the list is showing on the left, the order on
/// the right.
class ClientsListHeader extends StatelessWidget {
  const ClientsListHeader({
    required this.count,
    required this.sort,
    required this.onSortChanged,
    super.key,
    this.filter = const ClientsFilterAll(),
    this.total,
    this.isSearching = false,
    this.leading,
    this.onClearFilter,
    this.sortWrap,
  });

  /// Null while the first page is still settling — an unknown count renders
  /// nothing rather than a misleading zero, the same rule the row's job count
  /// follows.
  final int? count;

  /// The roster size, when it is known and larger than [count] — the list
  /// pages, so the rows it holds are not "all" of anything until they are.
  /// Null when no separate total has been fetched for the selected filter.
  final int? total;

  /// True while a search narrows the unfiltered list: [count] is its matches.
  final bool isSearching;

  /// Which slice the count is describing, so the sentence can name it.
  final ClientsFilter filter;

  final ClientsSort sort;
  final ValueChanged<ClientsSort> onSortChanged;

  /// The Filter control, which shares this row rather than owning one of its
  /// own — the sentence beside it already names whatever it has narrowed to.
  final Widget? leading;

  /// Clears the active filter. The ✕ renders only while one is on.
  final VoidCallback? onClearFilter;

  /// Wraps the sort control for the feature tour. A wrapper rather than a
  /// wrapped header: the Filter button arrives pre-wrapped in its own step,
  /// and a showcase inside a showcase does not resolve.
  final Widget Function(Widget child)? sortWrap;

  static String sortLabel(AppLocalizations l10n, ClientsSort sort) =>
      switch (sort) {
        ClientsSort.name => l10n.clients_sortByName,
        ClientsSort.mostJobs => l10n.clients_sortMostJobs,
        ClientsSort.recentlyAdded => l10n.clients_sortRecentlyAdded,
      };

  String _countSentence(AppLocalizations l10n) {
    final shown = count;
    if (shown == null) return '';
    final roster = total;
    return switch (filter) {
      ClientsFilterAll() when isSearching => l10n.clients_searchMatches(shown),
      ClientsFilterAll() when roster != null && shown < roster =>
        l10n.clients_showingSome(shown, roster),
      ClientsFilterAll() => l10n.clients_showingAll(shown),
      ClientsFilterType(:final type) => l10n.clients_showingType(
        shown,
        clientTypeLabel(l10n, type),
      ),
      ClientsFilterArchived() => l10n.clients_showingType(
        shown,
        l10n.clients_filterArchived,
      ),
      ClientsFilterBuilding() => l10n.clients_inThisBuilding(shown),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    final clear = onClearFilter;
    return Padding(
      // The same gutter and 4px optical inset the group headings carry, so the
      // list's lines share one left edge.
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        0,
        AppSpacing.sp16,
        AppSpacing.sp8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: AppSpacing.sp8),
              ],
              Expanded(
                child: Text(
                  _countSentence(l10n),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (clear != null && filter is! ClientsFilterAll)
                IconButton(
                  onPressed: clear,
                  tooltip: l10n.clients_clearFilter,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                  icon: const Icon(Icons.close),
                ),
              // Bounded rather than flexible: a Flexible here splits the free
              // space with the sentence's Expanded 50/50, which both truncated the
              // sentence and left the control floating mid-row instead of pinned
              // to the end. The cap is what keeps a long label from taking the
              // whole row at large text.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width * 0.55),
                child: _wrapSort(
                  _SortPill(sort: sort, onSortChanged: onSortChanged),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _wrapSort(Widget child) => sortWrap?.call(child) ?? child;
}

/// The sort control: a popup menu behind a ghost-tile-styled trigger.
class _SortPill extends StatelessWidget {
  const _SortPill({required this.sort, required this.onSortChanged});

  final ClientsSort sort;
  final ValueChanged<ClientsSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return PopupMenuButton<ClientsSort>(
      tooltip: l10n.clients_sort,
      initialValue: sort,
      onSelected: onSortChanged,
      color: theme.colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      itemBuilder: (context) => [
        for (final option in ClientsSort.values)
          PopupMenuItem<ClientsSort>(
            value: option,
            child: _SortOption(option: option, picked: option == sort),
          ),
      ],
      // The Filter button's vocabulary, painted rather than built
      // from GhostControl: the popup owns the tap, and a second
      // InkWell inside it would fight for the same gesture.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kGhostTapTarget),
        child: Center(
          widthFactor: 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: kGhostTile),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.rFull),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: AppSpacing.sp8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                Icon(
                  Icons.sort_rounded,
                  size: 15,
                  color: theme.colorScheme.onSurface,
                ),
                Flexible(
                  child: Text(
                    ClientsListHeader.sortLabel(l10n, sort),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kFontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the sort menu: the order's own glyph, its name, and a check on
/// the one in force — so the picked option is never colour alone.
class _SortOption extends StatelessWidget {
  const _SortOption({required this.option, required this.picked});

  final ClientsSort option;
  final bool picked;

  static IconData _glyph(ClientsSort sort) => switch (sort) {
    ClientsSort.name => Icons.sort_by_alpha_rounded,
    ClientsSort.mostJobs => Icons.leaderboard_rounded,
    ClientsSort.recentlyAdded => Icons.schedule_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.palette.primaryAccent;
    final tint = picked ? accent : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(_glyph(option), size: 18, color: tint),
        const SizedBox(width: AppSpacing.sp12),
        Expanded(
          child: Text(
            ClientsListHeader.sortLabel(context.l10n, option),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: picked ? accent : theme.colorScheme.onSurface,
              fontWeight: picked ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
        if (picked) ...[
          const SizedBox(width: AppSpacing.sp8),
          Icon(Icons.check_rounded, size: 18, color: accent),
        ],
      ],
    );
  }
}
