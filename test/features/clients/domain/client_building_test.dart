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

  // `buildingsIn` takes the shared key map the repository's scan window
  // memoizes; these cases care about the grouping, not about where keys
  // come from.
  List<ClientBuilding> buildingsOf(List<ClientRecord> clients) =>
      buildingsIn(clients, keys: buildingKeysIn(clients));

  group('buildingsIn', () {
    test('an address with only one client is not a building', () {
      // Otherwise the menu is the client list under another name.
      final buildings = buildingsOf([
        _client('a', address: '1 Rue Un'),
        _client('b', address: '2 Rue Deux'),
      ]);
      expect(buildings, isEmpty);
    });

    test('groups units and counts them', () {
      final buildings = buildingsOf([
        _client('a', address: '914-4450 Prom. Paton'),
        _client('b', address: '1207-4450 Prom. Paton'),
        _client('c', address: '601-4450 Prom. Paton'),
      ]);
      expect(buildings, hasLength(1));
      expect(buildings.single.street, '4450 Prom. Paton');
      expect(buildings.single.city, 'Laval');
      expect(buildings.single.clientCount, 3);
    });

    test('busiest building first', () {
      final buildings = buildingsOf([
        _client('a', address: '1-100 Rue A'),
        _client('b', address: '2-100 Rue A'),
        _client('c', address: '1-200 Rue B'),
        _client('d', address: '2-200 Rue B'),
        _client('e', address: '3-200 Rue B'),
      ]);
      expect(buildings.map((b) => b.street), ['200 Rue B', '100 Rue A']);
    });

    test('ties order by street so the menu is stable between rebuilds', () {
      final buildings = buildingsOf([
        _client('a', address: '1-200 Rue B'),
        _client('b', address: '2-200 Rue B'),
        _client('c', address: '1-100 Rue A'),
        _client('d', address: '2-100 Rue A'),
      ]);
      expect(buildings.map((b) => b.street), ['100 Rue A', '200 Rue B']);
    });

    test('clients with no address are skipped, not grouped together', () {
      // They all derive a null key; grouping them would invent a building.
      final buildings = buildingsOf([_client('a'), _client('b'), _client('c')]);
      expect(buildings, isEmpty);
    });
  });
}
