import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/errors/failure.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/features/maps/domain/maps_failure.dart';
import 'package:scheduling/features/maps/domain/models/address_suggestion.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/attached_dropdown.dart';
import 'package:scheduling/shared/widgets/fields/clear_text_button.dart';
import 'package:scheduling/shared/widgets/fields/labeled_text_field.dart';
import 'package:uuid/uuid.dart';

class AddressAutocompleteField extends ConsumerStatefulWidget {
  const AddressAutocompleteField({
    required this.controller,
    super.key,
    this.label,
    this.required = false,
    this.optional = false,
    this.errorText,
    this.onChanged,
    this.onAddressSelected,
  });

  final TextEditingController controller;
  final String? label;
  final bool required;
  final bool optional;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onAddressSelected;

  @override
  ConsumerState<AddressAutocompleteField> createState() =>
      _AddressAutocompleteFieldState();
}

class _AddressAutocompleteFieldState
    extends ConsumerState<AddressAutocompleteField> {
  late final PlacesRepository _service;
  late final AppLogger _logger;
  static const _uuid = Uuid();
  late final Debouncer _debounce;
  List<AddressSuggestion> _suggestions = [];
  bool _isLoading = false;
  String? _serviceError;
  bool _suppressFetch = false;
  String? _sessionToken;
  String _lastTypedApt = '';
  String _lastFetched = '';

  /// Request id used to discard stale responses that come back late.
  int _requestId = 0;

  static const _minQueryLength = 3;

  @override
  void initState() {
    super.initState();
    // Eager, not lazy `late final`s: the handlers run after this field can be gone.
    _logger = ref.read(loggerProvider);
    _service = ref.read(placesRepositoryProvider);
    _debounce = Debouncer.tagged(
      kAddressLookupDebounce,
      logger: _logger,
      tag: 'ADDR-AUTO debounced action failed',
    );
  }

  @override
  void dispose() {
    _debounce.dispose();
    super.dispose();
  }

  String _ensureSessionToken() => _sessionToken ??= _uuid.v4();

  void _onTextChanged(String value) {
    widget.onChanged?.call(value);
    if (_suppressFetch) {
      _suppressFetch = false;
      return;
    }

    if (!ref.read(featureFlagsProvider).addressAutocomplete) {
      _onAutocompletePaused();
      return;
    }

    _debounce.cancel();
    final trimmed = value.trim();
    if (trimmed.length < _minQueryLength) {
      _lastFetched = '';
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _serviceError = null;
      });
      return;
    }

    _debounce.run(() => _fetch(value));
  }

  String _localizedErrorFor(
    Object error,
    BuildContext context,
    String fallback,
  ) {
    if (error is Failure) return error.toLocalizedMessage(context);
    return fallback;
  }

  Future<void> _fetch(String query) async {
    if (!mounted || !ref.read(featureFlagsProvider).addressAutocomplete) return;
    // Skip re-fetching the exact query we already fetched successfully, so we
    // don't bill for an identical call. This is only set on success, so a
    // failed fetch will still retry.
    if (query == _lastFetched) return;
    final requestId = ++_requestId;
    // Logger resolved BEFORE the await: `ref.read` throws once unmounted (ADR-0033).
    setState(() {
      _isLoading = true;
      _serviceError = null;
    });
    _lastTypedApt = AddressParser.splitApt(query)?.apt ?? '';
    try {
      final results = await _service.autocomplete(
        query,
        sessionToken: _ensureSessionToken(),
      );
      if (!mounted || requestId != _requestId) return;
      _lastFetched = query;
      setState(() {
        _suggestions = results;
        _isLoading = false;
      });
    } catch (e, st) {
      // A typed failure (a server pause included) was logged by the repository.
      if (e is! Failure) _logger.warn('ADDR-AUTO autocomplete failed', e, st);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _suggestions = [];
        _isLoading = false;
        _serviceError = _localizedErrorFor(
          e,
          context,
          context.l10n.error_addressLookupFailed,
        );
      });
    }
  }

  /// The clear button empties the controller itself; this tears down the
  /// lookup that was running for the text it wiped. `onChanged` has to be
  /// called by hand — a programmatic `controller.clear()` never fires the
  /// field's own, so the host would keep the address it can no longer see.
  void _onCleared() {
    _debounce.cancel();
    // Discards a response already in flight for the old query.
    _requestId++;
    _lastFetched = '';
    _lastTypedApt = '';
    widget.onChanged?.call('');
    setState(() {
      _suggestions = [];
      _isLoading = false;
      _serviceError = null;
    });
  }

  /// Drops the list and any pending lookup when the kill switch pauses.
  void _onAutocompletePaused() {
    _debounce.cancel();
    _requestId++;
    _lastFetched = '';
    if (_suggestions.isEmpty && !_isLoading && _serviceError == null) return;
    setState(() {
      _suggestions = [];
      _isLoading = false;
      _serviceError = null;
    });
  }

  Future<void> _selectSuggestion(AddressSuggestion s) async {
    // Invalidate any pending debounce/in-flight request so a late response can't resurface suggestions.
    _debounce.cancel();
    _requestId++;
    _suppressFetch = true;
    var base = s.description;
    String? error;
    // Paused: Places would refuse the details call, so keep the shown text.
    if (ref.read(featureFlagsProvider).addressAutocomplete) {
      widget.controller.text = s.description;
      setState(() {
        _suggestions = [];
        _isLoading = true;
      });
      try {
        final details = await _service.getPlaceDetails(
          s.placeId,
          sessionToken: _ensureSessionToken(),
        );
        if (details.fullAddress.isNotEmpty) base = details.fullAddress;
      } on MapsFailurePaused {
        // Logged by the repository; keep the shown text.
      } catch (e, st) {
        if (e is! Failure) {
          _logger.warn('ADDR-DETAILS getPlaceDetails failed', e, st);
        }
        if (mounted) {
          error = _localizedErrorFor(
            e,
            context,
            context.l10n.error_couldNotLoadAddressDetails,
          );
        }
      }
      if (!mounted) return;
    } else {
      // Otherwise a re-enable would skip the pre-pause query as already fetched.
      _lastFetched = '';
    }
    _suppressFetch = true;
    widget.controller.text = AddressParser.formatForDisplay(
      base,
      _lastTypedApt,
    );
    _sessionToken = null;
    _lastTypedApt = '';
    setState(() {
      _suggestions = [];
      _isLoading = false;
      _serviceError = error;
    });
    widget.onAddressSelected?.call(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(featureFlagsProvider.select((f) => f.addressAutocomplete), (
      _,
      enabled,
    ) {
      if (!enabled) _onAutocompletePaused();
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTextField(context),
        if (_suggestions.isNotEmpty)
          AttachedDropdown(
            children: [
              for (final s in _suggestions) _buildSuggestionRow(context, s),
            ],
          ),
        if (_serviceError != null) _buildServiceError(context),
      ],
    );
  }

  Widget _buildTextField(BuildContext context) {
    return LabeledTextField(
      label: widget.label ?? context.l10n.common_address,
      controller: widget.controller,
      required: widget.required,
      optional: widget.optional,
      keyboard: TextInputType.streetAddress,
      autofillHints: const [AutofillHints.fullStreetAddress],
      maxLength: TextLimits.appointmentAddress,
      errorText: widget.errorText,
      onChanged: _onTextChanged,
      // ClearTextButton's placeholder: the pin while empty, the x once filled.
      suffixIcon: _isLoading
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.sp12),
              child: AdaptiveProgressIndicator(size: 16),
            )
          : ClearTextButton(
              controller: widget.controller,
              onCleared: _onCleared,
              placeholder: Icon(
                Icons.location_on_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }

  Widget _buildSuggestionRow(BuildContext context, AddressSuggestion s) {
    final leading = Icon(
      Icons.location_on_outlined,
      size: 18,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    if (s.mainText.trim().isEmpty) {
      return AttachedDropdownRow(
        leading: leading,
        headline: s.description,
        // Flat fallback: two lines, or the town ellipsises off most addresses.
        headlineMaxLines: 2,
        headlineStyle: Theme.of(context).textTheme.bodyMedium,
        onTap: () => _selectSuggestion(s),
      );
    }
    return AttachedDropdownRow(
      leading: leading,
      headline: s.mainText,
      detail: s.secondaryText,
      semanticLabel: s.description.isNotEmpty ? s.description : null,
      onTap: () => _selectSuggestion(s),
    );
  }

  Widget _buildServiceError(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sp8, left: AppSpacing.sp4),
      child: Text(
        _serviceError!,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
