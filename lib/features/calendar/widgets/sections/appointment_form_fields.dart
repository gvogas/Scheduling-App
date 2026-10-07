import 'package:flutter/material.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/calendar/domain/assignee_availability.dart';
import 'package:scheduling/features/calendar/domain/models/job_template.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/calendar/domain/policies/appointment_form_validator.dart';
import 'package:scheduling/features/calendar/utils/appointment_draft_defaults.dart';
import 'package:scheduling/features/calendar/utils/appointment_form_error_text.dart';
import 'package:scheduling/features/calendar/widgets/fields/appointment_date_rows.dart';
import 'package:scheduling/features/calendar/widgets/fields/appointment_status_picker.dart';
import 'package:scheduling/features/calendar/widgets/fields/employee_picker.dart';
import 'package:scheduling/features/calendar/widgets/fields/repeat_interval_picker.dart';
import 'package:scheduling/features/calendar/widgets/sections/job_address_section.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_status.dart';
import 'package:scheduling/features/clients/widgets/cards/selected_client_card.dart';
import 'package:scheduling/features/clients/widgets/fields/client_picker.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/fields/form_helpers.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

/// Text controllers shared by add and edit appointment forms.
class AppointmentFormControllers {
  const AppointmentFormControllers({
    required this.title,
    required this.date,
    required this.endDate,
    required this.startTime,
    required this.endTime,
    required this.clientSearch,
    required this.address,
    required this.notes,
    required this.materials,
  });

  final TextEditingController title;
  final TextEditingController date;
  final TextEditingController endDate;
  final TextEditingController startTime;
  final TextEditingController endTime;
  final TextEditingController clientSearch;
  final TextEditingController address;
  final TextEditingController notes;
  final TextEditingController materials;

  /// Disposes every owned controller. Call from the State that created them.
  void dispose() {
    title.dispose();
    date.dispose();
    endDate.dispose();
    startTime.dispose();
    endTime.dispose();
    clientSearch.dispose();
    address.dispose();
    notes.dispose();
    materials.dispose();
  }
}

/// Required callbacks shared by add and edit appointment forms.
class AppointmentFormCallbacks {
  const AppointmentFormCallbacks({
    required this.onSearchClients,
    required this.onRetryClientSearch,
    required this.onSelectClient,
    required this.onClearClient,
    required this.onToggleEmployee,
    required this.onSelectStartDate,
    required this.onSelectEndDate,
    required this.onPickStartTime,
    required this.onPickEndTime,
    required this.onSelectRepeat,
    required this.onUseCustomAddress,
    required this.onDayOffChanged,
    required this.onAllDayChanged,
  });

  /// Required switch callbacks shared by both flows.
  final ValueChanged<bool> onDayOffChanged;
  final ValueChanged<bool> onAllDayChanged;

  final ValueChanged<String> onSearchClients;
  final VoidCallback onRetryClientSearch;
  final ValueChanged<ClientRecord> onSelectClient;
  final VoidCallback onClearClient;
  final ValueChanged<EmployeeRecord> onToggleEmployee;

  /// Date rows return already-picked values.
  final ValueChanged<DateTime> onSelectStartDate;
  final ValueChanged<DateTime> onSelectEndDate;

  final VoidCallback onPickStartTime;
  final VoidCallback onPickEndTime;
  final ValueChanged<RepeatInterval> onSelectRepeat;
  final ValueChanged<bool> onUseCustomAddress;
}

/// Shared appointment form field stack for add and edit.
class AppointmentFormFields extends StatelessWidget {
  const AppointmentFormFields({
    required this.controllers,
    required this.allEmployees,
    required this.selectedClient,
    required this.clientResults,
    required this.isSearchingClient,
    required this.clientSearchStatus,
    required this.selectedEmployees,
    required this.repeat,
    required this.useCustomAddress,
    required this.selectedDate,
    required this.endDate,
    required this.isPersonal,
    required this.isDayOff,
    required this.isAllDay,
    required this.errors,
    required this.employeeLabel,
    required this.employeeRequired,
    required this.materialsHint,
    required this.photosSection,
    required this.callbacks,
    super.key,
    this.rosterStatus = AssigneeRosterStatus.ready,
    this.onRetryRoster,
    this.isMultiDay = false,
    this.isRunMember = false,
    this.canSpanDays = true,
    this.isOvernight = false,
    this.spanLength = 1,
    this.editingStatus,
    this.onStatusChanged,
    this.onRequestAddClient,
    this.onApplyTemplate,
    this.onPersonalChanged,
    this.tourWrap,
    this.assigneeAvailability = AssigneeAvailability.none,
    this.previousAddresses = const [],
    this.lastVisitLabel,
  });

