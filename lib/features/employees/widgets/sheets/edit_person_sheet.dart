import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/button_styles.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/employees/application/employee_form_controller.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/features/employees/domain/policies/crew_color_policy.dart';
import 'package:scheduling/features/employees/domain/policies/employee_form_validator.dart';
import 'package:scheduling/features/employees/domain/policies/employee_name_policy.dart';
import 'package:scheduling/features/employees/domain/policies/work_schedule_policy.dart';
import 'package:scheduling/features/employees/widgets/fields/availability_panel.dart';
import 'package:scheduling/features/employees/widgets/fields/employee_color_grid.dart';
import 'package:scheduling/features/employees/widgets/fields/job_title_chips.dart';
import 'package:scheduling/features/employees/widgets/fields/work_schedule_pickers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';
import 'package:scheduling/shared/widgets/feedback/user_status_chip.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/fields/sheet_field_row.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';
import 'package:scheduling/shared/widgets/sheets/app_bottom_sheet.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

/// Opens the edit-person sheet. Resolves to the saved record, or null when the
/// sheet was cancelled.
///
/// A nullable record is enough because a person is never removed here (owner
/// decision 2026-08-02) — there is no third "they are gone" state.
Future<EmployeeRecord?> showEditPersonSheet(
  BuildContext context,
  EmployeeRecord employee, {
  required Set<int> usedColors,
}) => showAppBottomSheet<EmployeeRecord>(
  context,
  builder: (_) => EditPersonSheet(employee: employee, usedColors: usedColors),
);

class EditPersonSheet extends ConsumerStatefulWidget {
  const EditPersonSheet({
    required this.employee,
    super.key,
    this.usedColors = const {},
  });

  final EmployeeRecord employee;
  final Set<int> usedColors;

  @override
  ConsumerState<EditPersonSheet> createState() => _EditPersonSheetState();
}

class _EditPersonSheetState extends ConsumerState<EditPersonSheet> {
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emergencyController;
  late final TextEditingController _emergencyPhoneController;
  late final ProviderSubscription<AsyncValue<EmergencyContact>> _emergencySub;

  /// A snapshot of users/{id}/private/emergency has actually arrived.
  /// Save writes the emergency doc ONLY when this is true — the fields start
  /// blank and fill in asynchronously, so saving before the read lands would
  /// merge two empty strings over a stored contact and destroy it.
  bool _emergencyLoaded = false;

  /// The admin has typed in one of the two fields. Until then a fresher
  /// snapshot is allowed to re-seed, so a stale cache-first emission can be
  /// corrected by the server one instead of being saved back as a lost update.
  bool _emergencyDirty = false;

  /// The read failed — "we couldn't load it", which must NOT render as "none
  /// on file", or the admin overwrites a contact they simply couldn't see.
  bool _emergencyFailed = false;

  late JobTitle _jobTitle;
  late List<bool> _workingDays;
  late int _workStartMinutes;
  late int _workEndMinutes;
  // Picked from an action sheet, not typed. 0 means no cap.
  late int _maxJobsPerDay;
  late int _selectedColor;
  late bool _onCall;
  late bool _isAdmin;
  late bool _isTestAccount;
  late bool _monthEndReviewPush;
  late bool _isDisabled;
  final Map<String, String?> errors = {};

