import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

/// A run of consecutive rows rendered inside one card, with the heading that
/// sits above it. A null heading is a card with no header at all.
typedef ClientGroup = ({String? heading, int start, int length});

/// The letter [client] files under, accent-folded through the search policy so
/// "Étienne" lands on E. Anything that is not a letter — a person whose display
/// name is their phone number — files under `#`.
String clientInitialOf(ClientRecord client) {
  final normalized = ClientSearchPolicy.normalize(client.displayName);
  if (normalized.isEmpty) return '#';
  final first = normalized[0];
  return first.compareTo('a') >= 0 && first.compareTo('z') <= 0
      ? first.toUpperCase()
      : '#';
}

/// One group per run of clients sharing an initial.
///
/// It never re-orders: [clients] must already be in `sortClients` Name order,
/// the same folded key the heading reads.
List<ClientGroup> letterGroupsOf(List<ClientRecord> clients) {
  final groups = <ClientGroup>[];
  var start = 0;
  String? current;
  for (var i = 0; i < clients.length; i++) {
    final initial = clientInitialOf(clients[i]);
    if (current == null) {
      current = initial;
      continue;
    }
    if (initial == current) continue;
    groups.add((heading: current, start: start, length: i - start));
    current = initial;
    start = i;
  }
  if (current != null) {
    groups.add((
      heading: current,
      start: start,
      length: clients.length - start,
    ));
  }
  return groups;
}

/// The whole list as one card — the shape every sort but Name takes, and the
/// shape a building filter takes with the street as its heading.
List<ClientGroup> singleGroupOf(
  List<ClientRecord> clients, {
  String? heading,
}) => clients.isEmpty
    ? const []
    : [(heading: heading, start: 0, length: clients.length)];
