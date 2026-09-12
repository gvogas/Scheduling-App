import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/address_autocomplete_field.dart';
import 'package:scheduling/shared/widgets/fields/form_helpers.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

class AppointmentAddressField extends StatelessWidget {
  const AppointmentAddressField({
    required this.selectedClient,
    required this.useCustomAddress,
    required this.addressController,
    required this.onSwitchToCustom,
    required this.onUseClientAddress,
    super.key,
    this.optional = false,
  });

  final ClientRecord? selectedClient;
  final bool useCustomAddress;
  final TextEditingController addressController;

  /// Marks the field "(Optional)". Set on a personal job, which may name a
  /// place but doesn't have to — a client visit always has one to show, either
  /// the client's or a custom one.
  final bool optional;

  final VoidCallback onSwitchToCustom;
  final VoidCallback onUseClientAddress;

  @override
  Widget build(BuildContext context) {
    final showPill = selectedClient != null && !useCustomAddress;
    final scheme = Theme.of(context).colorScheme;
    // This block names itself; the form must not label it as well.
    final label = context.l10n.calendar_jobAddress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showPill) ...[
          formLabel(context, label, required: !optional, optional: optional),
          _AddressPill(client: selectedClient!, onChange: onSwitchToCustom),
        ] else ...[
          SheetFocusScroll(
            child: AddressAutocompleteField(
              controller: addressController,
              label: label,
              required: !optional,
              optional: optional,
            ),
          ),
          if (selectedClient != null &&
              useCustomAddress &&
              selectedClient!.address.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sp8),
            GestureDetector(
              onTap: onUseClientAddress,
              child: Text(
                context.l10n.calendar_useClientsAddress,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.client, required this.onChange});

  final ClientRecord client;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final address = client.address.isNotEmpty
        ? client.fullAddress
        : context.l10n.calendar_noAddress;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp8,
        AppSpacing.sp8,
        AppSpacing.sp12,
        AppSpacing.sp8,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.r12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(AppRadius.r8),
            ),
            child: Icon(
              Icons.location_on_outlined,
              color: scheme.onPrimary,
              size: 16,
            ),
          ),
          const SizedBox(width: AppSpacing.sp8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.calendar_clientSAddress,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sp4),
                Text(
                  address,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.onSurface),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sp8,
                vertical: AppSpacing.sp4,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              context.l10n.calendar_changeAddress,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