  @override
  void initState() {
    super.initState();
    ref
        .read(analyticsServiceProvider)
        .logScreenView(AnalyticsScreens.editPerson);
    final e = widget.employee;
    // A legacy doc has the whole name in `name` and nothing in first/last.
    // Seeding First with it keeps the stored name visible and editable, and
    // composeEmployeeName then preserves it on save.
    final hasSplitName =
        e.firstName.trim().isNotEmpty || e.lastName.trim().isNotEmpty;
    _firstNameController = TextEditingController(
      text: hasSplitName ? e.firstName : e.name,
    );
    _lastNameController = TextEditingController(text: e.lastName);
    _emailController = TextEditingController(text: e.email);
    _phoneController = TextEditingController(text: e.phone);
    // Seeded asynchronously: the emergency pair lives in
    // users/{id}/private/emergency, a separate read, so the fields start blank
    // and fill in when it arrives. Guarded by _emergencySeeded so a later
    // snapshot can't overwrite what the admin has already typed.
    _emergencyController = TextEditingController();
    _emergencyPhoneController = TextEditingController();
    // Read the current value directly rather than firing the listener
    // immediately — the immediate fire lands inside initState, where setState
    // is illegal.
    _applyEmergency(ref.read(emergencyContactProvider(e.id)), initial: true);
    _emergencySub = ref.listenManual(
      emergencyContactProvider(e.id),
      (_, next) => _applyEmergency(next),
    );

    _jobTitle = e.jobTitle;
    _workingDays = normalizeWorkingDays(e.workingDays);
    _workStartMinutes = e.workStartMinutes;
    _workEndMinutes = e.workEndMinutes;
    _maxJobsPerDay = e.maxJobsPerDay;
    _selectedColor = e.color.toARGB32();
    _onCall = e.onCall;
    _isAdmin = e.isAdmin;
    _isTestAccount = e.isTestAccount;
    _monthEndReviewPush = e.monthEndReviewPush;
    _isDisabled = e.isDisabled;
  }

  /// Folds one emergency snapshot into the fields. [initial] runs inside
  /// initState, where the frame hasn't been built yet and setState would throw.
  void _applyEmergency(
    AsyncValue<EmergencyContact> value, {
    bool initial = false,
  }) {
    void apply() {
      value.when(
        loading: () {},
        error: (_, _) {
          _emergencyFailed = true;
        },
        data: (contact) {
          _emergencyFailed = false;
          _emergencyLoaded = true;
          // Never clobber what is being typed.
          if (_emergencyDirty) return;
          _emergencyController.text = contact.contact;
          _emergencyPhoneController.text = contact.phone;
        },
      );
    }

    if (initial || !mounted) {
      apply();
      return;
    }
    setState(apply);
  }

  void _markEmergencyDirty() {
    if (_emergencyDirty) return;
    _emergencyDirty = true;
  }

