import 'package:cloud_functions/cloud_functions.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/maps/data/maps_error_mapper.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';
import 'package:scheduling/features/maps/domain/maps_failure.dart';
import 'package:scheduling/features/maps/domain/models/address_suggestion.dart';
import 'package:scheduling/features/maps/domain/models/parsed_address.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';

/// The deadline on every Places callable. Short on purpose: these back an
/// as-you-type field, so a slow response is worse than no response. Hoisted
/// because it was written out at all three call sites.
const Duration _callableTimeout = Duration(seconds: 10);

class GooglePlacesRepository implements PlacesRepository {
  GooglePlacesRepository({FirebaseFunctions? functions, AppLogger? logger})
    : _injectedFunctions = functions,
      _logger = logger ?? AppLogger();

  /// Resolved LAZILY, not in the constructor. `FirebaseFunctions.instance`
  /// reaches for the default Firebase app, so constructing this repository
  /// used to require Firebase to be initialized — which made merely BUILDING
  /// a widget that reads `placesRepositoryProvider` fail in every widget test,
  /// whether or not that test ever performs a lookup. The same lazy shape
  /// `AppointmentImageLoader` uses for its Storage handle.
  final FirebaseFunctions? _injectedFunctions;
  FirebaseFunctions get _functions =>
      _injectedFunctions ?? FirebaseFunctions.instance;

  final AppLogger _logger;

  @override
  Future<List<AddressSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
  }) async {
    if (input.trim().isEmpty) return const [];

    final stripped = AddressParser.splitApt(input)?.street ?? input;

    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'placesAutocomplete',
            options: HttpsCallableOptions(timeout: _callableTimeout),
          )
          .call({'input': stripped, 'sessionToken': sessionToken});
    } catch (e, st) {
      throw _logFailure(
        'ADDR-PLACES placesAutocomplete callable failed',
        e,
        st,
      );
    }

    try {
      // Android callables return Map<dynamic, dynamic>; cast loosely first.
      final data = (result.data as Map?)?.cast<String, dynamic>() ?? const {};
      return (data['suggestions'] as List? ?? [])
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => AddressSuggestion.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (e, st) {
      _logger.warn(
        'ADDR-PLACES placesAutocomplete response parse failed',
        e,
        st,
      );
      throw MapsFailureParse(cause: e, stackTrace: st);
    }
  }

  @override
  Future<ParsedAddress> getPlaceDetails(
    String placeId, {
    required String sessionToken,
  }) async {
    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'placesGetDetails',
            options: HttpsCallableOptions(timeout: _callableTimeout),
          )
          .call({'placeId': placeId, 'sessionToken': sessionToken});
    } catch (e, st) {
      throw _logFailure('ADDR-PLACES placesGetDetails callable failed', e, st);
    }

    try {
      // Android callables return Map<dynamic, dynamic>; cast loosely first.
      final data = (result.data as Map?)?.cast<String, dynamic>() ?? const {};
      final components = (data['addressComponents'] as List? ?? [])
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

      var unit = '';
      var streetNumber = '';
      var route = '';
      var city = '';
      var province = '';
      var postalCode = '';

      for (final c in components) {
        // `whereType`, not `cast`: a cast is lazy, so a non-string entry in
        // the array throws later at the `contains` call rather than here.
        final types = (c['types'] as List? ?? const []).whereType<String>();
        final longText = c['longText']?.toString() ?? '';
        final shortText = c['shortText']?.toString() ?? '';

        if (types.contains('subpremise')) unit = longText;
        if (types.contains('street_number')) streetNumber = longText;
        if (types.contains('route')) route = longText;
        if (types.contains('locality')) city = longText;
        if (types.contains('administrative_area_level_1')) province = shortText;
        if (types.contains('postal_code')) postalCode = longText;
      }

      final baseStreet = [
        streetNumber,
        route,
      ].where((e) => e.isNotEmpty).join(' ').trim();

      final street = unit.isNotEmpty && baseStreet.isNotEmpty
          ? '$unit-$baseStreet'
          : baseStreet;

      return ParsedAddress(
        fullAddress: data['formattedAddress']?.toString() ?? '',
        street: street,
        city: city,
        province: province,
        postalCode: postalCode,
      );
    } catch (e, st) {
      _logger.warn('ADDR-PLACES placesGetDetails response parse failed', e, st);
      throw MapsFailureParse(cause: e, stackTrace: st);
    }
  }

  @override
  Future<String?> reverseGeocode({
    required double lat,
    required double lng,
    required String locale,
  }) async {
    final HttpsCallableResult<dynamic> result;
    try {
      result = await _functions
          .httpsCallable(
            'placesReverseGeocode',
            options: HttpsCallableOptions(timeout: _callableTimeout),
          )
          .call({'lat': lat, 'lng': lng, 'locale': locale});
    } catch (e, st) {
      throw _logFailure(
        'ADDR-PLACES placesReverseGeocode callable failed',
        e,
        st,
      );
    }

    try {
      // Android callables can return Map<dynamic, dynamic>, so loosen before
      // casting to the app's expected shape.
      final data = (result.data as Map?)?.cast<String, dynamic>() ?? const {};
      return data['address']?.toString();
    } catch (e, st) {
      _logger.warn(
        'ADDR-PLACES placesReverseGeocode response parse failed',
        e,
        st,
      );
      throw MapsFailureParse(cause: e, stackTrace: st);
    }
  }

  /// Maps [e]; a server-side pause is an operator state, so only a breadcrumb.
  MapsFailure _logFailure(String label, Object e, StackTrace st) {
    final failure = MapsErrorMapper.map(e, st);
    if (failure is MapsFailurePaused) {
      _logger.breadcrumb('$label (feature paused)');
    } else {
      _logger.warn(label, e, st);
    }
    return failure;
  }
}
