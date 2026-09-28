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
