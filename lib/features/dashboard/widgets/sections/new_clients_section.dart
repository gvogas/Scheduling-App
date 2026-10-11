import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';
import 'package:scheduling/features/dashboard/domain/new_client_trend.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// Clients added over the dashboard window: a headline figure with how it
/// compares to the window before it, an 8-week sparkline, and the most recent
/// few as tappable rows.
///
/// **The form is a stat tile, not a chart.** The question this card answers is
/// "how many, and is that more or less than usual" — one number plus a
/// direction — so the number leads and the bars are context behind it. The
/// weekly bars used to be the whole answer, unlabelled and at the same visual
/// weight as the trends chart directly above (which already plots these same
/// buckets), which left the reader deriving the count by eye from eight bars
/// that carried no scale.
///
/// Archived clients are already excluded upstream (`newClientsProvider`): the
/// dashboard answers *what should I look at now*, and an archived client is
/// one you decided not to look at.
class NewClientsSection extends StatelessWidget {
  const NewClientsSection({
    required this.clients,
    required this.weeklyCounts,
    super.key,
  });

  /// Newest first.
  final List<ClientRecord> clients;

  /// One count per week bucket, oldest first — the same buckets the trends
  /// chart uses.
  final List<int> weeklyCounts;

  /// Enough to show momentum without turning the dashboard into the clients
  /// list, which is one tap away.
  static const int rowLimit = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    final trend = newClientTrend(weeklyCounts);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l10n.dashboard_newClients),
        const SizedBox(height: AppSpacing.sp8),
        Container(
          decoration: appCardDecoration(theme, color: scheme.surface),
          padding: const EdgeInsets.all(AppSpacing.sp16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Headline(trend: trend, weeks: weeklyCounts.length),
              // A window with nothing in it draws a flat line that says
              // nothing, so it isn't drawn at all — the empty line below says
              // it in words instead.
              if (!trend.isEmpty) ...[
                const SizedBox(height: AppSpacing.sp12),
                Semantics(
                  label:
                      '${l10n.dashboard_newClients}: '
                      '${l10n.dashboard_newClientsWindow(weeklyCounts.length)}',
                  child: ExcludeSemantics(
                    child: NewClientSparkline(
                      values: weeklyCounts,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sp4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    l10n.dashboard_newClientsThisWeek,
                    style: theme.monoType.micro.copyWith(
                      color: theme.palette.textMuted,
                    ),
                  ),
                ),
              ],
              _ClientRows(clients: clients),
            ],
          ),
        ),
      ],
    );
  }
}

/// The sample of new clients under the sparkline, or the empty line in its
/// place. Split out to keep [NewClientsSection.build] near the ~60-line
/// guideline, and it needs nothing but the list.
class _ClientRows extends StatelessWidget {
  const _ClientRows({required this.clients});

  final List<ClientRecord> clients;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;

    if (clients.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sp12),
        child: Text(
          l10n.dashboard_newClientsEmpty,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // Built once per rebuild, never per row: constructing a DateFormat
    // verifies the locale and parses a skeleton, and doing that inside an item
    // builder is what made the calendar build 30-90 of them per frame.
    final dateFormat = DateFormat.MMMd(
      Localizations.localeOf(context).toString(),
    );
    final overflow = clients.length - NewClientsSection.rowLimit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.sp12),
          child: Divider(height: 1),
        ),
        for (final client in clients.take(NewClientsSection.rowLimit))
          _NewClientRow(client: client, dateFormat: dateFormat),
        // The rows are a sample, not the set — without this the card silently
        // reports five when twenty came in.
        if (overflow > 0)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp8),
            child: Text(
              l10n.dashboard_newClientsMore(overflow),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// The figure the card leads with, and the direction beside it.
class _Headline extends StatelessWidget {
  const _Headline({required this.trend, required this.weeks});

  final NewClientTrend trend;
  final int weeks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${trend.total}',
                key: const ValueKey('new-clients-total'),
                style: theme.monoType.numeralKpi,
              ),
              const SizedBox(height: AppSpacing.sp4),
              Text(
                l10n.dashboard_newClientsWindow(weeks),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (trend.hasComparison) ...[
          const SizedBox(width: AppSpacing.sp8),
          _TrendChip(trend: trend),
        ],
      ],
    );
  }
}

