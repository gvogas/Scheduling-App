import 'dart:collection';

import 'package:scheduling/features/clients/domain/models/client_record.dart';

/// Search rows with the complete candidate scan's coverage and result count.
class ClientSearchResults extends UnmodifiableListView<ClientRecord> {
  ClientSearchResults(
    super.source, {
    required this.examinedCount,
    required this.matchedCount,
    required this.truncated,
  });

  final int examinedCount;
  final int matchedCount;
  final bool truncated;
}
