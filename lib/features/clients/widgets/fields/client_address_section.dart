import 'package:flutter/material.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/clients/widgets/fields/address_grid_fields.dart';
import 'package:scheduling/features/maps/address_field_filler.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/address_autocomplete_field.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_widgets.dart';

/// Street-address block shared by the add/edit forms. When the user picks an
/// autocomplete suggestion, this splits the address out across the controllers.
class ClientAddressSection extends StatefulWidget {
  const ClientAddressSection({
    required this.addressController,
    required this.aptController,
    required this.cityController,
    required this.provinceController,
    required this.postalCodeController,
    required this.countryController,
    required this.isRequired,
    required this.onAddressErrorCleared,
    this.errorText,
    super.key,
  });

  final TextEditingController addressController;
  final TextEditingController aptController;
  final TextEditingController cityController;
  final TextEditingController provinceController;
  final TextEditingController postalCodeController;
  final TextEditingController countryController;
  final bool isRequired;
  final String? errorText;
  final VoidCallback onAddressErrorCleared;

  @override
  State<ClientAddressSection> createState() => _ClientAddressSectionState();
}

class _ClientAddressSectionState extends State<ClientAddressSection> {
  List<TextEditingController> get _allControllers => [
    widget.addressController,
    widget.aptController,
    widget.cityController,
    widget.provinceController,
    widget.postalCodeController,
    widget.countryController,
  ];

  void _clearAddress() {
    for (final controller in _allControllers) {
      controller.clear();
    }
    widget.onAddressErrorCleared();
  }

  // Deferred to a microtask so the autocomplete field finishes writing its controller
  // before we split the address out across the other fields.
  void _handleAddressSelected() {
    Future<void>.microtask(() {
      if (!mounted) return;
      fillAddressControllersFromText(
        widget.addressController.text,
        address: widget.addressController,
        apt: widget.aptController,
        city: widget.cityController,
        province: widget.provinceController,
        postalCode: widget.postalCodeController,
        country: widget.countryController,
      );
      widget.onAddressErrorCleared();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetFocusScroll(
          child: AddressAutocompleteField(
            controller: widget.addressController,
            required: widget.isRequired,
            errorText: widget.errorText,
            onChanged: (_) => widget.onAddressErrorCleared(),
            onAddressSelected: (_) => _handleAddressSelected(),
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        SheetFocusScroll(
          child: LabeledTextField(
            label: context.l10n.clients_aptUnit,
            controller: widget.aptController,
            optional: true,
            maxLength: TextLimits.aptUnit,
          ),
        ),
        const SizedBox(height: AppSpacing.sp16),
        AddressGridFields(
          cityController: widget.cityController,
          provinceController: widget.provinceController,
          postalCodeController: widget.postalCodeController,
          countryController: widget.countryController,
        ),
        // One-tap wipe of the whole block (street, apt, and the grid). It stays
        // hidden while every address field is already empty.
        ListenableBuilder(
          listenable: Listenable.merge(_allControllers),
          builder: (context, _) {
            final hasAny = _allControllers.any((c) => c.text.trim().isNotEmpty);
            if (!hasAny) return const SizedBox.shrink();
            return Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: _clearAddress,
                icon: const Icon(Icons.backspace_outlined, size: 16),
                label: Text(context.l10n.clients_clearAddress),
              ),
            );
          },
        ),
      ],
    );
  }
}
