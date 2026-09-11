import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/launchers/phone_call_launcher.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_month_grid.dart';
import 'package:scheduling/features/clients/email_compose_launcher.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';
import 'package:scheduling/features/employees/widgets/cards/employee_profile_card.dart';
import 'package:scheduling/features/employees/widgets/sections/employee_today_section.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/key_value_panel.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';
import 'package:scheduling/shared/widgets/primitives/quick_action_button.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

class EmployeeDetailsView extends ConsumerWidget {
  const EmployeeDetailsView({
    required this.employee,
    required this.isCurrentUserAdmin,
    required this.onEdit,
    super.key,
    this.scrollController,
    this.showHandle = false,
    this.bottomPadding = 24,
  });

  final EmployeeRecord employee;
  final bool isCurrentUserAdmin;

  /// Disable/enable moved into the edit sheet and delete was withdrawn, so
  /// Edit is the only action this surface can raise.
  final VoidCallback onEdit;
  final ScrollController? scrollController;
  final bool showHandle;
  final double bottomPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

    // Handlers built here (where `ref` lives) so the widgets stay
    // presentational. Both delegate to launchExternalUri.
    final onCall = employee.phone.isEmpty
        ? null
        : () => launchPhoneCall(context, ref, employee.phone);
    final onEmail = employee.email.isEmpty
        ? null
        : () => EmailComposeLauncher.showEmailChoices(
            context,
            ref,
            email: employee.email,
          );

    // Its own document (users/{id}/private/emergency), gated by rules to an
    // admin and the person themselves. Team is admin-only, so a viewer here
    // always passes that rule and a failed read means the read failed - not
    // that there is none on file. If this view is ever reused on a non-admin
    // surface it must distinguish the two, the way MyDetailsScreen does.
    //
    // Loading and error deliberately render the SAME thing here (the panel is
    // omitted below when the rows are empty), which is what "not shown" means
    // on a read-only surface. The failure itself is not swallowed: the
    // provider logs it once per error emission.
    final emergency =
        ref.watch(emergencyContactProvider(employee.id)).value ??
        EmergencyContact.empty;
    final onCallEmergency = emergency.phone.isEmpty
        ? null
        : () => launchPhoneCall(context, ref, emergency.phone);

