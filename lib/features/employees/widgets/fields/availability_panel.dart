import 'package:flutter/material.dart';

import 'package:scheduling/core/adaptive/adaptive_pickers.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';
import 'package:scheduling/features/employees/widgets/fields/working_days_picker.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel_row.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';

/// Signature of an availability edit.
///
/// Every value travels together so the write is ONE patch: the rules' `hasOnly`
/// is satisfied by the key set, not by which of them actually changed, so
/// sending a partial patch would buy nothing and fork the save path.
typedef AvailabilityChanged =
    void Function(
      List<bool> workingDays,
      int workStartMinutes,
      int workEndMinutes, {
      required bool onCall,
    });

/// The working days / hours / on-call panel, shared by the admin's Team sheet
/// and Settings › My details.
///
/// One widget because the two screens must render this panel IDENTICALLY, and
/// hand-mirroring had already drifted twice: My details picked its times with a
/// raw `showTimePicker` while the Team sheet used [showAdaptiveTimePicker] — so
/// the same row opened a Material dialog on one screen and a Cupertino wheel on
/// the other — and the two disagreed on whether a time reads as a mono numeral.
/// Numerals are mono app-wide, so mono wins.
///
/// The panel owns the pickers; the host owns the state and decides what a
/// change MEANS (an immediate optimistic write on My details, a staged edit
/// behind Save on the Team sheet).
class AvailabilityPanel extends StatelessWidget {
  const AvailabilityPanel({
    required this.workingDays,
    required this.workStartMinutes,
    required this.workEndMinutes,
    required this.onCall,
    required this.onChanged,
    super.key,
    this.hoursErrorText,
    this.maxJobsRow,
    this.onCallKey,
  });

  final List<bool> workingDays;
  final int workStartMinutes;
  final int workEndMinutes;
  final bool onCall;

  final AvailabilityChanged onChanged;

  /// Validation message under the end-time row.
  final String? hoursErrorText;

  /// The admin-only `maxJobsPerDay` row, appended before on-call.
  ///
  /// A slot rather than a value + callback: that field is NOT on the
  /// self-service allowlist, so it is written through a different save path
  /// entirely and does not belong in [onChanged]'s one patch.
  final Widget? maxJobsRow;

  final Key? onCallKey;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);

    return SheetPanel(
      children: [
        SheetPanelRow(
          label: l10n.employees_workingDays,
          child: WorkingDaysPicker(
            workingDays: workingDays,
            onChanged: (next) => onChanged(
              next,
              workStartMinutes,
              workEndMinutes,
              onCall: onCall,
            ),
          ),
        ),
        _buildStartRow(context, l10n, materialL10n),
        _buildEndRow(context, l10n, materialL10n),
        ?maxJobsRow,
        SheetPanelRow(
          label: l10n.employees_onCall,
          trailing: Switch.adaptive(
            key: onCallKey,
            value: onCall,
            activeTrackColor: theme.colorScheme.primary,
            onChanged: (value) => onChanged(
              workingDays,
              workStartMinutes,
              workEndMinutes,
              onCall: value,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStartRow(
    BuildContext context,
    AppLocalizations l10n,
    MaterialLocalizations materialL10n,
  ) {
    return SheetFieldRow(
      label: l10n.employees_startsAt,
      value: materialL10n.formatTimeOfDay(minutesToTimeOfDay(workStartMinutes)),
      useMonoValue: true,
      accent: true,
      onTap: () => _pickTime(
        context,
        initial: workStartMinutes,
        onPicked: (minutes) =>
            onChanged(workingDays, minutes, workEndMinutes, onCall: onCall),
      ),
    );
  }

  Widget _buildEndRow(
    BuildContext context,
    AppLocalizations l10n,
    MaterialLocalizations materialL10n,
  ) {
    return SheetFieldRow(
      label: l10n.employees_endsAt,
      value: materialL10n.formatTimeOfDay(minutesToTimeOfDay(workEndMinutes)),
      useMonoValue: true,
      accent: true,
      errorText: hoursErrorText,
      onTap: () => _pickTime(
        context,
        initial: workEndMinutes,
        onPicked: (minutes) =>
            onChanged(workingDays, workStartMinutes, minutes, onCall: onCall),
      ),
    );
  }

  /// The adaptive picker every other time field in the app uses — a Cupertino
  /// wheel on iOS, Material elsewhere.
  Future<void> _pickTime(
    BuildContext context, {
    required int initial,
    required ValueChanged<int> onPicked,
  }) async {
    final picked = await showAdaptiveTimePicker(
      context,
      initialTime: minutesToTimeOfDay(initial),
    );
    if (picked == null) return;
    onPicked(timeOfDayToMinutes(picked));
  }
}
