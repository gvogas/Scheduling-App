import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
import 'package:scheduling/core/errors/failure.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/debouncer.dart';
import 'package:scheduling/core/validators/text_limits.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
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
    // Both eager, not lazy `late final`s: the debounce error handler and the
    // two post-await catches all run after this field can be gone, and
    // `ref.read` on an unmounted consumer throws under Riverpod 3. A lazy
    // initializer is one moved line away from being first touched below an
    // await.
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
    // Skip re-fetching the exact query we already fetched successfully, so we
    // don't bill for an identical call. This is only set on success, so a
    // failed fetch will still retry.
    if (query == _lastFetched) return;
    final requestId = ++_requestId;
    // Resolved BEFORE the await, not inside the catch. `AppLogger` is
    // context-free and the log must survive unmount — but `ref.read` is not:
    // under Riverpod 3 it THROWS a StateError once the consumer is unmounted.
    // This method runs from a Debouncer timer with no error handler, so that
    // throw escaped to the zone handler as a FATAL — on the most-used field in
    // the app, whenever a lookup failed after the sheet was dismissed. Holding
    // the logger keeps both properties.
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
      // Logged before the mounted guard so it reaches Crashlytics even if the
      // field is gone by then — through the logger captured above.
      _logger.warn('ADDR-AUTO autocomplete failed', e, st);
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

  Future<void> _selectSuggestion(AddressSuggestion s) async {
    // Resolved BEFORE the await for the same reason as _fetch above — this is
    // fired from onTap, so the sheet being dismissed before Places responds is
    // routine, and `ref.read` on an unmounted consumer throws.
    // Invalidate any pending debounce/in-flight request so a late response can't resurface suggestions.
    _debounce.cancel();
    _requestId++;
    _suppressFetch = true;
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
      if (!mounted) return;
      _suppressFetch = true;
      final base = details.fullAddress.isNotEmpty
          ? details.fullAddress
          : s.description;
      widget.controller.text = AddressParser.formatForDisplay(
        base,
        _lastTypedApt,
      );
      setState(() => _isLoading = false);
      widget.onAddressSelected?.call(widget.controller.text);
    } catch (e, st) {
      _logger.warn('ADDR-DETAILS getPlaceDetails failed', e, st);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _serviceError = _localizedErrorFor(
          e,
          context,
          context.l10n.error_couldNotLoadAddressDetails,
        );
      });
      widget.onAddressSelected?.call(widget.controller.text);
    } finally {
      _sessionToken = null;
      _lastTypedApt = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledTextField(
          label: widget.label ?? context.l10n.common_address,
          controller: widget.controller,
          required: widget.required,
          optional: widget.optional,
          keyboard: TextInputType.streetAddress,
          autofillHints: const [AutofillHints.fullStreetAddress],
          maxLength: TextLimits.appointmentAddress,
          errorText: widget.errorText,
          onChanged: _onTextChanged,
          // The custom suffix used to cost this field the clear "x" every
          // other text field gets. ClearTextButton's placeholder slot is
          // exactly this case: the pin while empty, the x once there is an
          // address to wipe.
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
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
        if (_suggestions.isNotEmpty)
          AttachedDropdown(
            children: [
              for (final s in _suggestions)
                AttachedDropdownRow(
                  leading: Icon(
                    Icons.location_on_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  headline: s.description,
                  // An address is the whole answer and runs long; one line
                  // ellipsised the town off the end of most of them.
                  headlineMaxLines: 2,
                  headlineStyle: Theme.of(context).textTheme.bodyMedium,
                  onTap: () => _selectSuggestion(s),
                ),
            ],
          ),
        if (_serviceError != null)
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.sp8,
              left: AppSpacing.sp4,
            ),
            child: Text(
              _serviceError!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}
