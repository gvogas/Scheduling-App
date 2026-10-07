import 'package:flutter/foundation.dart';

import 'package:scheduling/features/clients/domain/models/client_type.dart';

/// Which slice of the client roster the list is showing.
///
/// Sealed so "archived AND commercial" is unexpressible rather than merely
/// unhandled — the chips are mutually exclusive by design.
@immutable
sealed class ClientsFilter {
  const ClientsFilter();
}

class ClientsFilterAll extends ClientsFilter {
  const ClientsFilterAll();

  @override
  bool operator ==(Object other) => other is ClientsFilterAll;

  @override
  int get hashCode => 1;
}

class ClientsFilterType extends ClientsFilter {
  const ClientsFilterType(this.type);
  final ClientType type;

  @override
  bool operator ==(Object other) =>
      other is ClientsFilterType && other.type == type;

  @override
  int get hashCode => type.hashCode;
}

/// One building's worth of clients, keyed by `buildingKeyFor`.
///
/// Keyed on the DERIVED key rather than the street text: the key is
/// accent-folded and carries the city, so two spellings of one address select
/// the same clients and two towns sharing a civic number stay apart.
class ClientsFilterBuilding extends ClientsFilter {
  const ClientsFilterBuilding(this.key);
  final String key;

  @override
  bool operator ==(Object other) =>
      other is ClientsFilterBuilding && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class ClientsFilterArchived extends ClientsFilter {
  const ClientsFilterArchived();

  @override
  bool operator ==(Object other) => other is ClientsFilterArchived;

  @override
  int get hashCode => 0;
}
