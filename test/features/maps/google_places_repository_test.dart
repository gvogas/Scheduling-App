import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/maps/data/google_places_repository.dart';
import 'package:scheduling/features/maps/domain/maps_failure.dart';

class _MockFunctions extends Mock implements FirebaseFunctions {}

class _MockCallable extends Mock implements HttpsCallable {}

class _MockResult extends Mock implements HttpsCallableResult<dynamic> {}

class _FakeHttpsCallableOptions extends Fake implements HttpsCallableOptions {}

class _MockLogger extends Mock implements AppLogger {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeHttpsCallableOptions());
  });

  late _MockFunctions functions;
  late _MockCallable autocomplete;
  late _MockCallable details;
  late _MockCallable reverseGeocode;
  late GooglePlacesRepository repo;

  setUp(() {
    functions = _MockFunctions();
    autocomplete = _MockCallable();
    details = _MockCallable();
    reverseGeocode = _MockCallable();
    when(
      () => functions.httpsCallable(
        any(that: equals('placesAutocomplete')),
        options: any(named: 'options'),
      ),
    ).thenReturn(autocomplete);
    when(
      () => functions.httpsCallable(
        any(that: equals('placesGetDetails')),
        options: any(named: 'options'),
      ),
    ).thenReturn(details);
    when(
      () => functions.httpsCallable(
        any(that: equals('placesReverseGeocode')),
        options: any(named: 'options'),
      ),
    ).thenReturn(reverseGeocode);
    repo = GooglePlacesRepository(functions: functions);
  });

  group('autocomplete', () {
    test(
      'parses the suggestions payload into AddressSuggestion list',
      () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'suggestions': [
            {
              'placePrediction': {
                'placeId': 'abc123',
                'text': {'text': '1234 Rue Saint-Denis, Montréal, QC'},
              },
            },
            {
              'placePrediction': {
                'placeId': 'def456',
                'text': {'text': '999 Rue Sherbrooke, Montréal, QC'},
              },
            },
          ],
        });
        when(
          () => autocomplete.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final suggestions = await repo.autocomplete(
          '1234 Rue Saint-Denis',
          sessionToken: 'token-1',
        );

        expect(suggestions, hasLength(2));
        expect(suggestions[0].placeId, 'abc123');
        expect(
          suggestions[0].description,
          '1234 Rue Saint-Denis, Montréal, QC',
        );
        expect(suggestions[1].placeId, 'def456');
      },
    );

    test(
      'strips the apt prefix before sending input to the callable',
      () async {
        final result = _MockResult();
        when(
          () => result.data,
        ).thenReturn(<String, dynamic>{'suggestions': const <dynamic>[]});
        when(
          () => autocomplete.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        await repo.autocomplete(
          '5-1234 Rue Saint-Denis',
          sessionToken: 'token-1',
        );

        final captured =
            verify(
                  () => autocomplete.call<dynamic>(captureAny<Object?>()),
                ).captured.single
                as Map<String, dynamic>;
        expect(captured['input'], '1234 Rue Saint-Denis');
        expect(captured['sessionToken'], 'token-1');
      },
    );

    test(
      'returns empty list for whitespace input without calling the callable',
      () async {
        final suggestions = await repo.autocomplete(
          '   ',
          sessionToken: 'token-1',
        );

        expect(suggestions, isEmpty);
        verifyNever(() => autocomplete.call<dynamic>(any<Object?>()));
      },
    );

    test(
      'FirebaseFunctionsException(resource-exhausted) → RateLimit',
      () async {
        when(() => autocomplete.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'resource-exhausted',
            message: 'too-many-places-requests',
          ),
        );

        expect(
          () => repo.autocomplete('1234 Main', sessionToken: 't'),
          throwsA(isA<MapsFailureRateLimit>()),
        );
      },
    );

    test(
      'FirebaseFunctionsException(unauthenticated) → Unauthorized',
      () async {
        when(() => autocomplete.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'unauthenticated',
            message: 'auth-required',
          ),
        );

        expect(
          () => repo.autocomplete('1234 Main', sessionToken: 't'),
          throwsA(isA<MapsFailureUnauthorized>()),
        );
      },
    );

    test(
      'FirebaseFunctionsException(failed-precondition) → Unauthorized',
      () async {
        when(() => autocomplete.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'failed-precondition',
            message: 'app-check-failed',
          ),
        );

        expect(
          () => repo.autocomplete('1234 Main', sessionToken: 't'),
          throwsA(isA<MapsFailureUnauthorized>()),
        );
      },
    );

    test(
      'a server feature-disabled refusal → Paused, as a breadcrumb not a warn',
      () async {
        final logger = _MockLogger();
        final quiet = GooglePlacesRepository(
          functions: functions,
          logger: logger,
        );
        when(() => autocomplete.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'failed-precondition',
            message: 'feature-disabled',
          ),
        );

        await expectLater(
          () => quiet.autocomplete('1234 Main', sessionToken: 't'),
          throwsA(isA<MapsFailurePaused>()),
        );
        verify(() => logger.breadcrumb(any())).called(1);
        verifyNever(() => logger.warn(any(), any<Object?>(), any()));
      },
    );

    test(
      'FirebaseFunctionsException(invalid-argument) → InvalidInput',
      () async {
        when(() => autocomplete.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'invalid-argument',
            message: 'invalid-input',
          ),
        );

        expect(
          () => repo.autocomplete('1234 Main', sessionToken: 't'),
          throwsA(isA<MapsFailureInvalidInput>()),
        );
      },
    );

    test('FirebaseFunctionsException(internal) → Network', () async {
      when(() => autocomplete.call<dynamic>(any<Object?>())).thenThrow(
        FirebaseFunctionsException(
          code: 'internal',
          message: 'places-upstream',
        ),
      );

      expect(
        () => repo.autocomplete('1234 Main', sessionToken: 't'),
        throwsA(isA<MapsFailureNetwork>()),
      );
    });
  });

  group('getPlaceDetails', () {
    test(
      'parses formattedAddress + addressComponents into ParsedAddress',
      () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'formattedAddress':
              '1234 Rue Saint-Denis, Montréal, QC H2X 3J5, Canada',
          'addressComponents': [
            {
              'types': ['street_number'],
              'longText': '1234',
              'shortText': '1234',
            },
            {
              'types': ['route'],
              'longText': 'Rue Saint-Denis',
              'shortText': 'Rue Saint-Denis',
            },
            {
              'types': ['locality'],
              'longText': 'Montréal',
              'shortText': 'Montréal',
            },
            {
              'types': ['administrative_area_level_1'],
              'longText': 'Quebec',
              'shortText': 'QC',
            },
            {
              'types': ['postal_code'],
              'longText': 'H2X 3J5',
              'shortText': 'H2X 3J5',
            },
          ],
        });
        when(
          () => details.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final parsed = await repo.getPlaceDetails(
          'abc123',
          sessionToken: 'token-1',
        );

        expect(
          parsed.fullAddress,
          '1234 Rue Saint-Denis, Montréal, QC H2X 3J5, Canada',
        );
        expect(parsed.street, '1234 Rue Saint-Denis');
        expect(parsed.city, 'Montréal');
        expect(parsed.province, 'QC');
        expect(parsed.postalCode, 'H2X 3J5');
      },
    );

    test(
      'prefixes the apt portion onto street when subpremise is present',
      () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'formattedAddress': '1234 Rue Saint-Denis #5, Montréal, QC',
          'addressComponents': [
            {
              'types': ['subpremise'],
              'longText': '5',
              'shortText': '5',
            },
            {
              'types': ['street_number'],
              'longText': '1234',
              'shortText': '1234',
            },
            {
              'types': ['route'],
              'longText': 'Rue Saint-Denis',
              'shortText': 'Rue Saint-Denis',
            },
          ],
        });
        when(
          () => details.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final parsed = await repo.getPlaceDetails(
          'abc123',
          sessionToken: 'token-1',
        );

        expect(parsed.street, '5-1234 Rue Saint-Denis');
      },
    );

    test('forwards placeId + sessionToken in the call payload', () async {
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{
        'formattedAddress': '',
        'addressComponents': const <dynamic>[],
      });
      when(
        () => details.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      await repo.getPlaceDetails('abc123', sessionToken: 'token-1');

      final captured =
          verify(
                () => details.call<dynamic>(captureAny<Object?>()),
              ).captured.single
              as Map<String, dynamic>;
      expect(captured['placeId'], 'abc123');
      expect(captured['sessionToken'], 'token-1');
    });

    test(
      'FirebaseFunctionsException(resource-exhausted) → RateLimit',
      () async {
        when(() => details.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'resource-exhausted',
            message: 'too-many-places-requests',
          ),
        );

        expect(
          () => repo.getPlaceDetails('abc123', sessionToken: 't'),
          throwsA(isA<MapsFailureRateLimit>()),
        );
      },
    );

    test('malformed response body → MapsFailureParse', () async {
      final result = _MockResult();
      // Returning an int where a Map is expected — the cast in the parser
      // throws, which the catch path wraps as MapsFailureParse.
      when(() => result.data).thenReturn(42);
      when(
        () => details.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      expect(
        () => repo.getPlaceDetails('abc123', sessionToken: 't'),
        throwsA(isA<MapsFailureParse>()),
      );
    });
  });

  group('reverseGeocode', () {
    test('sends lat/lng/locale in the call payload', () async {
      final result = _MockResult();
      when(
        () => result.data,
      ).thenReturn(<String, dynamic>{'address': '1234 Main St'});
      when(
        () => reverseGeocode.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      await repo.reverseGeocode(lat: 45.5017, lng: -73.5673, locale: 'fr');

      final captured =
          verify(
                () => reverseGeocode.call<dynamic>(captureAny<Object?>()),
              ).captured.single
              as Map<String, dynamic>;
      expect(captured['lat'], 45.5017);
      expect(captured['lng'], -73.5673);
      expect(captured['locale'], 'fr');
    });

    test('returns the resolved address string on success', () async {
      final result = _MockResult();
      when(
        () => result.data,
      ).thenReturn(<String, dynamic>{'address': '1234 Rue Saint-Denis'});
      when(
        () => reverseGeocode.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final address = await repo.reverseGeocode(
        lat: 45.5017,
        lng: -73.5673,
        locale: 'en',
      );

      expect(address, '1234 Rue Saint-Denis');
    });

    test('returns null when the server found no address', () async {
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{'address': null});
      when(
        () => reverseGeocode.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final address = await repo.reverseGeocode(
        lat: 45.5017,
        lng: -73.5673,
        locale: 'en',
      );

      expect(address, isNull);
    });

    test(
      'casts a Map<dynamic, dynamic> result.data (Android convention)',
      () async {
        final result = _MockResult();
        // Android callables return Map<dynamic, dynamic>; the repository must
        // loosely cast rather than `as Map<String, dynamic>?`.
        when(
          () => result.data,
        ).thenReturn(<dynamic, dynamic>{'address': '1234 Main St'});
        when(
          () => reverseGeocode.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final address = await repo.reverseGeocode(
          lat: 45.5017,
          lng: -73.5673,
          locale: 'en',
        );

        expect(address, '1234 Main St');
      },
    );

    test('malformed response body → MapsFailureParse', () async {
      final result = _MockResult();
      when(() => result.data).thenReturn(42);
      when(
        () => reverseGeocode.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      expect(
        () => repo.reverseGeocode(lat: 45.5017, lng: -73.5673, locale: 'en'),
        throwsA(isA<MapsFailureParse>()),
      );
    });

    test(
      'FirebaseFunctionsException(resource-exhausted) → RateLimit',
      () async {
        when(() => reverseGeocode.call<dynamic>(any<Object?>())).thenThrow(
          FirebaseFunctionsException(
            code: 'resource-exhausted',
            message: 'too-many-attempts',
          ),
        );

        expect(
          () => repo.reverseGeocode(lat: 45.5017, lng: -73.5673, locale: 'en'),
          throwsA(isA<MapsFailureRateLimit>()),
        );
      },
    );
  });
}
