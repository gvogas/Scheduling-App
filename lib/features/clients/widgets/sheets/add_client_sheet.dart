import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/sheet_focus.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/clients/application/client_form_controller.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/policies/client_form_validator.dart';
import 'package:scheduling/features/clients/domain/policies/client_name_policy.dart';
import 'package:scheduling/features/clients/widgets/client_form_state.dart';
import 'package:scheduling/features/clients/widgets/fields/client_address_section.dart';
import 'package:scheduling/features/clients/widgets/fields/client_name_phone_lift.dart';
import 'package:scheduling/features/clients/widgets/fields/client_type_chips.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/offline_form_notice.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';
import 'package:scheduling/shared/widgets/sheets/app_bottom_sheet.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

/// What the admin asked to do after the client was created.
enum AddClientNext { none, bookJob }

/// What [showAddClientSheet] resolves to: the created client plus the follow-up
/// action.
typedef AddClientResult = ({ClientRecord client, AddClientNext next});

/// Opens the add-client sheet.
/// [analyticsSource] is required: this sheet serves the Clients tab and the
/// booking form's inline add, and telling those apart is what says whether
/// clients are created deliberately or mid-booking.
Future<AddClientResult?> showAddClientSheet(
  BuildContext context, {
  required String analyticsSource,
  String? initialName,
  bool settleFocus = false,
}) async {
  if (settleFocus) {
    await SheetFocus.settleBeforeSheet();
    if (!context.mounted) return null;
  }
  final created = await showAppBottomSheet<AddClientResult>(
    context,
    builder: (_) => AddClientSheet(
      initialName: initialName,
      analyticsSource: analyticsSource,
    ),
  );
  if (settleFocus && context.mounted) await SheetFocus.unfocusAfterSheet();
  // Guard against the widget unmounting while the sheet is open — we shouldn't
  // hand the client back to a form that's already been disposed.
  return context.mounted ? created : null;
}

class AddClientSheet extends ConsumerStatefulWidget {
  const AddClientSheet({
    required this.analyticsSource,
    super.key,
    this.initialName,
  });

  /// Which surface opened this sheet (see `AnalyticsSources`).
  final String analyticsSource;

  /// Prefills the name field (e.g.
  final String? initialName;

  @override
  ConsumerState<AddClientSheet> createState() => _AddClientSheetState();
}

