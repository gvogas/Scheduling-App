import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/app_language.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/features/presence/widgets/live_map_labels.dart';
import 'package:scheduling/features/presence/widgets/staff_focus_panel.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/status_pill.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

const double kTeamSheetMinSize = 0.14;
const double kTeamSheetRestSize = 0.48;
const double kTeamSheetMaxSize = 0.86;

/// The admin map's team list, under the map and dragged up for more.
class LiveMapTeamSheet extends StatelessWidget {
  const LiveMapTeamSheet({
    required this.team,
    required this.now,
    required this.selfDocId,
    required this.selected,
    required this.scrollController,
    required this.onSelect,
    required this.onCloseSelection,
    this.headerTourWrap,
    super.key,
  });

  final LiveMapTeam team;
  final DateTime now;
  final String? selfDocId;
  final StaffMapPoint? selected;
  final ScrollController scrollController;
  final ValueChanged<StaffMapPoint> onSelect;
  final VoidCallback onCloseSelection;
  final Widget Function(Widget child)? headerTourWrap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final ordered = LiveMapAggregator.sortedByProximity(
      team.onMap,
      selfDocId: selfDocId,
    );
    final self = ordered.where((p) => p.userDocId == selfDocId).firstOrNull;
    double? distanceTo(StaffMapPoint p) =>
        self == null || p.userDocId == self.userDocId
        ? null
        : LiveMapAggregator.distanceMeters(self.lat, self.lng, p.lat, p.lng);
    final focus = selected;
    final others = [
      for (final p in ordered)
        if (p.userDocId != focus?.userDocId) p,
    ];
    final header = _TeamHeader(
      onMapCount: team.onMap.length,
      offMapCount: team.offMapCount,
    );
    const radius = BorderRadius.vertical(top: Radius.circular(AppRadius.r20));

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: radius,
        boxShadow: theme.cardStyle.sheetShadow,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.sp16,
            ),
            children: [
              headerTourWrap?.call(header) ?? header,
              if (focus != null) ...[
                StaffFocusPanel(
                  point: focus,
                  now: now,
                  distanceMeters: distanceTo(focus),
                  onClose: onCloseSelection,
                ),
                if (others.isNotEmpty)
                  _SectionLabel(l10n.liveMap_sectionAlsoNearby, others.length),
              ] else if (others.isNotEmpty)
                _SectionLabel(l10n.liveMap_sectionOnMap, others.length),
              for (final (i, point) in others.indexed) ...[
                if (i > 0) const _RowDivider(),
                _OnMapRow(
                  point: point,
                  now: now,
                  isSelf: point.userDocId == selfDocId,
                  distanceMeters: distanceTo(point),
                  onTap: () => onSelect(point),
                ),
              ],
              if (team.notSeen.isNotEmpty) ...[
                _SectionLabel(l10n.liveMap_sectionNotSeen, team.notSeen.length),
                for (final (i, absence) in team.notSeen.indexed) ...[
                  if (i > 0) const _RowDivider(),
                  _AbsenceRow(
                    absence: absence,
                    subtitle: l10n.liveMap_noFixYet,
                  ),
                ],
              ],
              if (team.sharingOff.isNotEmpty) ...[
                _SectionLabel(
                  l10n.liveMap_sectionSharingOff,
                  team.sharingOff.length,
                ),
                for (final (i, absence) in team.sharingOff.indexed) ...[
                  if (i > 0) const _RowDivider(),
                  _AbsenceRow(
                    absence: absence,
                    subtitle: l10n.liveMap_sharingOffRow,
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sp16,
                    AppSpacing.sp12,
                    AppSpacing.sp16,
                    0,
                  ),
                  child: Text(
                    l10n.liveMap_sharingOffFooter,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.palette.textTertiary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TeamHeader extends StatelessWidget {
  const _TeamHeader({required this.onMapCount, required this.offMapCount});

  final int onMapCount;
  final int offMapCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp8,
        AppSpacing.sp16,
        AppSpacing.sp4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpacing.sp8),
              decoration: BoxDecoration(
                color: theme.palette.decorFaint,
                borderRadius: BorderRadius.circular(AppRadius.rFull),
              ),
            ),
          ),
          Text(
            l10n.liveMap_teamTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.sp4),
          Text(
            '${l10n.liveMap_teamOnMapCount(onMapCount)} · '
            '${l10n.liveMap_teamOffMapCount(offMapCount)}',
            style: theme.monoType.data.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, this.count);

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp16,
        AppSpacing.sp16,
        AppSpacing.sp4,
      ),
      child: Text(
        '${label.toUpperCase()} · $count',
        style: theme.monoType.groupLabel.copyWith(
          color: theme.palette.textTertiary,
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: 64,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

/// A pin on the map: tapping it focuses the person.
class _OnMapRow extends ConsumerWidget {
  const _OnMapRow({
    required this.point,
    required this.now,
    required this.isSelf,
    required this.distanceMeters,
    required this.onTap,
  });

  final StaffMapPoint point;
  final DateTime now;
  final bool isSelf;
  final double? distanceMeters;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final geo = ref.watch(
      reverseGeocodeProvider(
        ReverseGeocodeQuery(
          lat: point.lat,
          lng: point.lng,
          locale: serverLocaleOf(Localizations.localeOf(context).languageCode),
        ),
      ),
    );
    // "No location" only once the geocode has settled with nothing usable.
    final place =
        LiveMapAggregator.cityFromAddress(geo.value) ??
        (geo.isLoading ? l10n.liveMap_locatingCity : l10n.liveMap_noLocation);
    return _TeamRowFrame(
      name: point.name,
      color: point.color,
      faded: LiveMapAggregator.isStale(point.updatedAt, now),
      isSelf: isSelf,
      subtitle: '$place · ${freshnessLabel(l10n, point.updatedAt, now)}',
      trailing: distanceMeters == null
          ? null
          : distanceLabel(context, distanceMeters!),
      onTap: onTap,
    );
  }
}

/// A teammate with no pin — there is nothing to open, so it is not tappable.
class _AbsenceRow extends StatelessWidget {
  const _AbsenceRow({required this.absence, required this.subtitle});

  final StaffAbsence absence;
  final String subtitle;

  @override
  Widget build(BuildContext context) => _TeamRowFrame(
    name: absence.name,
    color: absence.color,
    faded: true,
    isSelf: false,
    subtitle: subtitle,
  );
}

class _TeamRowFrame extends StatelessWidget {
  const _TeamRowFrame({
    required this.name,
    required this.color,
    required this.faded,
    required this.isSelf,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final String name;
  final Color color;
  final bool faded;
  final bool isSelf;
  final String subtitle;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sp16,
          vertical: AppSpacing.sp8,
        ),
        child: Row(
          children: [
            Opacity(
              opacity: faded ? 0.5 : 1,
              child: AppAvatar(name: name, color: color),
            ),
            const SizedBox(width: AppSpacing.sp12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isSelf) ...[
                        const SizedBox(width: AppSpacing.sp8),
                        StatusPill(
                          label: context.l10n.liveMap_you,
                          background: theme.colorScheme.primary.withValues(
                            alpha: theme.cardStyle.iconChipAlpha,
                          ),
                          foreground: theme.palette.primaryAccent,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.palette.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sp8),
              Text(
                trailing!,
                style: theme.monoType.data.copyWith(
                  color: theme.palette.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