  @override
  void dispose() {
    _emergencySub.close();
    for (final controller in [
      _firstNameController,
      _lastNameController,
      _emailController,
      _phoneController,
      _emergencyController,
      _emergencyPhoneController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _clearError(String key) {
    if (errors[key] == null) return;
    setState(() => errors[key] = null);
  }

  bool _validate() {
    final next = EmployeeFormValidator.validate(
      l10n: context.l10n,
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      email: _emailController.text.trim(),
      workStartMinutes: _workStartMinutes,
      workEndMinutes: _workEndMinutes,
    );
    setState(() {
      errors
        ..clear()
        ..addAll(next);
    });
    return next.values.every((e) => e == null);
  }

  Future<void> _pickMaxJobs() async {
    final picked = await showMaxJobsPicker(context);
    if (picked == null || !mounted) return;
    setState(() => _maxJobsPerDay = picked);
  }

  Future<void> _save() async {
    final composedName = composeEmployeeName(
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      fallback: widget.employee.name,
    );
    if (!_validate()) return;

    // Fail fast offline, or Save spins until we reconnect.
    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introSaveEmployee,
    )) {
      return;
    }

    final updated = widget.employee.copyWith(
      name: composedName,
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
      email: normalizeEmail(_emailController.text),
      phone: _phoneController.text.trim(),
      color: Color(_selectedColor),
      role: _isAdmin ? 'admin' : 'employee',
      jobTitle: _jobTitle,
      workingDays: _workingDays,
      workStartMinutes: _workStartMinutes,
      workEndMinutes: _workEndMinutes,
      maxJobsPerDay: _maxJobsPerDay,
      onCall: _onCall,
      isTestAccount: _isTestAccount,
      monthEndReviewPush: _isAdmin && _monthEndReviewPush,
    );

    final outcome = await ref
        .read(employeeFormControllerProvider.notifier)
        .updateEmployee(
          updated,
          // null = leave the emergency doc alone. Sending a value we never
          // managed to read would merge blanks over a stored contact.
          emergency: _emergencyLoaded
              ? EmergencyContact(
                  contact: _emergencyController.text,
                  phone: _emergencyPhoneController.text,
                )
              : null,
        );
    if (!mounted) return;

    switch (outcome) {
      // See pending_invite_tile: a skipped duplicate submit surfaces nothing.
      case EmployeeSaveBusy():
        break;
      case EmployeeUpdated():
        ref.read(analyticsServiceProvider).logEmployeeEdited();
        ref
            .read(noticeServiceProvider)
            .success(context.l10n.common_changesSaved);
        Navigator.pop(context, updated);
      case EmployeeEmailInUse(:final failure):
        setState(() => errors['email'] = failure.toLocalizedMessage(context));
      case EmployeeSaveFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introSaveEmployee,
                error: error,
              ),
            );
      case EmployeeAccountCreated():
        // Unreachable from the edit path; the sealed family forces the branch.
        break;
    }
  }

  Future<void> _confirmToggleStatus() async {
    final l10n = context.l10n;
    final actionLabel = _isDisabled
        ? l10n.employees_enableEmployee
        : l10n.employees_disableEmployee;
    final confirmed = await showConfirmDialog(
      context,
      title: actionLabel,
      message: _isDisabled
          ? l10n.employees_enableEmployeeConfirmBody
          : l10n.employees_disableEmployeeConfirmBody,
      confirmLabel: actionLabel,
      destructive: !_isDisabled,
    );
    if (!mounted || !confirmed) return;

    final outcome = await ref
        .read(employeeFormControllerProvider.notifier)
        .setEmployeeStatus(docId: widget.employee.id, disable: !_isDisabled);
    if (!mounted) return;

    switch (outcome) {
      case EmployeeStatusChanged():
        // The NEW status only — never who it was applied to.
        ref
            .read(analyticsServiceProvider)
            .logEmployeeStatusChanged(
              // The account-status vocabulary has an owner; a second spelling
              // here would drift from what the doc actually stores.
              status: _isDisabled
                  ? UserStatus.active.name
                  : UserStatus.disabled.name,
            );
        setState(() => _isDisabled = !_isDisabled);
        ref
            .read(noticeServiceProvider)
            .success(
              _isDisabled
                  ? l10n.employees_employeeDisabledSuccessfully
                  : l10n.employees_employeeEnabledSuccessfully,
            );
      case EmployeeStatusBusy():
        break;
      case EmployeeStatusChangeFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: l10n.error_introChangeEmployeeStatus,
                error: error,
              ),
            );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final materialL10n = MaterialLocalizations.of(context);
    final activity = ref.watch(employeeFormControllerProvider);
    final sheetBusy = activity.isSaving || activity.isTogglingStatus;

    return FormSheetFrame(
      title: l10n.employees_editPerson,
      primaryLabel: l10n.common_save,
      isBusy: sheetBusy,
      onPrimary: _save,
      children: [
        ..._detailsSection(theme, l10n),
        ..._roleSection(theme, l10n),
        ..._colourSection(theme, l10n),
        ..._availabilitySection(theme, l10n, materialL10n),
        ..._emergencySection(theme, l10n),
        ..._accessSection(theme, l10n, sheetBusy),
      ],
    );
  }

  List<Widget> _detailsSection(ThemeData theme, AppLocalizations l10n) => [
    MonoSectionLabel(l10n.employees_sectionDetails),
    const SizedBox(height: AppSpacing.sp8),
    SheetFocusScroll(
      child: LabeledTextField(
        key: const Key('firstName'),
        label: l10n.employees_firstName,
        controller: _firstNameController,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        maxLength: TextLimits.employeeNameHalf,
        errorText: errors['name'],
        onChanged: (_) => _clearError('name'),
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    SheetFocusScroll(
      child: LabeledTextField(
        key: const Key('lastName'),
        label: l10n.employees_lastName,
        controller: _lastNameController,
        optional: true,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        maxLength: TextLimits.employeeNameHalf,
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    SheetFocusScroll(
      // Editable again since the `changeEmployeeEmail` callable exists: this is
      // the person's SIGN-IN identity, and the repository routes a change
      // through the server so Firebase Auth and the users doc move together.
      // It was read-only while the field wrote Firestore alone — that left the
      // person signing in at the old address and desynced the two stores
      // `createEmployeeAccount` joins on.
      child: LabeledTextField(
        key: const Key('email'),
        label: l10n.employees_workEmail,
        controller: _emailController,
        required: true,
        keyboard: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        maxLength: TextLimits.authEmail,
        errorText: errors['email'],
        onChanged: (_) => _clearError('email'),
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    SheetFocusScroll(
      child: LabeledTextField(
        label: l10n.employees_phoneNumber,
        controller: _phoneController,
        optional: true,
        keyboard: TextInputType.phone,
        inputFormatters: const [PhoneInputFormatter()],
        maxLength: TextLimits.phone,
      ),
    ),
    const SizedBox(height: AppSpacing.sp24),
  ];

  List<Widget> _roleSection(ThemeData theme, AppLocalizations l10n) => [
    MonoSectionLabel(l10n.employees_sectionRole),
    const SizedBox(height: AppSpacing.sp8),
    JobTitleChips(
      value: _jobTitle,
      onChanged: (next) => setState(() => _jobTitle = next),
    ),
    const SizedBox(height: AppSpacing.sp24),
  ];

  List<Widget> _colourSection(ThemeData theme, AppLocalizations l10n) => [
    MonoSectionLabel(l10n.employees_sectionColour),
    const SizedBox(height: AppSpacing.sp8),
    EmployeeColorGrid(
      selectedColor: _selectedColor,
      usedColors: widget.usedColors,
      onColorSelected: (value) => setState(() => _selectedColor = value),
    ),
    const SizedBox(height: AppSpacing.sp8),
    Text(
      l10n.employees_coloursLeft(availableCrewColorCount(widget.usedColors)),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.palette.textTertiary,
      ),
    ),
    const SizedBox(height: AppSpacing.sp24),
  ];

  List<Widget> _availabilitySection(
    ThemeData theme,
    AppLocalizations l10n,
    MaterialLocalizations materialL10n,
  ) => [
    MonoSectionLabel(l10n.employees_sectionAvailability),
    const SizedBox(height: AppSpacing.sp8),
    // The SAME panel Settings › My details renders, so the two can't drift on
    // a row's treatment or on which time picker it opens.
    AvailabilityPanel(
      workingDays: _workingDays,
      workStartMinutes: _workStartMinutes,
      workEndMinutes: _workEndMinutes,
      onCall: _onCall,
      hoursErrorText: errors['hours'],
      // Admin-only, and written through the admin save path — it is not on the
      // self-service allowlist, so it is a slot rather than part of the patch.
      maxJobsRow: SheetFieldRow(
        label: l10n.employees_maxJobsPerDay,
        value: maxJobsLabel(l10n, _maxJobsPerDay),
        useMonoValue: true,
        onTap: _pickMaxJobs,
      ),
      onChanged: (days, start, end, {required onCall}) => setState(() {
        _workingDays = days;
        _workStartMinutes = start;
        _workEndMinutes = end;
        _onCall = onCall;
        errors['hours'] = null;
      }),
    ),
    const SizedBox(height: AppSpacing.sp24),
    // Its own section, not a tail on AVAILABILITY — who to call in an
    // emergency has nothing to do with when someone works.,
  ];

  List<Widget> _emergencySection(ThemeData theme, AppLocalizations l10n) => [
    MonoSectionLabel(l10n.employees_sectionEmergency),
    const SizedBox(height: AppSpacing.sp8),
    // Free-text stays a LabeledTextField, outside the panel — it owns the
    // error shake and the clear button a panel row has neither of.
    if (_emergencyFailed)
      WarningNote(message: l10n.employees_emergencyLoadFailed)
    else ...[
      SheetFocusScroll(
        child: LabeledTextField(
          label: l10n.employees_emergencyContact,
          controller: _emergencyController,
          optional: true,
          // Not editable until the separate read lands, so the admin can
          // never type into (or save) fields that only LOOK empty.
          readOnly: !_emergencyLoaded,
          textInputAction: TextInputAction.next,
          maxLength: TextLimits.employeeEmergencyContact,
          onChanged: (_) => _markEmergencyDirty(),
        ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      SheetFocusScroll(
        child: LabeledTextField(
          key: const Key('emergencyPhone'),
          label: l10n.employees_emergencyPhone,
          controller: _emergencyPhoneController,
          optional: true,
          readOnly: !_emergencyLoaded,
          keyboard: TextInputType.phone,
          inputFormatters: const [PhoneInputFormatter()],
          maxLength: TextLimits.phone,
          onChanged: (_) => _markEmergencyDirty(),
        ),
      ),
    ],
    const SizedBox(height: AppSpacing.sp24),
  ];

  List<Widget> _accessSection(
    ThemeData theme,
    AppLocalizations l10n,
    bool sheetBusy,
  ) => [
    MonoSectionLabel(l10n.employees_sectionAccess),
    const SizedBox(height: AppSpacing.sp8),
    SwitchListTile.adaptive(
      key: const Key('adminAccess'),
      value: _isAdmin,
      activeTrackColor: theme.colorScheme.primary,
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.employees_adminAccess),
      subtitle: Text(l10n.employees_adminAccessDescription),
      onChanged: (value) => setState(() => _isAdmin = value),
    ),
    SwitchListTile.adaptive(
      key: const Key('testAccount'),
      value: _isTestAccount,
      activeTrackColor: theme.colorScheme.primary,
      contentPadding: EdgeInsets.zero,
      title: Text(l10n.employees_testAccount),
      subtitle: Text(l10n.employees_testAccountCaption),
      onChanged: (value) => setState(() => _isTestAccount = value),
    ),
    if (_isAdmin)
      SwitchListTile.adaptive(
        key: const Key('monthEndReviewPush'),
        value: _monthEndReviewPush,
        activeTrackColor: theme.colorScheme.primary,
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.employees_monthEndReviewPush),
        subtitle: Text(l10n.employees_monthEndReviewPushDescription),
        onChanged: (value) => setState(() => _monthEndReviewPush = value),
      ),
    const SizedBox(height: AppSpacing.sp24),
    _StatusFooter(
      employeeId: widget.employee.id,
      isDisabled: _isDisabled,
      isBusy: sheetBusy,
      onToggle: _confirmToggleStatus,
    ),
  ];
}

/// Disable / re-enable, with the count of jobs a human still has to move.
///
/// P4 reassigns nothing — the spec's words are "availability changes notify,
/// a human moves the work". The count is information, not an action.
class _StatusFooter extends ConsumerWidget {
  const _StatusFooter({
    required this.employeeId,
    required this.isDisabled,
    required this.isBusy,
    required this.onToggle,
  });

  final String employeeId;
  final bool isDisabled;
  final bool isBusy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final futureJobs = ref.watch(futureAssignmentCountProvider(employeeId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          style: destructiveOutlinedButtonStyle(
            context,
            minimumSize: const Size(double.infinity, 48),
          ),
          onPressed: isBusy ? null : onToggle,
          icon: Icon(
            isDisabled ? Icons.lock_open_outlined : Icons.block_outlined,
            size: 18,
          ),
          label: Text(
            isDisabled
                ? l10n.employees_enableEmployee
                : l10n.employees_disableEmployee,
          ),
        ),
        // Only meaningful before disabling — after, the work has already been
        // left assigned and the caption would be nagging about the past.
        if (!isDisabled && futureJobs.hasValue)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sp8),
            child: Text(
              l10n.employees_disableReassignCaption(futureJobs.requireValue),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.palette.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}