/// "▲ 3" — the recent half of the window against the half before it.
///
/// The number is never the only carrier: the arrow gives the direction a
/// shape, and the whole chip speaks its comparison in full to a screen reader,
/// because "3" beside a headline of "12" is otherwise unreadable.
class _TrendChip extends StatelessWidget {
  const _TrendChip({required this.trend});

  final NewClientTrend trend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = theme.statusColors;
    final delta = trend.delta;
    final weeks = trend.halfWeeks;

    final (
      IconData icon,
      Color fill,
      Color ink,
      String description,
    ) = switch (delta) {
      > 0 => (
        Icons.trending_up_rounded,
        status.successContainer,
        status.onSuccessContainer,
        context.l10n.dashboard_newClientsTrendUp(delta, weeks),
      ),
      < 0 => (
        Icons.trending_down_rounded,
        status.neutralContainer,
        status.onNeutralContainerMuted,
        context.l10n.dashboard_newClientsTrendDown(-delta, weeks),
      ),
      _ => (
        Icons.trending_flat_rounded,
        status.neutralContainer,
        status.onNeutralContainer,
        context.l10n.dashboard_newClientsTrendFlat(weeks),
      ),
    };

    return Semantics(
      label: description,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sp8,
            vertical: AppSpacing.sp4,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppRadius.rFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: ink),
              const SizedBox(width: AppSpacing.sp4),
              Text(
                '${delta.abs()}',
                style: theme.monoType.data.copyWith(color: ink),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewClientRow extends StatelessWidget {
  const _NewClientRow({required this.client, required this.dateFormat});

  final ClientRecord client;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = context.isCompact;
    final date = Text(
      dateFormat.format(client.createdAt!),
      style: theme.monoType.data.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    return InkWell(
      onTap: () => showClientDetailSheet(context, client),
      borderRadius: BorderRadius.circular(AppRadius.r8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp8),
        child: Row(
          children: [
            AppAvatar(name: client.displayName, size: AvatarSize.sm),
            const SizedBox(width: AppSpacing.sp12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    client.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (compact) date,
                ],
              ),
            ),
            if (!compact) ...[const SizedBox(width: AppSpacing.sp8), date],
          ],
        ),
      ),
    );
  }
}

/// The weekly buckets behind the headline, in the EMPHASIS form: the current
/// week carries the accent and the weeks behind it recede to a tint of the
/// same hue. One hue, never a second colour — these bars are context for one
/// number, not a set of series to tell apart.
///
/// Public because the section owns it now but the trends card rendered it
/// first — one copy, not two.
class NewClientSparkline extends StatelessWidget {
  const NewClientSparkline({
    required this.values,
    required this.color,
    super.key,
  });

  final List<int> values;
  final Color color;

  static const double _height = 44;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var maxValue = 0;
    for (final v in values) {
      if (v > maxValue) maxValue = v;
    }
    final lastIndex = values.length - 1;
    // Recessive, same hue: the bars behind the current week are context.
    final pastColor = color.withValues(alpha: 0.28);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: SizedBox(
                      // A zero week still paints a 2px stub rather than
                      // nothing: an absent bar reads as missing data, and the
                      // difference between "no clients that week" and "we have
                      // no figure" is the whole point of the baseline.
                      height: maxValue == 0
                          ? 2
                          : (_height * values[i] / maxValue).clamp(2, _height),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: i == lastIndex ? color : pastColor,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // The baseline the bars stand on — without it a short bar floats.
        Container(height: 1, color: theme.colorScheme.outlineVariant),
      ],
    );
  }
}
