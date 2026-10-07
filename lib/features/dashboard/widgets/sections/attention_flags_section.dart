import 'package:flutter/material.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/dashboard/application/dashboard_providers.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/widgets/fields/work_schedule_pickers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// Pending-soon and never-closed visits, rendered with the shared [AppointmentCard].
class AttentionFlagsSection extends StatelessWidget {
  const AttentionFlagsSection({
    required this.flags,
    required this.colorMap,
    required this.nameMap,
    required this.isAdmin,
    super.key,
    this.neverSetUp = const [],
    this.availabilityConflicts = const [],
  });

  final AttentionFlags flags;
  final Map<String, Color> colorMap;
  final Map<String, String> nameMap;

  /// Accounts created but never set up — the person still holds the shared
  /// starting password. Tapping one lands on the Team roster, where the
  /// pending row owns Reset password and Remove.
  final List<EmployeeRecord> neverSetUp;

  /// Staff holding booked work on a weekday they are marked unavailable for.
  final List<AvailabilityConflict> availabilityConflicts;

  /// Gates the admin-only Edit/Cancel/Delete actions on the sheet a card opens.
  final bool isAdmin;

  bool get _isAllClear =>
      flags.isAllClear && neverSetUp.isEmpty && availabilityConflicts.isEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColors = theme.statusColors;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(l10n.dashboard_attentionFlags),
        const SizedBox(height: AppSpacing.sp8),
        if (_isAllClear)
          Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: statusColors.success,
              ),
              const SizedBox(width: AppSpacing.sp8),
              Expanded(
                child: Text(
                  l10n.dashboard_allClear,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          )
        else ...[
          if (flags.pendingSoon.isNotEmpty)
            _FlagGroup(
              title: l10n.dashboard_pendingSoonHeader(flags.pendingSoon.length),
              appointments: flags.pendingSoon,
              colorMap: colorMap,
              nameMap: nameMap,
              isAdmin: isAdmin,
            ),
          if (flags.pendingSoon.isNotEmpty && flags.overdueOpen.isNotEmpty)
            const SizedBox(height: AppSpacing.sp16),
          if (flags.overdueOpen.isNotEmpty)
            _FlagGroup(
              title: l10n.dashboard_overdueOpenHeader(flags.overdueOpen.length),
              appointments: flags.overdueOpen,
              colorMap: colorMap,
              nameMap: nameMap,
              isAdmin: isAdmin,
            ),
          if (neverSetUp.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sp16),
            _PeopleGroup(
              title: l10n.dashboard_neverSetUpHeader(neverSetUp.length),
              rows: [
                for (final person in neverSetUp)
                  (name: person.name, detail: person.email),
              ],
            ),
          ],
          if (availabilityConflicts.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sp16),
            _PeopleGroup(
              title: l10n.dashboard_availabilityConflictHeader(
                availabilityConflicts.length,
              ),
              rows: [
                for (final conflict in availabilityConflicts)
                  (
                    name: conflict.employee.name,
                    detail: l10n.dashboard_availabilityConflictDays(
                      joinWeekdayNames(context, conflict.days),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

typedef _PersonRow = ({String name, String detail});

/// A flag group whose rows are people rather than jobs.
class _PeopleGroup extends StatelessWidget {
  const _PeopleGroup({required this.title, required this.rows});

  final String title;
  final List<_PersonRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sp8),
        Container(
          decoration: appCardDecoration(
            theme,
            color: theme.colorScheme.surface,
          ),
          padding: const EdgeInsets.all(AppSpacing.sp12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.sp8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        rows[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sp8),
                    Flexible(
                      child: Text(
                        rows[i].detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FlagGroup extends StatelessWidget {
  const _FlagGroup({
    required this.title,
    required this.appointments,
    required this.colorMap,
    required this.nameMap,
    required this.isAdmin,
  });

  final String title;
  final List<AppointmentRecord> appointments;
  final Map<String, Color> colorMap;
  final Map<String, String> nameMap;

  /// Gates the admin-only actions on the sheet a card opens.
  final bool isAdmin;

  /// How many cards this group renders, however many the reducer found.
  ///
  /// The `overdueOpen` reducer deliberately has NO range predicate — a job that
  /// went overdue nine weeks ago still needs closing — so this list is the only
  /// unbounded one on the screen, and it was spread into a plain `Column` inside
  /// a `ListView(children:)`: nothing lazy, every card built AND laid out on the
  /// first frame, each with its own `IntrinsicHeight` pass, re-paid on every live
  /// snapshot and every period-control tap. The COUNT is what matters here and
  /// the group's title already carries it (`dashboard_overdueOpenHeader`), so
  /// only the render is capped — the same shape as `NewClientsSection.rowLimit`.
  static const int rowLimit = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = appointments.take(rowLimit).toList();
    final hidden = appointments.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sp8),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sp8),
          AppointmentCard(
            appointment: shown[i],
            crew: crewFor(shown[i], colorMap: colorMap, nameMap: nameMap),
            onTap: () => showEventDetails(
              context,
              shown[i],
              analyticsSource: AnalyticsSources.dashboard,
              showActions: isAdmin,
            ),
          ),
        ],
        if (hidden > 0) ...[
          const SizedBox(height: AppSpacing.sp8),
          Text(
            context.l10n.dashboard_andMoreVisits(hidden),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
