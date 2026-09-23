import 'package:flutter/foundation.dart';

import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/maps/domain/address_parser.dart';

/// One street address that more than one client sits at — a condo or apartment
/// building, and the unit of the clients list's Building filter.
@immutable
class ClientBuilding {
  const ClientBuilding({
    required this.key,
    required this.street,
    required this.city,
    required this.clientCount,
  });

  /// Normalized, accent-folded identity. Never rendered.
  final String key;

  /// The street as it is spelled on the clients that share it.
  final String street;

  /// Kept beside [street] because two towns can hold the same civic address —
  /// [key] separates them, and this is what lets the reader tell them apart.
  final String city;

  final int clientCount;

  @override
  bool operator ==(Object other) =>
      other is ClientBuilding &&
      other.key == key &&
      other.street == street &&
      other.city == city &&
      other.clientCount == clientCount;

  @override
  int get hashCode => Object.hash(key, street, city, clientCount);
}

/// The identity of the building a client sits at, or null when there isn't one.
///
/// Mirrored by the server-maintained `buildingKey` projection and catalog.
/// `clients/{id}.address` is the street line, so the key is that
/// line with the UNIT taken off: "914-4450 Prom. Paton" and
/// "1207-4450 Prom. Paton" are two units of one building.
///
/// **The city is part of the key.** Without it two towns holding the same
/// civic number merge into one building, and the filter then shows a Laval
/// client under a Montréal address with nothing on screen explaining why.
///
/// It reduces through [AddressParser.streetOnly] first, so it answers the same
/// key for a legacy doc whose `address` still carries the locality as for one
/// the backfill has normalized. Don't skip that: the collection holds both
/// shapes and always will.
String? buildingKeyFor(ClientRecord client) {
  final street = _buildingStreetOf(client);
  if (street == null) return null;
  final normalizedStreet = ClientSearchPolicy.normalize(street);
  if (normalizedStreet.isEmpty) return null;
  return '$normalizedStreet|${ClientSearchPolicy.normalize(client.city)}';
}

/// The street a client's building is known by, unit removed — null when the
/// client has no usable address.
String? _buildingStreetOf(ClientRecord client) {
  if (client.noFixedAddress) return null;
  final stored = client.address.trim();
  if (stored.isEmpty) return null;

  final street = AddressParser.streetOnly(
    stored,
    city: client.city,
    province: client.province,
    postalCode: client.postalCode,
    country: client.country,
  );
  if (street.isEmpty) return null;
  // "914-4450 Prom. Paton" -> "4450 Prom. Paton". A street with no unit on it
  // is already its own building.
  final withoutUnit = (AddressParser.splitApt(street)?.street ?? street).trim();
  return withoutUnit.isEmpty ? null : withoutUnit;
}

/// Every address shared by [minimumClients] or more of [clients], busiest
/// first.
///
/// A building of ONE is just a client, so the default floor is 2 — a filter
/// offering an entry per address would be a list of every client under another
/// name, and the dropdown has to stay readable.
///
/// Ordered by count descending because the reason to open this menu is "which
/// addresses do we have a lot of work at"; ties fall back to the street so the
/// order is stable between rebuilds rather than depending on iteration order.
/// [keys] is a `buildingKeysIn` result over the SAME clients — required rather
/// than optional so this can never become a second place building keys are
/// derived. It carries an entry per client, `null` included, so an absent id
/// means "not from this set" rather than "no building".
List<ClientBuilding> buildingsIn(
  Iterable<ClientRecord> clients, {
  required Map<String, String?> keys,
  int minimumClients = 2,
}) {
  final counts = <String, int>{};
  final labels = <String, ({String street, String city})>{};

  for (final client in clients) {
    final key = keys[client.id];
    if (key == null) continue;
    counts[key] = (counts[key] ?? 0) + 1;
    // First spelling seen wins — the key is already accent- and case-folded,
    // so any of them reads correctly and picking one keeps the label stable.
    labels[key] ??= (
      street: _buildingStreetOf(client)!,
      city: client.city.trim(),
    );
  }

  final buildings =
      [
        for (final entry in counts.entries)
          if (entry.value >= minimumClients)
            ClientBuilding(
              key: entry.key,
              street: labels[entry.key]!.street,
              city: labels[entry.key]!.city,
              clientCount: entry.value,
            ),
      ]..sort((a, b) {
        final byCount = b.clientCount.compareTo(a.clientCount);
        return byCount != 0 ? byCount : a.street.compareTo(b.street);
      });
  return buildings;
}

/// Every client's building key by client id, `null` where there isn't one.
///
/// [buildingKeyFor] is not cheap — `AddressParser.streetOnly`, `splitApt` and
/// two per-codeunit `normalize` passes each — and THREE surfaces want the same
/// answer per client: the Building menu's counts, the building filter, and the
/// per-row pill. Computing it once and handing this map to each of them is what
/// keeps a client write from re-deriving the whole window three times over on
/// the UI isolate. Every client gets an entry, so a caller can tell "no
/// building" from "not in this window" with `containsKey`.
Map<String, String?> buildingKeysIn(Iterable<ClientRecord> clients) => {
  for (final client in clients) client.id: buildingKeyFor(client),
};
