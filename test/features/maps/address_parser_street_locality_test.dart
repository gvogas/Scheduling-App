// AddressParser.streetOnly / composeFull hand-mirror functions/client_address_utils.js;
// both suites read test/fixtures/shared/address.json.

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/maps/domain/address_parser.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  final fixture = loadSharedFixture('address.json');

  group('AddressParser.streetOnly', () {
    for (final c in sharedCases(fixture, 'streetOnly')) {
      test(c['name'] as String, () {
        final l = c['locality'] as Map<String, dynamic>;
        expect(
          AddressParser.streetOnly(
            c['stored'] as String,
            city: l['city'] as String? ?? '',
            province: l['province'] as String? ?? '',
            postalCode: l['postalCode'] as String? ?? '',
            country: l['country'] as String? ?? '',
          ),
          c['expect'],
        );
      });
    }
  });

  group('AddressParser.composeFull', () {
    for (final c in sharedCases(fixture, 'composeFull')) {
      test(c['name'] as String, () {
        final l = c['locality'] as Map<String, dynamic>;
        expect(
          AddressParser.composeFull(
            c['stored'] as String,
            city: l['city'] as String? ?? '',
            province: l['province'] as String? ?? '',
            postalCode: l['postalCode'] as String? ?? '',
            country: l['country'] as String? ?? '',
          ),
          c['expect'],
        );
      });
    }

    test('composing an already-composed value is stable', () {
      const city = 'Montréal';
      const province = 'QC';
      const postalCode = 'H2X 1Y4';
      const country = 'Canada';
      final once = AddressParser.composeFull(
        '4-1234 Rue Principale',
        city: city,
        province: province,
        postalCode: postalCode,
        country: country,
      );
      expect(
        AddressParser.composeFull(
          once,
          city: city,
          province: province,
          postalCode: postalCode,
          country: country,
        ),
        once,
      );
    });
  });
}