  final AppointmentFormControllers controllers;
  final List<EmployeeRecord> allEmployees;

  /// Whether [allEmployees] has actually settled — see [EmployeePicker].
  final AssigneeRosterStatus rosterStatus;
  final VoidCallback? onRetryRoster;
  final ClientRecord? selectedClient;
  final List<ClientRecord> clientResults;
  final bool isSearchingClient;
  final ClientSearchStatus clientSearchStatus;

  /// Where the attached client's earlier jobs were, newest-first.
  final List<String> previousAddresses;

  /// When the attached client was last visited, already formatted.
  final String? lastVisitLabel;
  final List<EmployeeRecord> selectedEmployees;
  final RepeatInterval repeat;
  final bool useCustomAddress;

  /// Dates behind the two date rows' text.
  final DateTime? selectedDate;
  final DateTime? endDate;

  /// Personal job time blocked off for the crew.
  final bool isPersonal;

  /// True when a personal block is time off.
  final bool isDayOff;

  /// True when the block owns the whole day.
  final bool isAllDay;

  /// True when this job runs more than one day.
  final bool isMultiDay;

  /// True when this appointment is one day of a multi-day run.
  final bool isRunMember;

  /// Whether this form may turn a one-day job into a multi-day one.
  final bool canSpanDays;

  /// True when the daily window crosses midnight, so the run counts nights.
  final bool isOvernight;

  /// Run length in days (or nights). 1 for a single-day job.
  final int spanLength;

  final Map<String, AppointmentFormError> errors;
  final String employeeLabel;
  final bool employeeRequired;
  final String materialsHint;
  final Widget photosSection;

  /// Wraps a section as its feature-tour step.
  final Widget Function(TourStepId id, Widget child)? tourWrap;

  /// The ten always-present pickers. See [AppointmentFormCallbacks].
  final AppointmentFormCallbacks callbacks;

  /// Crew conflicts for the chosen date/span.
  final AssigneeAvailability assigneeAvailability;

  /// Edit flow only. When null, the status block is omitted (add flow).
  final String? editingStatus;
  final ValueChanged<String>? onStatusChanged;

  /// Opens the add-client sheet and auto-selects the result.
  final Future<ClientRecord?> Function(String initialName)? onRequestAddClient;

  /// Add flow only job-template callback.
  final ValueChanged<JobTemplate>? onApplyTemplate;

  /// Renders the personal-job switch when supplied.
  final ValueChanged<bool>? onPersonalChanged;

  String? _err(BuildContext context, String field) {
    final key = errors[field];
    return key == null ? null : appointmentFormErrorText(context, key);
  }

  void _selectClient(ClientRecord client) {
    controllers.clientSearch.text = client.displayName;
    // AppointmentRecord.address is the full directions string.
    controllers.address.text = client.fullAddress;
    callbacks.onSelectClient(client);
  }

  void _clearClient() {
    controllers.clientSearch.clear();
    controllers.address.clear();
    callbacks.onClearClient();
  }

  Future<void> _addNewClient() async {
    final created = await onRequestAddClient!(
      controllers.clientSearch.text.trim(),
    );
    if (created == null) return;
    _selectClient(created);
  }

  void _setPersonal(bool value) {
    // Clear hidden client-job fields without dropping uploaded photos.
    if (value) {
      controllers.clientSearch.clear();
      controllers.materials.clear();
      if (selectedClient != null && !useCustomAddress) {
        controllers.address.clear();
      }
    }
    onPersonalChanged!(value);
  }

  void _switchToCustomAddress() {
    controllers.address.clear();
    callbacks.onUseCustomAddress(true);
  }

