import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/l10n/l10n.dart';

/// One line above the list: what the list is showing on the left, the order on
/// the right.
class ClientsListHeader extends StatelessWidget {
  const ClientsListHeader({
    required this.count,
    required this.sort,
    required this.onSortChanged,
    super.key,
    this.filter = const ClientsFilterAll(),
  });

  /// Null while the first page is still settling — an unknown count renders
  /// nothing rather than a misleading zero, the same rule the row's job count
  /// follows.
  final int? count;

  /// Which slice the count is describing, so the sentence can name it.
  final ClientsFilter filter;

  final ClientsSort sort;
  final ValueChanged<ClientsSort> onSortChanged;

  static String sortLabel(AppLocalizations l10n, ClientsSort sort) =>
      switch (sort) {
        ClientsSort.name => l10n.clients_sortByName,
        ClientsSort.mostJobs => l10n.clients_sortMostJobs,
        ClientsSort.recentlyAdded => l10n.clients_sortRecentlyAdded,
      };

  String _countSentence(AppLocalizations l10n) {
    final total = count;
    if (total == null) return '';
    return switch (filter) {
      ClientsFilterAll() => l10n.clients_showingAll(total),
      ClientsFilterType(:final type) => l10n.clients_showingType(
        total,
        clientTypeLabel(l10n, type),
      ),
      ClientsFilterArchived() => l10n.clients_showingType(
        total,
        l10n.clients_filterArchived,
      ),
      ClientsFilterBuilding() => l10n.clients_inThisBuilding(total),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Padding(
      // The chip row's gutter plus the same 4px optical inset the group
      // headings carry, so the three lines share one left edge.
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        0,
        AppSpacing.sp16,
        AppSpacing.sp8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _countSentence(l10n),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.palette.textTertiary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Flexible, not a fixed child: at 260px with 2x text the count and
          // the sort label together exceed the row, so both must be allowed to
          // ellipsize rather than one overflowing.
          Flexible(
            child: PopupMenuButton<ClientsSort>(
              tooltip: l10n.clients_sort,
              initialValue: sort,
              onSelected: onSortChanged,
              itemBuilder: (context) => [
                for (final option in ClientsSort.values)
                  PopupMenuItem<ClientsSort>(
                    value: option,
                    child: Text(sortLabel(l10n, option)),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sp4,
                  vertical: AppSpacing.sp8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 5,
                  children: [
                    Icon(
                      Icons.sort_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurface,
                    ),
                    Flexible(
                      child: Text(
                        sortLabel(l10n, sort),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kFontSans,
                          fontSize: 12.5,
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
        ],
      ),
    );
  }
}
