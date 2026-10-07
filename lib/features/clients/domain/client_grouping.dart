import 'package:scheduling/features/clients/domain/models/client_record.dart';

/// A run of consecutive rows rendered inside one card, with the heading that
/// sits above it. A null heading is a card with no header at all.
typedef ClientGroup = ({String? heading, int start, int length});

/// The whole list as one card — the shape every sort but Name takes, and the
/// shape a building filter takes with the street as its heading.
List<ClientGroup> singleGroupOf(
  List<ClientRecord> clients, {
  String? heading,
}) => clients.isEmpty
    ? const []
    : [(heading: heading, start: 0, length: clients.length)];