  void _useClientAddress() {
    final client = selectedClient;
    if (client == null) return;
    controllers.address.text = client.fullAddress;
    callbacks.onUseCustomAddress(false);
  }

  /// Same shape as [_switchToCustomAddress], with the address already chosen —
  /// so it belongs here rather than once per form host.
  void _pickPreviousAddress(String address) {
    controllers.address.text = address;
    callbacks.onUseCustomAddress(true);
  }

  /// True exactly when `SelectedClientCard` is showing its "use this address"
  /// toggle AND it is on — so the Job Address block below would only repeat
  /// the address already on screen.
  ///
  /// The non-empty test is load-bearing: a client with NO address on file also
  /// sits at `useCustomAddress == false` and shows no toggle, so hiding on the
  /// flag alone leaves that job with no way to get an address at all.
  bool get _clientAddressInUse =>
      !useCustomAddress &&
      (selectedClient?.fullAddress.trim().isNotEmpty ?? false);

  Widget _jobAddress() => JobAddressSection(
    selectedClient: selectedClient,
    useCustomAddress: useCustomAddress,
    addressController: controllers.address,
    previousAddresses: previousAddresses,
    optional: isPersonal,
    onPickPrevious: _pickPreviousAddress,
    onSwitchToCustom: _switchToCustomAddress,
    onUseClientAddress: _useClientAddress,
  );

