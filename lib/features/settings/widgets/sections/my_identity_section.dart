import 'package:flutter/material.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/cards/sheet_panel.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// What [MyIdentitySection] hands back on Save.
@immutable
class MyIdentityEdit {
  const MyIdentityEdit({
    required this.phone,
    required this.emergencyContact,
    required this.emergencyPhone,
  });

  final String phone;
  final String emergencyContact;
  final String emergencyPhone;
}

/// The identity values a person may change about themselves.
///
/// **Explicitly saved, deliberately** (owner call, 2026-08-10). The availability
/// controls below this section apply the instant they are tapped, but these are
/// free-text identity fields: a half-typed phone number auto-committing is both
/// a bad write and a bad feeling, and there is no undo for one. The bar appears
/// only once the form is dirty, so a screen that has merely been read shows no
/// call to action.
///
/// Keep the two behaviours distinct rather than unifying them in either
/// direction — a switch that needs confirming reads as broken, and a text field
/// that saves itself reads as unsafe.
class MyIdentitySection extends StatefulWidget {
  const MyIdentitySection({
    required this.email,
    required this.initialPhone,
    required this.initialEmergencyContact,
    required this.initialEmergencyPhone,
    required this.isSaving,
    required this.onSave,
    required this.onChangeEmail,
    super.key,
  });

  final String email;
  final String initialPhone;
  final String initialEmergencyContact;
  final String initialEmergencyPhone;
  final bool isSaving;
  final Future<void> Function(MyIdentityEdit edit) onSave;

  /// Null until the callable's `self` branch ships, which renders the email row
  /// read-only. It must never become a plain users-doc write: `email` is a
  /// sign-in identity, and Auth and Firestore move together or not at all.
  final VoidCallback? onChangeEmail;

  @override
  State<MyIdentitySection> createState() => _MyIdentitySectionState();
}

class _MyIdentitySectionState extends State<MyIdentitySection> {
  late final _phone = TextEditingController(text: widget.initialPhone);
  late final _contact = TextEditingController(
    text: widget.initialEmergencyContact,
  );
  late final _emergencyPhone = TextEditingController(
    text: widget.initialEmergencyPhone,
  );

  bool _isDirty = false;

  List<TextEditingController> get _controllers => [
    _phone,
    _contact,
    _emergencyPhone,
  ];

  @override
  void initState() {
    super.initState();
    for (final controller in _controllers) {
      controller.addListener(_recomputeDirty);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller
        ..removeListener(_recomputeDirty)
        ..dispose();
    }
    super.dispose();
  }

  /// The STORED values are the other half of the comparison, so a save that
  /// commits them has to re-run it — the controllers don't change, so nothing
  /// else would. Without this the Save/Discard bar the section documents as
  /// appearing "only once the form is dirty" survived its own successful save
  /// (with Discard as a visible no-op) until the next keystroke.
  ///
  /// No `setState`: a rebuild is already in flight when this runs.
  @override
  void didUpdateWidget(MyIdentitySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _isDirty = _computeDirty();
  }

  /// Recomputed against the STORED values rather than latched as a one-way
  /// flag, so typing a change and typing it back reads as pristine again and
  /// the bar stops offering to save nothing.
  void _recomputeDirty() {
    final dirty = _computeDirty();
    if (dirty != _isDirty) setState(() => _isDirty = dirty);
  }

  bool _computeDirty() =>
      _phone.text != widget.initialPhone ||
      _contact.text != widget.initialEmergencyContact ||
      _emergencyPhone.text != widget.initialEmergencyPhone;

  void _discard() {
    _phone.text = widget.initialPhone;
    _contact.text = widget.initialEmergencyContact;
    _emergencyPhone.text = widget.initialEmergencyPhone;
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoSectionLabel(l10n.settings_myDetailsIdentity),
        const SizedBox(height: AppSpacing.sp8),
        Text(
          l10n.settings_myDetailsIdentityBlurb,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        _buildFieldsPanel(l10n),
        if (_isDirty) ...[
          const SizedBox(height: AppSpacing.sp16),
          _SaveBar(
            key: const Key('myIdentitySaveBar'),
            isSaving: widget.isSaving,
            onDiscard: _discard,
            onSave: () => widget.onSave(
              MyIdentityEdit(
                phone: _phone.text,
                emergencyContact: _contact.text,
                emergencyPhone: _emergencyPhone.text,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFieldsPanel(AppLocalizations l10n) {
    return SheetPanel(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sp16),
          child: Column(
            children: [
              LabeledTextField(
                key: const Key('myPhone'),
                label: l10n.employees_phoneNumber,
                controller: _phone,
                keyboard: TextInputType.phone,
                inputFormatters: const [PhoneInputFormatter()],
                maxLength: TextLimits.phone,
              ),
              const SizedBox(height: AppSpacing.sp16),
              _EmailRow(
                email: widget.email,
                onChangeEmail: widget.onChangeEmail,
              ),
              const SizedBox(height: AppSpacing.sp16),
              LabeledTextField(
                key: const Key('myEmergencyContact'),
                label: l10n.employees_emergencyContact,
                controller: _contact,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: TextLimits.employeeEmergencyContact,
              ),
              const SizedBox(height: AppSpacing.sp16),
              LabeledTextField(
                key: const Key('myEmergencyPhone'),
                label: l10n.employees_emergencyPhone,
                controller: _emergencyPhone,
                keyboard: TextInputType.phone,
                inputFormatters: const [PhoneInputFormatter()],
                maxLength: TextLimits.phone,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Read-only until the self-service email change ships. The row still shows the
/// address, because "what do I sign in with" is the question this screen is
/// most often opened to answer.
class _EmailRow extends StatelessWidget {
  const _EmailRow({required this.email, required this.onChangeEmail});

  final String email;
  final VoidCallback? onChangeEmail;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.common_email,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sp4),
        Row(
          children: [
            Expanded(
              child: Text(
                email,
                style: theme.textTheme.bodyLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onChangeEmail != null)
              TextButton(
                key: const Key('myChangeEmail'),
                onPressed: onChangeEmail,
                child: Text(l10n.common_edit),
              ),
          ],
        ),
        if (onChangeEmail == null)
          Text(
            l10n.settings_myDetailsEmailReadOnly,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.isSaving,
    required this.onDiscard,
    required this.onSave,
    super.key,
  });

  final bool isSaving;
  final VoidCallback onDiscard;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    final discard = TextButton(
      key: const Key('myIdentityDiscard'),
      onPressed: isSaving ? null : onDiscard,
      child: Text(l10n.common_discard),
    );
    final save = AnimatedLoadingButton(
      key: const Key('myIdentitySave'),
      label: l10n.common_save,
      isLoading: isSaving,
      onPressed: onSave,
    );

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sp12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.r12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settings_unsavedChanges,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sp8),
          // Folds to a column on a small phone or at large text, the same gate
          // every other dense row in the app uses.
          if (context.isCompact)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                save,
                const SizedBox(height: AppSpacing.sp8),
                discard,
              ],
            )
          else
            Row(
              children: [
                Expanded(child: discard),
                const SizedBox(width: AppSpacing.sp8),
                Expanded(child: save),
              ],
            ),
        ],
      ),
    );
  }
}
