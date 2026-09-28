import 'dart:convert';
import 'dart:io';

// Pins the building grouping — the derived key, and the reduction the clients
// list's Address filter and its per-row pill both read.
//
// The key is derived and never stored, so the risks are all in the deriving:
// merging two towns that share a civic number, splitting one building because
// its docs are in two stored shapes, or counting a unit number as a building.

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';

ClientRecord _client(
  String id, {
  String address = '',
  String city = 'Laval',
  String province = 'QC',
  String postalCode = 'H7W 5J7',
  String country = 'Canada',
  bool noFixedAddress = false,
}) => ClientRecord(
  id: id,
  name: id,
  address: address,
  city: city,
  province: province,
  postalCode: postalCode,
  country: country,
  noFixedAddress: noFixedAddress,
);

void main() {
  final cases =
      jsonDecode(
            File('test/fixtures/client_building_cases.json').readAsStringSync(),
          )
          as List;
  for (final entry in cases.cast<Map<String, dynamic>>()) {
    test('server identity parity: ${entry['description']}', () {
      final client = ClientRecord.fromMap(
        'fixture',
        (entry['data'] as Map).cast<String, dynamic>(),
      );
      expect(buildingKeyFor(client), entry['key']);
    });
  }

  group('buildingKeyFor', () {
    test('two units of one building share a key', () {
      expect(
        buildingKeyFor(_client('a', address: '914-4450 Prom. Paton')),
        buildingKeyFor(_client('b', address: '1207-4450 Prom. Paton')),
      );
    });

    test('BOTH stored shapes reach the same key', () {
      // The collection holds legacy full-address docs and street-only ones at
      // the same time; a key that split them would break the grouping on
      // exactly the buildings with the most history.
      expect(
        buildingKeyFor(
          _client(
            'legacy',
            address: '914-4450 Prom. Paton, Laval, QC H7W 5J7, Canada',
          ),
        ),
        buildingKeyFor(_client('new', address: '914-4450 Prom. Paton')),
      );
    });

    test('the same civic address in two towns does NOT merge', () {
      // Without the city in the key, a Laval client turns up under a Montréal
      // address with nothing on screen explaining why.
      expect(
        buildingKeyFor(_client('a', address: '100 Rue Principale')),
        isNot(
          buildingKeyFor(
            _client('b', address: '100 Rue Principale', city: 'Montréal'),
          ),
        ),
      );
    });

    test('accents and case do not split a building', () {
      expect(
        buildingKeyFor(_client('a', address: '4564 Av. du Château')),
        buildingKeyFor(_client('b', address: '4564 AV. DU CHATEAU')),
      );
    });

    test('a street with no unit is its own building', () {
      expect(
        buildingKeyFor(_client('a', address: "10200 Bd de l'Acadie")),
        buildingKeyFor(_client('b', address: "501-10200 Bd de l'Acadie")),
      );
    });

    test('null for a client with no address', () {
      expect(buildingKeyFor(_client('a')), isNull);
    });

    test('null for a no-fixed-address client', () {
      // They have somewhere written down, but it is not a building.
      expect(
        buildingKeyFor(
          _client('a', address: '4450 Prom. Paton', noFixedAddress: true),
        ),
        isNull,
      );
    });
  });
}