  /// Wraps [child] as [id]'s tour step when injected.
  Widget _tour(TourStepId id, Widget child) =>
      tourWrap?.call(id, child) ?? child;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ..._whoSection(context, l10n),
        ..._scheduleSection(context, l10n),
        ..._detailsSection(context, l10n),
      ],
    );
  }

  /// Service title, and on the add flow the job-template chips that fill it.
  ///
  /// A template sets this field and the default duration and nothing else, so
  /// the chips sit under it rather than in a section of their own. They keep
  /// the `apptTemplates` tour step: its copy still describes them, and the
  /// member name IS the tour's storage key, so moving the target replays
  /// nothing.
  Widget _titleGroup(BuildContext context, AppLocalizations l10n) {
    final field = SheetFocusScroll(
      child: LabeledTextField(
        label: l10n.calendar_serviceTitle,
        // Blank personal titles save as "Personal".
        hint: isPersonal
            ? l10n.calendar_personal
            : l10n.calendar_eGPlumbingRepair,
        controller: controllers.title,
        required: !isPersonal,
        optional: isPersonal,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.next,
        maxLength: TextLimits.appointmentTitle,
        errorText: _err(context, 'title'),
      ),
    );
    if (onApplyTemplate == null || isPersonal) return field;
    final theme = Theme.of(context);
    return _tour(
      TourStepId.apptTemplates,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          const SizedBox(height: AppSpacing.sp8),
          Wrap(
            spacing: AppSpacing.sp8,
            runSpacing: AppSpacing.sp8,
            children: [
              for (final template in JobTemplate.values)
                ActionChip(
                  label: Text(jobTemplateLabel(l10n, template)),
                  onPressed: () => onApplyTemplate!(template),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sp4),
          // Nothing else says a template sets the duration too.
          Text(
            l10n.calendar_templateHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  /// Service title, the personal-job switch, client picker and employee picker.
  List<Widget> _whoSection(BuildContext context, AppLocalizations l10n) => [
    MonoSectionLabel(l10n.calendar_sectionWho),
    const SizedBox(height: AppSpacing.sp8),
    // --- Personal job ---
    if (onPersonalChanged != null) ...[
      _PersonalJobSwitch(value: isPersonal, onChanged: _setPersonal),
      // Time off belongs only to personal jobs.
      if (isPersonal) ...[
        const SizedBox(height: AppSpacing.sp8),
        _DayOffChoiceChip(
          value: isDayOff,
          onChanged: callbacks.onDayOffChanged,
        ),
      ],
      const SizedBox(height: AppSpacing.sp16),
    ],
    // --- Service title, and the chips that fill it ---
    _titleGroup(context, l10n),
    const SizedBox(height: AppSpacing.sp16),
    // --- Client (a personal job has none) ---
    if (!isPersonal) ...[
      formLabel(context, l10n.calendar_client, required: true),
      _tour(
        TourStepId.apptClient,
        selectedClient == null
            ? SheetFocusScroll(
                child: ClientPicker(
                  controller: controllers.clientSearch,
                  results: clientResults,
                  status: clientSearchStatus,
                  isSearching: isSearchingClient,
                  onChanged: callbacks.onSearchClients,
                  onSelect: _selectClient,
                  onRetry: callbacks.onRetryClientSearch,
                  errorText: _err(context, 'client'),
                  onAddNew: onRequestAddClient == null ? null : _addNewClient,
                ),
              )
            : SelectedClientCard(
                client: selectedClient!,
                useClientAddress: !useCustomAddress,
                lastVisitLabel: lastVisitLabel,
                onChange: _clearClient,
                onRemove: _clearClient,
                onUseClientAddressChanged: (useIt) =>
                    useIt ? _useClientAddress() : _switchToCustomAddress(),
              ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      if (!_clientAddressInUse) ...[
        _tour(TourStepId.apptJobAddress, _jobAddress()),
        const SizedBox(height: AppSpacing.sp16),
      ],
    ],
    // A personal block has no client but may still name a place. Day off has
    // neither.
    if (isPersonal && !isDayOff) ...[
      _jobAddress(),
      const SizedBox(height: AppSpacing.sp16),
    ],
    // --- Employees ---
    formLabel(context, employeeLabel, required: employeeRequired),
    const SizedBox(height: AppSpacing.sp4),
    _tour(
      TourStepId.apptCrew,
      EmployeePicker(
        allEmployees: allEmployees,
        selectedEmployees: selectedEmployees,
        onToggle: callbacks.onToggleEmployee,
        errorText: _err(context, 'employees'),
        availability: assigneeAvailability,
        rosterStatus: rosterStatus,
        onRetryRoster: onRetryRoster,
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
  ];

  /// Start/end date, start/end time, status (edit flow only) and repeat.
  List<Widget> _scheduleSection(BuildContext context, AppLocalizations l10n) {
    // Day off has no work status lifecycle.
    final showStatus =
        editingStatus != null && onStatusChanged != null && !isDayOff;
    final isNarrowPhone = context.isNarrowWidth;

    // Build time rows only when the schedule needs them.
    List<Widget> timeRows() {
      final startRow = SheetFieldRow(
        // Multi-day times describe each day's window.
        label: !isMultiDay
            ? l10n.calendar_startTime
            : (isOvernight
                  ? l10n.calendar_startTimeEachNight
                  : l10n.calendar_startTimeEachDay),
        value: controllers.startTime.text,
        placeholder: l10n.calendar_start,
        accent: true,
        useMonoValue: true,
        errorText: _err(context, 'startTime'),
        onTap: callbacks.onPickStartTime,
      );
      final endRow = SheetFieldRow(
        label: !isMultiDay
            ? l10n.calendar_endTime
            : (isOvernight
                  ? l10n.calendar_endTimeNextMorning
                  : l10n.calendar_endTimeEachDay),
        value: controllers.endTime.text,
        placeholder: l10n.calendar_end,
        accent: true,
        useMonoValue: true,
        errorText: _err(context, 'endTime'),
        onTap: callbacks.onPickEndTime,
      );
      // Start and end share one row until the screen is too narrow to read both.
      if (isNarrowPhone) return [startRow, endRow];
      return [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: startRow),
              const VerticalDivider(width: 1),
              Expanded(child: endRow),
            ],
          ),
        ),
      ];
    }

    return [
      MonoSectionLabel(l10n.calendar_sectionSchedule),
      const SizedBox(height: AppSpacing.sp8),
      _tour(
        TourStepId.apptSchedule,
        SheetPanel(
          children: [
            // All day controls whether time rows exist.
            if (!isDayOff)
              _AllDaySwitch(
                value: isAllDay,
                onChanged: callbacks.onAllDayChanged,
              ),
            _dateRows(context, l10n),
            // All-day schedules show dates only.
            if (!isAllDay && !isDayOff) ...timeRows(),
            // Repeat is hidden for personal and multi-day jobs, and for one day
            // of a run: a run member's own window is a single day, so
            // `isMultiDay` is false for it and cannot carry this on its own.
            if (!isPersonal && !isMultiDay && !isRunMember)
              RepeatIntervalPicker(
                current: repeat,
                onChanged: callbacks.onSelectRepeat,
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      // --- Status (edit flow only) ---
      if (showStatus) ...[
        formLabel(context, l10n.calendar_appointmentStatus),
        const SizedBox(height: AppSpacing.sp4),
        AppointmentStatusPicker(
          currentStatus: editingStatus!,
          onChanged: onStatusChanged!,
        ),
        const SizedBox(height: AppSpacing.sp16),
      ],
    ];
  }

  /// Start and end date as one expandable panel row.
  Widget _dateRows(BuildContext context, AppLocalizations l10n) =>
      AppointmentDateRows(
        startValue: controllers.date.text,
        endValue: controllers.endDate.text,
        startDate: selectedDate,
        endDate: endDate,
        firstDate: AppointmentDraftDefaults.datePickerFirstDate,
        lastDate: AppointmentDraftDefaults.datePickerLastDate,
        startError: _err(context, 'date'),
        endError: _err(context, 'endDate'),
        endTrailingLabel: !isMultiDay
            ? null
            : (isOvernight
                  ? l10n.calendar_spanNights(spanLength)
                  : l10n.calendar_spanDays(spanLength)),
        showEndDate: !isRunMember && canSpanDays,
        onStartDateSelected: callbacks.onSelectStartDate,
        onEndDateSelected: callbacks.onSelectEndDate,
      );

  /// Address, notes, materials, and host-supplied photos.
  List<Widget> _detailsSection(BuildContext context, AppLocalizations l10n) => [
    MonoSectionLabel(l10n.calendar_sectionDetails),
    const SizedBox(height: AppSpacing.sp8),
    _tour(
      TourStepId.apptDetails,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _detailsBody(context, l10n),
      ),
    ),
  ];

  List<Widget> _detailsBody(BuildContext context, AppLocalizations l10n) => [
    // --- Notes ---
    SheetFocusScroll(
      child: LabeledTextField(
        label: l10n.calendar_notes,
        hint: l10n.calendar_typeTheNoteHere,
        controller: controllers.notes,
        optional: true,
        textCapitalization: TextCapitalization.sentences,
        maxLines: 2,
        maxLength: TextLimits.appointmentNotes,
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    // --- Materials and photos (job-site fields; a personal block has none) ---
    if (!isPersonal) ...[
      SheetFocusScroll(
        child: LabeledTextField(
          label: l10n.calendar_materialsNeeded,
          hint: materialsHint,
          controller: controllers.materials,
          optional: true,
          textCapitalization: TextCapitalization.sentences,
          maxLines: 2,
          maxLength: TextLimits.appointmentMaterials,
        ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      formLabel(context, l10n.calendar_pictures, optional: true),
      photosSection,
    ],
  ];
}

/// The "Day off" chip under the personal-job switch.
class _DayOffChoiceChip extends StatelessWidget {
  const _DayOffChoiceChip({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: FilterChip(
      label: Text(context.l10n.calendar_dayOff),
      selected: value,
      onSelected: onChanged,
    ),
  );
}

/// Marks the job as personal time rather than a client visit.
class _PersonalJobSwitch extends StatelessWidget {
  const _PersonalJobSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      // The field changes below make the switch self-explanatory.
      title: Text(context.l10n.calendar_personalJob),
      value: value,
      activeTrackColor: Theme.of(context).colorScheme.primary,
      onChanged: onChanged,
    ),
  );
}

/// Turns the block into a whole-day one.
class _AllDaySwitch extends StatelessWidget {
  const _AllDaySwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 9, 13, 9),
          child: Row(
            children: [
              // "All day" is enough label on its own.
              Expanded(
                child: Text(
                  context.l10n.calendar_allDay,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: AppSpacing.sp8),
              Switch.adaptive(
                value: value,
                activeTrackColor: theme.colorScheme.primary,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