// ClientFormState supplies `noFixedAddress`, `setNoFixedAddress`, `errors` and
// `clearError`.
class _AddClientSheetState extends ConsumerState<AddClientSheet>
    with ClientFormState<AddClientSheet> {
  final _nameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _accessNotesController = TextEditingController();
  final _addressController = TextEditingController();
  final _aptController = TextEditingController();
  final _cityController = TextEditingController();
  final _provinceController = TextEditingController();
  final _postalCodeController = TextEditingController();
  final _countryController = TextEditingController();

  ClientType _type = ClientType.unset;

  // Admin-only surface: reached from the Clients FAB and the appointment form's
  // inline add-client, both admin-gated.
  final _tour = TourSteps(const FormTour(TourForm.addClient), isAdmin: true);

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.initialName ?? '';
    // The seed is a programmatic write, which never fires the name field's
    // `onChanged` — so the lift below has to be run by hand here.
    liftPhoneFromNameField(name: _nameController, phone: _phoneController);
    // A sheet route has no name, so the observer skips it.
    ref
        .read(analyticsServiceProvider)
        .logScreenView(AnalyticsScreens.addClient);
  }

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _firstNameController,
      _lastNameController,
      _phoneController,
      _emailController,
      _accessNotesController,
      _addressController,
      _aptController,
      _cityController,
      _provinceController,
      _postalCodeController,
      _countryController,
    ]) {
      controller.dispose();
    }
    // A no-op today — this sheet deliberately offers no additional contacts
    // (see the note above the class) — but the mixin owns those controllers, so
    // the day someone adds the field for parity there is no compile-time signal
    // that this line is missing.
    disposeAdditionalContacts();
    super.dispose();
  }

  String _buildFullAddress() => AddressParser.canonicalFrom(
    street: _addressController.text,
    apt: _aptController.text,
  );

  ClientRecord _draft() {
    // The STORED name is the Wave CUSTOMER name: the phone number for a person,
    // the typed name for a business.
    final composed = ClientNamePolicy.composeSave(
      baseName: _nameController.text,
      phone: _phoneController.text,
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      type: _type,
    );
    return ClientRecord(
      id: '',
      name: composed.name,
      firstName: composed.firstName,
      lastName: composed.lastName,
      phone: _phoneController.text.trim(),
      email: _emailController.text.trim(),
      address: noFixedAddress ? '' : _buildFullAddress(),
      apt: noFixedAddress ? '' : _aptController.text.trim(),
      city: noFixedAddress ? '' : _cityController.text.trim(),
      province: noFixedAddress ? '' : _provinceController.text.trim(),
      postalCode: noFixedAddress ? '' : _postalCodeController.text.trim(),
      country: noFixedAddress ? '' : _countryController.text.trim(),
      noFixedAddress: noFixedAddress,
      accessNotes: _accessNotesController.text.trim(),
      type: _type,
    );
  }

  Future<void> _save({required AddClientNext next}) async {
    // The EXISTING validator, not a fast-capture variant: address is required
    // unless noFixedAddress is on, which is what makes that toggle meaningful.
    final nextErrors = ClientFormValidator.validate(
      l10n: context.l10n,
      name: _nameController.text.trim(),
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
      phone: _phoneController.text.trim(),
      mobile: '',
      email: _emailController.text.trim(),
      address: _addressController.text.trim(),
      additionalContacts: const [],
      noFixedAddress: noFixedAddress,
    );
    setState(() {
      errors
        ..clear()
        ..addAll(nextErrors);
    });
    if (errors.values.any((e) => e != null)) return;

    final outcome = await ref
        .read(clientFormControllerProvider.notifier)
        .addClient(_draft());
    if (!mounted) return;
    switch (outcome) {
      // A skipped duplicate submit committed nothing and failed nothing — the
      // save already running owns the outcome, so say nothing.
      case ClientSaveBusy():
        break;
      case ClientSaved(:final client):
        ref
            .read(analyticsServiceProvider)
            .logClientCreated(source: widget.analyticsSource);
        ref
            .read(noticeServiceProvider)
            .success(context.l10n.common_clientAdded);
        Navigator.pop(context, (client: client, next: next));
      case ClientSaveFailed(:final error):
        ref
            .read(noticeServiceProvider)
            .error(
              composeErrorNotice(
                context,
                intro: context.l10n.error_introAddClient,
                error: error,
              ),
            );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isSaving = ref.watch(clientFormControllerProvider);

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: true,
      stepKeys: _tour.keys,
      autoScroll: true,
      child: FormSheetFrame(
        title: l10n.clients_newClient,
        primaryLabel: l10n.common_add,
        heightFactor: 0.88,
        isBusy: isSaving,
        onPrimary: () => _save(next: AddClientNext.none),
        headerTourWrap: (child) => _tour.stepIf(TourStepId.clientSave, child),
        scrollCacheExtent: kTourScrollCacheExtent,
        children: [
          // First, so the person is told BEFORE filling the form in — the
          // submit controller already fails fast, and the app's global offline
          // banner is drawn under the page, behind this sheet.
          const OfflineFormNotice(),
          ..._whoSection(theme, l10n),
          ..._reachThemSection(theme, l10n),
          ..._siteSection(theme, l10n, isSaving: isSaving),
        ],
      ),
    );
  }

  /// Label + tour-wrapped body.
  List<Widget> _section(TourStepId id, String label, List<Widget> body) => [
    MonoSectionLabel(label),
    const SizedBox(height: AppSpacing.sp8),
    _tour.stepIf(
      id,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
    ),
  ];

  List<Widget> _whoSection(ThemeData theme, AppLocalizations l10n) => _section(
    TourStepId.clientWho,
    l10n.clients_sectionWho,
    [
      SheetFocusScroll(
        child: LabeledTextField(
          label: l10n.clients_nameOrBusiness,
          controller: _nameController,
          required: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.name],
          maxLength: TextLimits.personName,
          errorText: errors['name'],
          // LabeledTextField has no `onCleared` — its built-in ClearTextButton
          // routes through onChanged(''), so clearing the error here covers
          // both typing and the clear "x".
          onChanged: (_) {
            clearError('name');
            // Pulls a phone number out of what was just typed or pasted — quiet
            // unless the phone field is still empty.
            if (liftPhoneFromNameField(
              name: _nameController,
              phone: _phoneController,
            )) {
              setState(() => clearError('phone'));
            }
          },
        ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      // Owner change 6: always rendered, both optional.
      SheetFocusScroll(
        child: LabeledTextField(
          label: l10n.clients_firstName,
          controller: _firstNameController,
          optional: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.givenName],
          maxLength: TextLimits.firstName,
        ),
      ),
      const SizedBox(height: AppSpacing.sp16),
      SheetFocusScroll(
        child: LabeledTextField(
          label: l10n.clients_lastName,
          controller: _lastNameController,
          optional: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.familyName],
          maxLength: TextLimits.lastName,
        ),
      ),
      const SizedBox(height: AppSpacing.sp12),
      ClientTypeChips(
        value: _type,
        onChanged: (next) => setState(() => _type = next),
      ),
      const SizedBox(height: AppSpacing.sp24),
    ],
  );

  List<Widget> _reachThemSection(ThemeData theme, AppLocalizations l10n) =>
      _section(TourStepId.clientReach, l10n.clients_sectionReachThem, [
        SheetFocusScroll(
          child: LabeledTextField(
            label: l10n.clients_phone,
            controller: _phoneController,
            optional: true,
            keyboard: TextInputType.phone,
            inputFormatters: const [PhoneInputFormatter()],
            textInputAction: TextInputAction.next,
            maxLength: TextLimits.phone,
            errorText: errors['phone'],
            onChanged: (_) => clearError('phone'),
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        SheetFocusScroll(
          child: LabeledTextField(
            label: l10n.common_email,
            controller: _emailController,
            optional: true,
            keyboard: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            maxLength: TextLimits.email,
            errorText: errors['email'],
            onChanged: (_) => clearError('email'),
          ),
        ),
        const SizedBox(height: AppSpacing.sp24),

        // SITE keeps the full address block, because the appointment form's
        // inline add-client path opens this same sheet and the booking needs a
        // split address there.,
      ]);

  List<Widget> _siteSection(
    ThemeData theme,
    AppLocalizations l10n, {
    required bool isSaving,
  }) => _section(TourStepId.clientSite, l10n.clients_sectionSite, [
    Material(
      type: MaterialType.transparency,
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.clients_noFixedAddress),
        subtitle: Text(l10n.clients_noFixedAddressHint),
        value: noFixedAddress,
        activeTrackColor: theme.colorScheme.primary,
        onChanged: (value) => setNoFixedAddress(value: value),
      ),
    ),
    if (!noFixedAddress) ...[
      const SizedBox(height: AppSpacing.sp16),
      ClientAddressSection(
        addressController: _addressController,
        aptController: _aptController,
        cityController: _cityController,
        provinceController: _provinceController,
        postalCodeController: _postalCodeController,
        countryController: _countryController,
        isRequired: true,
        errorText: errors['address'],
        onAddressErrorCleared: () => clearError('address'),
      ),
    ],
    const SizedBox(height: AppSpacing.sp16),
    SheetFocusScroll(
      child: LabeledTextField(
        label: l10n.clients_accessNotes,
        hint: l10n.clients_accessNotesHint,
        controller: _accessNotesController,
        optional: true,
        maxLines: 2,
        textCapitalization: TextCapitalization.sentences,
        maxLength: TextLimits.clientAccessNotes,
      ),
    ),
    const SizedBox(height: AppSpacing.sp24),

    Text(
      l10n.clients_newClientCaption,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.palette.textTertiary,
      ),
    ),
    const SizedBox(height: AppSpacing.sp16),
    OutlinedButton(
      onPressed: isSaving ? null : () => _save(next: AddClientNext.bookJob),
      child: Text(l10n.clients_addAndBookAJob),
    ),
  ]);
}
