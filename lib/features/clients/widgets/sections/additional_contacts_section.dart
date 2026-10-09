import 'package:flutter/material.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_contacts_policy.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

class ContactFields {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController emailController = TextEditingController();

  bool get isEmpty =>
      nameController.text.trim().isEmpty &&
      phoneController.text.trim().isEmpty &&
      emailController.text.trim().isEmpty;

  ClientContact toContact() => ClientContact(
    name: nameController.text.trim(),
    phone: phoneController.text.trim(),
    email: emailController.text.trim(),
  );

  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    emailController.dispose();
  }
}

class AdditionalContactsSection extends StatelessWidget {
  const AdditionalContactsSection({
    required this.contacts,
    required this.errors,
    required this.onAddContact,
    required this.onRemoveContact,
    required this.onClearError,
    super.key,
  });

  final List<ContactFields> contacts;
  final Map<String, String?> errors;
  final VoidCallback onAddContact;
  final ValueChanged<int> onRemoveContact;
  final ValueChanged<String> onClearError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = context.isCompact;
    final canAdd = contacts.length < kMaxAdditionalContacts;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sp16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.r16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact)
            _buildStackedHeader(context, theme, canAdd)
          else
            _buildInlineHeader(context, theme, canAdd),
          const SizedBox(height: AppSpacing.sp4),
          _buildHint(context, theme, scheme),
          if (!canAdd) ...[
            const SizedBox(height: AppSpacing.sp8),
            Text(
              context.l10n.clients_additionalContactsLimit(
                kMaxAdditionalContacts,
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          if (contacts.isEmpty) ...[
            const SizedBox(height: AppSpacing.sp12),
            OutlinedButton.icon(
              onPressed: canAdd ? onAddContact : null,
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(context.l10n.clients_addAnotherContact),
            ),
          ],
          for (var i = 0; i < contacts.length; i++) ...[
            const SizedBox(height: AppSpacing.sp16),
            _AdditionalContactCard(
              index: i,
              contact: contacts[i],
              errors: errors,
              onRemove: () => onRemoveContact(i),
              onClearError: onClearError,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStackedHeader(
    BuildContext context,
    ThemeData theme,
    bool canAdd,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.clients_additionalBusinessContacts,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.sp8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: canAdd ? onAddContact : null,
            icon: const Icon(Icons.add),
            label: Text(context.l10n.clients_add),
          ),
        ),
      ],
    );
  }

  Widget _buildInlineHeader(
    BuildContext context,
    ThemeData theme,
    bool canAdd,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            context.l10n.clients_additionalBusinessContacts,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: canAdd ? onAddContact : null,
          icon: const Icon(Icons.add),
          label: Text(context.l10n.clients_add),
        ),
      ],
    );
  }

  Widget _buildHint(BuildContext context, ThemeData theme, ColorScheme scheme) {
    return Text(
      context
          .l10n
          .clients_theFirstContactIsTheMainContactAboveAddMoreContactsHereIfNeeded,
      style: theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

class _AdditionalContactCard extends StatelessWidget {
  const _AdditionalContactCard({
    required this.index,
    required this.contact,
    required this.errors,
    required this.onRemove,
    required this.onClearError,
  });

  final int index;
  final ContactFields contact;
  final Map<String, String?> errors;
  final VoidCallback onRemove;
  final ValueChanged<String> onClearError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sp12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, theme),
          const SizedBox(height: AppSpacing.sp8),
          _nameField(context),
          const SizedBox(height: AppSpacing.sp12),
          _phoneField(context),
          const SizedBox(height: AppSpacing.sp12),
          _emailField(context),
        ],
      ),
    );
  }

  /// "Contact N" and its remove button.
  Widget _header(BuildContext context, ThemeData theme) {
    final title = Text(
      '${context.l10n.clients_contact} ${index + 1}',
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    );
    final removeButton = IconButton(
      tooltip: context.l10n.clients_removeContact,
      onPressed: onRemove,
      icon: const Icon(Icons.close),
    );

    if (!context.isCompact) {
      return Row(
        children: [
          Expanded(child: title),
          removeButton,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: AppSpacing.sp4),
        Align(alignment: Alignment.centerLeft, child: removeButton),
      ],
    );
  }

  Widget _nameField(BuildContext context) => SheetFocusScroll(
    child: LabeledTextField(
      label: context.l10n.clients_contactName,
      controller: contact.nameController,
      required: true,
      textCapitalization: TextCapitalization.words,
      autofillHints: const [AutofillHints.name],
      maxLength: TextLimits.personName,
      errorText: errors['contact_${index}_name'],
      onChanged: (_) => onClearError('contact_${index}_name'),
    ),
  );

  Widget _phoneField(BuildContext context) => SheetFocusScroll(
    child: LabeledTextField(
      label: context.l10n.clients_phone,
      controller: contact.phoneController,
      keyboard: TextInputType.phone,
      inputFormatters: const [PhoneInputFormatter()],
      autofillHints: const [AutofillHints.telephoneNumber],
      maxLength: TextLimits.phone,
      errorText: errors['contact_${index}_phone'],
      onChanged: (_) => onClearError('contact_${index}_phone'),
    ),
  );

  /// Clearing the PHONE error from the email field is deliberate: the "one of
  /// phone or email" rule reports on the phone row, so supplying an email is
  /// what resolves it.
  Widget _emailField(BuildContext context) => SheetFocusScroll(
    child: LabeledTextField(
      label: context.l10n.common_email,
      controller: contact.emailController,
      keyboard: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      maxLength: TextLimits.email,
      errorText: errors['contact_${index}_email'],
      onChanged: (_) {
        onClearError('contact_${index}_email');
        onClearError('contact_${index}_phone');
      },
    ),
  );
}
