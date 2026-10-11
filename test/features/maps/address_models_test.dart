import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/maps/domain/models/address_suggestion.dart';
import 'package:scheduling/features/maps/domain/models/parsed_address.dart';

void main() {
  group('AddressSuggestion', () {
    test('value equality', () {
      const a = AddressSuggestion(placeId: 'p1', description: 'd');
      const b = AddressSuggestion(placeId: 'p1', description: 'd');
      expect(a, equals(b));
    });

    test('fromJson hydrates from Google Places response shape', () {
      final s = AddressSuggestion.fromJson(const {
        'placePrediction': {
          'placeId': 'abc',
          'text': {'text': '123 Main St, Montréal, QC'},
        },
      });
      expect(s.placeId, 'abc');
      expect(s.description, '123 Main St, Montréal, QC');
    });

    test('fromJson defaults missing fields to empty', () {
      expect(AddressSuggestion.fromJson(const {}).placeId, '');
      expect(AddressSuggestion.fromJson(const {}).description, '');
    });

    test('fromJson reads the street and city lines from structuredFormat', () {
      final s = AddressSuggestion.fromJson(const {
        'placePrediction': {
          'placeId': 'abc',
          'text': {'text': '123 Main St, Montréal, QC'},
          'structuredFormat': {
            'mainText': {'text': '123 Main St'},
            'secondaryText': {'text': 'Montréal, QC'},
          },
        },
      });
      expect(
        (s.mainText, s.secondaryText, s.description),
        ('123 Main St', 'Montréal, QC', '123 Main St, Montréal, QC'),
      );
    });

    test('fromJson leaves the lines empty without structuredFormat', () {
      final s = AddressSuggestion.fromJson(const {
        'placePrediction': {
          'placeId': 'abc',
          'text': {'text': '123 Main St, Montréal, QC'},
        },
      });
      expect((s.mainText, s.secondaryText), ('', ''));
    });

    test('fromJson ignores non-string lines', () {
      final s = AddressSuggestion.fromJson(const {
        'placePrediction': {
          'structuredFormat': {
            'mainText': {'text': 42},
            'secondaryText': 'x',
          },
        },
      });
      expect((s.mainText, s.secondaryText), ('', ''));
    });
  });

  group('ParsedAddress', () {
    test('value equality', () {
      const a = ParsedAddress(street: 's', city: 'c');
      const b = ParsedAddress(street: 's', city: 'c');
      expect(a, equals(b));
    });

    test('toMap → fromMap roundtrip', () {
      const original = ParsedAddress(
        fullAddress: '12-1245 Rue de Bleury, Montréal, QC H3B 0A8',
        street: '12-1245 Rue de Bleury',
        city: 'Montréal',
        province: 'QC',
        postalCode: 'H3B 0A8',
      );
      final restored = ParsedAddress.fromMap(original.toMap());
      expect(restored, equals(original));
    });
  });
}
