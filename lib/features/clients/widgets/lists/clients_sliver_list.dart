import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/floating_controls.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/client_grouping.dart';

/// The grouped Clients rows: a heading over each run, the run itself inside one
/// white card, divided row from row.
///
/// The card is a [DecoratedSliver] around a `SliverList` rather than a
/// `Container` around a `Column`, so a group stays lazily built — a single
/// "one card" group can hold every loaded row, and under a type filter every
/// client of that type.
class ClientsSliverList extends StatelessWidget {
  const ClientsSliverList({
    required this.groups,
    required this.itemBuilder,
    super.key,
    this.footer,
    this.onRowBuilt,
  });

  final List<ClientGroup> groups;

  /// Builds one row by its GLOBAL index, so the first-row tour wrap and the
  /// pager's prefetch both key off one index rather than a per-group one.
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// The paged list's spinner or retry row. Null on the unpaginated paths.
  final Widget? footer;

  /// Fired with the global row index as each row builds — the prefetch trigger.
  final void Function(int index)? onRowBuilt;

  /// Gap between a heading and the card under it.
  static const double _headingGap = AppSpacing.sp8;

  /// Gap between one group and the next.
  static const double _groupGap = 14;

  /// The card's own corners, on the END rows only: [DecoratedSliver] does not
  /// clip, and a row is a square `Material` + `InkWell`.
  static Widget _clipEndRows(Widget row, int index, int count) {
    final isFirst = index == 0;
    final isLast = index == count - 1;
    if (!isFirst && !isLast) return row;
    const corner = Radius.circular(AppRadius.r12);
    return ClipRRect(
      borderRadius: BorderRadius.vertical(
        top: isFirst ? corner : Radius.zero,
        bottom: isLast ? corner : Radius.zero,
      ),
      child: row,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp12),
      child: CustomScrollView(
        slivers: [
          for (var g = 0; g < groups.length; g++)
            SliverMainAxisGroup(
              slivers: [
                if (groups[g].heading != null)
                  SliverToBoxAdapter(
                    child: _GroupHeading(label: groups[g].heading!),
                  ),
                DecoratedSliver(
                  decoration: appCardDecoration(
                    theme,
                    color: theme.colorScheme.surface,
                  ),
                  sliver: SliverList.separated(
                    itemCount: groups[g].length,
                    itemBuilder: (context, index) {
                      final global = groups[g].start + index;
                      onRowBuilt?.call(global);
                      return _clipEndRows(
                        itemBuilder(context, global),
                        index,
                        groups[g].length,
                      );
                    },
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      thickness: 1,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
                if (g < groups.length - 1)
                  const SliverToBoxAdapter(child: SizedBox(height: _groupGap)),
              ],
            ),
          SliverToBoxAdapter(
            child: Padding(
              // The host floats a FAB and a back-to-top button over this list.
              padding: const EdgeInsets.only(
                bottom: kFloatingControlsClearance,
              ),
              child: footer ?? const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The letter — or, under a building filter, the street — over one card.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    // The 4 is the optical inset that lines this up with the chip row's gutter
    // over the list's own sp12.
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.sp4,
      AppSpacing.sp4,
      AppSpacing.sp4,
      ClientsSliverList._headingGap,
    ),
    child: Text(
      label.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).monoType.label,
    ),
  );
}
