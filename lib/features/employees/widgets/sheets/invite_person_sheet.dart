import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/employees/application/employee_form_controller.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/features/employees/domain/policies/crew_color_policy.dart';
import 'package:scheduling/features/employees/domain/policies/employee_form_validator.dart';
import 'package:scheduling/features/employees/domain/policies/employee_name_policy.dart';
import 'package:scheduling/features/employees/widgets/dialogs/new_account_dialog.dart';
import 'package:scheduling/features/employees/widgets/fields/employee_color_grid.dart';
import 'package:scheduling/features/employees/widgets/fields/job_title_chips.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';
import 'package:scheduling/shared/widgets/sheets/app_bottom_sheet.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

/// Opens the invite sheet. Resolves to `true` once the account is created and
/// the admin has dismissed the new-account dialog, null otherwise.
///
/// Deliberately NOT returning the created record: the account is written
/// server-side by `createEmployeeAccount`, so the client never holds the doc
/// id. The roster picks it up from the live users stream.
Future<bool?> showInvitePersonSheet(
  BuildContext context, {
  required Set<int> usedColors,
}) => showAppBottomSheet<bool>(
  context,
  builder: (_) => InvitePersonSheet(usedColors: usedColors),
);

class InvitePersonSheet extends ConsumerStatefulWidget {
  const InvitePersonSheet({super.key, this.usedColors = const {}});

  final Set<int> usedColors;

  @override
  ConsumerState<InvitePersonSheet> createState() => _InvitePersonSheetState();
}

class _InvitePersonSheetState extends ConsumerState<InvitePersonSheet> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  JobTitle _jobTitle = JobTitle.unset;
  late int _selectedColor;
  final Map<String, String?> errors = {};

  // Admin-only surface: the Team tab's FAB is the only way in.
  final _tour = TourSteps(const FormTour(TourForm.invitePerson), isAdmin: true);

  @override
  void initState() {
    super.initState();
    // Seed the first colour nobody holds, so the default pick is not a
    // duplicate the admin has to notice and change.
    _selectedColor = AppColors.crewPalette
        .firstWhere(
          (c) => !widget.usedColors.contains(c.toARGB32()),
          orElse: () => AppColors.crewPalette.first,
        )
        .toARGB32();
    ref
        .read(analyticsServiceProvider)
        .logScreenView(AnalyticsScreens.invitePerson);
  }

  @override
  void dispose() {
    for (final controller in [
      _firstNameController,
      _lastNameController,
      _emailController,
      _phoneController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _clearError(String key) {
    if (errors[key] == null) return;
    setState(() => errors[key] = null);
  }

  Future<void> _save() async {
    // Both halves are required here: an invite with no name produces a roster
    // row with nothing to identify.
    final composedName = composeEmployeeName(
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      fallback: '',
    );
    final nextErrors = EmployeeFormValidator.validate(
      l10n: context.l10n,
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      email: _emailController.text.trim(),
      requireLastName: true,
    );
    setState(() {
      errors
        ..clear()
        ..addAll(nextErrors);
    });
    if (nextErrors.values.any((e) => e != null)) return;

    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introSaveEmployee,
    )) {
      return;
    }

    // Drag-dismiss bypasses PopScope, so show the password via the root navigator.
    final navigator = Navigator.of(context, rootNavigator: true);
    final analytics = ref.read(analyticsServiceProvider);
    final firstName = _firstNameController.text.trim();
    final outcome = await ref
        .read(employeeFormControllerProvider.notifier)
        .createAccount(
          EmployeeRecord(
            id: '',
            name: composedName,
            firstName: firstName,
            lastName: _lastNameController.text.trim(),
            email: normalizeEmail(_emailController.text),
            phone: _phoneController.text.trim(),
            color: Color(_selectedColor),
            // role defaults to 'employee'; createEmployeeAccount always
            // writes it server-side regardless of what the client sends.
            jobTitle: _jobTitle,
          ),
        );
    switch (outcome) {
      case EmployeeAccountCreated(:final credentials):
        // Fires before the dialog: the account exists whether or not it is dismissed.
        analytics.logEmployeeInvited();
        await showNewAccountDialog(
          // The root navigator outlives this sheet, so its context is safe.
          // ignore: use_build_context_synchronously
          navigator.context,
          name: firstName,
          credentials: credentials,
        );
        if (!mounted) return;
        Navigator.pop(context, true);
      // A skipped duplicate submit surfaces nothing; an update is unreachable here.
      case EmployeeSaveBusy():
      case EmployeeUpdated():
        break;
      case EmployeeEmailInUse(:final failure):
        if (!mounted) return;
        setState(() => errors['email'] = failure.toLocalizedMessage(context));
      case EmployeeSaveFailed(:final error):
        if (!mounted) return;
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introSaveEmployee,
                error: error,
              ),
            );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final activity = ref.watch(employeeFormControllerProvider);

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: true,
      stepKeys: _tour.keys,
      autoScroll: true,
      child: FormSheetFrame(
        title: l10n.employees_invitePerson,
        primaryLabel: l10n.employees_sendInvite,
        isBusy: activity.isSaving,
        onPrimary: _save,
        headerTourWrap: (child) => _tour.stepIf(TourStepId.personCreate, child),
        scrollCacheExtent: kTourScrollCacheExtent,
        children: [
          ..._detailsSection(theme, l10n),
          ..._roleSection(theme, l10n),
          ..._colourSection(theme, l10n),
          // Outside every _section: it is advice about the whole form, and
          // inside one it would sit under that step's tour spotlight.
          WarningNote(message: l10n.employees_invitedNote),
        ],
      ),
    );
  }

  /// Label + tour-wrapped body. One target per section, since each step
  /// describes the whole section rather than its first field. Stretch-aligned
  /// like its parent, so the layout is unchanged.
  List<Widget> _section(TourStepId id, String label, List<Widget> body) => [
    MonoSectionLabel(label),
    const SizedBox(height: AppSpacing.sp8),
    _tour.stepIf(
      id,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
    ),
  ];

  List<Widget> _detailsSection(ThemeData theme, AppLocalizations l10n) =>
      _section(TourStepId.personDetails, l10n.employees_sectionDetails, [
        SheetFocusScroll(
          child: LabeledTextField(
            key: const Key('firstName'),
            label: l10n.employees_firstName,
            controller: _firstNameController,
            required: true,
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
            required: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            maxLength: TextLimits.employeeNameHalf,
            errorText: errors['lastName'],
            onChanged: (_) => _clearError('lastName'),
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        SheetFocusScroll(
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
      ]);

  List<Widget> _roleSection(ThemeData theme, AppLocalizations l10n) =>
      _section(TourStepId.personJobTitle, l10n.employees_sectionRole, [
        JobTitleChips(
          value: _jobTitle,
          onChanged: (next) => setState(() => _jobTitle = next),
        ),
        const SizedBox(height: AppSpacing.sp24),
      ]);

  List<Widget> _colourSection(ThemeData theme, AppLocalizations l10n) =>
      _section(TourStepId.personColour, l10n.employees_sectionColour, [
        EmployeeColorGrid(
          selectedColor: _selectedColor,
          usedColors: widget.usedColors,
          onColorSelected: (value) => setState(() => _selectedColor = value),
        ),
        const SizedBox(height: AppSpacing.sp8),
        Text(
          l10n.employees_coloursLeft(
            availableCrewColorCount(widget.usedColors),
          ),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.palette.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.sp24),
      ]);
}