    return DetailSheetListView(
      scrollController: scrollController,
      showHandle: showHandle,
      bottomPadding: bottomPadding,
      children: [
        EmployeeProfileCard(
          employee: employee,
          onEdit: isCurrentUserAdmin ? onEdit : null,
        ),
        ..._quickActions(l10n, onCall: onCall, onEmail: onEmail),
        ..._panels(
          l10n,
          _emergencyRows(l10n, emergency, onCall: onCallEmergency),
          _infoRows(context, onCall: onCall, onEmail: onEmail),
        ),
        EmployeeTodaySection(
          employeeId: employee.id,
          onJobTap: (appointmentId) =>
              _openJob(context, ref, appointmentId, employee.id),
        ),
      ],
    );
  }

  /// Hours, days, cap and access level, plus the two contact rows when there
  /// is something behind them.
  List<KeyValueRow> _infoRows(
    BuildContext context, {
    VoidCallback? onCall,
    VoidCallback? onEmail,
  }) {
    final l10n = context.l10n;
    final materialL10n = MaterialLocalizations.of(context);
    final hoursValue = employee.workingDays.contains(true)
        ? '${materialL10n.formatTimeOfDay(minutesToTimeOfDay(employee.workStartMinutes))}'
              ' – '
              '${materialL10n.formatTimeOfDay(minutesToTimeOfDay(employee.workEndMinutes))}'
        : l10n.employees_noWorkingDays;

    return [
      if (employee.phone.isNotEmpty)
        KeyValueRow(
          label: l10n.employees_phoneKey,
          value: employee.phone,
          onTap: onCall,
          emphasize: true,
        ),
      if (employee.email.isNotEmpty)
        KeyValueRow(
          label: l10n.employees_emailKey,
          value: employee.email,
          onTap: onEmail,
          emphasize: true,
        ),
      KeyValueRow(label: l10n.employees_hoursKey, value: hoursValue),
      // Approved design: days are a phrase here, not a seven-cell strip. The
      // grid lives only in the edit sheet, where tapping a day is the point.
      KeyValueRow(
        label: l10n.employees_daysKey,
        value: formatWorkingDays(
          l10n,
          employee.workingDays,
          weekStart: CalendarMonthGrid.weekStartOf(context),
          labels: weekdayAbbreviationsForLocale(
            Localizations.localeOf(context).toString(),
          ),
        ),
      ),
      // No "No cap" row here, unlike the two edit surfaces: this is a
      // read-only body, which omits empty sections rather than rendering a
      // placeholder - an uncapped person has no daily cap to report.
      if (employee.maxJobsPerDay > 0)
        KeyValueRow(
          label: l10n.employees_maxPerDayKey,
          value: l10n.employees_jobsPerDay(employee.maxJobsPerDay),
        ),
      // No `ON CALL` row - the profile card carries it as a chip, and a row
      // here would state the same boolean twice on one screen.
      KeyValueRow(
        label: l10n.employees_accessKey,
        value: employee.isAdmin
            ? l10n.common_admin
            : l10n.common_employeeRoleValue,
      ),
    ];
  }

  /// Its own panel, not two more rows in the block above: who to call if
  /// something goes wrong on site is a different question from someone's hours
  /// and access level, and it is the one you scan for in a hurry.
  List<KeyValueRow> _emergencyRows(
    AppLocalizations l10n,
    EmergencyContact emergency, {
    VoidCallback? onCall,
  }) => [
    if (emergency.contact.isNotEmpty)
      KeyValueRow(label: l10n.employees_emergencyKey, value: emergency.contact),
    if (emergency.phone.isNotEmpty)
      KeyValueRow(
        label: l10n.employees_emergencyPhoneKey,
        value: emergency.phone,
        onTap: onCall,
        emphasize: true,
      ),
  ];

  /// Opens the appointment sheet for the tapped card. `showActions` carries
  /// the caller's resolved role - never `true`.
  void _openJob(
    BuildContext context,
    WidgetRef ref,
    String appointmentId,
    String employeeId,
  ) {
    final jobs = ref.read(employeeTodayJobsProvider(employeeId));
    for (final job in jobs) {
      if (job.id == appointmentId) {
        showEventDetails(
          context,
          job,
          analyticsSource: AnalyticsSources.employees,
          showActions: isCurrentUserAdmin,
        );
        return;
      }
    }
  }

  /// Only the buttons whose data exists - a tile with nothing behind it is
  /// worse than no tile.
  List<Widget> _quickActions(
    AppLocalizations l10n, {
    VoidCallback? onCall,
    VoidCallback? onEmail,
  }) => [
    if (onCall != null || onEmail != null) ...[
      const SizedBox(height: AppSpacing.sp16),
      QuickActionsRow(
        buttons: [
          if (onCall != null)
            QuickActionButton(
              icon: Icons.phone_outlined,
              label: l10n.clients_call,
              onTap: onCall,
            ),
          if (onEmail != null)
            QuickActionButton(
              icon: Icons.mail_outline,
              label: l10n.common_email,
              onTap: onEmail,
            ),
        ],
      ),
    ],
    const SizedBox(height: AppSpacing.sp24),
  ];

  List<Widget> _panels(
    AppLocalizations l10n,
    List<KeyValueRow> emergencyRows,
    List<KeyValueRow> infoRows,
  ) => [
    KeyValuePanel(rows: infoRows),
    if (emergencyRows.isNotEmpty) ...[
      const SizedBox(height: AppSpacing.sp24),
      MonoSectionLabel(l10n.employees_sectionEmergency),
      const SizedBox(height: AppSpacing.sp8),
      KeyValuePanel(rows: emergencyRows),
    ],
    const SizedBox(height: AppSpacing.sp24),
  ];
}
