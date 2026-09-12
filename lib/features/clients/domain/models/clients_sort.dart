import 'package:scheduling/features/clients/domain/models/client_record.dart';

/// How the unfiltered client list is ordered.
///
/// The field names are the Firestore field paths the repository orders by, so
/// this enum is the ONE owner of that mapping — a sort added here without a
/// matching composite in `firestore.indexes.json` fails the query, loudly,
/// which is the intended failure. `sortClients` below is the same order in
/// Dart, for the filtered paths; a new member means an arm there too.
enum ClientsSort {
  name('name', descending: false, requiresBackfill: false),
  mostJobs('jobCount', descending: true, requiresBackfill: true),
  recentlyAdded('createdAt', descending: true, requiresBackfill: true);

  const ClientsSort(
    this.field, {
    required this.descending,
    required this.requiresBackfill,
  });

  /// The Firestore field this sort orders by.
  final String field;

  final bool descending;

  /// Whether the field is nullable on a client doc, so Firestore's `orderBy`
  /// silently omits any document missing it. True means
  /// `functions/scripts/backfill-client-sort-fields.js` must have run before
  /// this sort tells the truth.
  final bool requiresBackfill;
}

/// The same order in Dart, for the filtered paths — which read a bounded
/// in-memory window rather than the paginated server query.
///
/// It diverges from the server `orderBy` in one way, deliberately: a record
/// missing the sorted field sorts LAST here, where Firestore DROPS it. Strictly
/// better, but the two paths now answer differently for an un-backfilled doc.
List<ClientRecord> sortClients(List<ClientRecord> records, ClientsSort sort) {
  final keyed = [
    for (final record in records)
      (nameKey: record.displayName.toLowerCase(), record: record),
  ];
  // Every arm tie-breaks on the name key, so the order is total and stable.
  switch (sort) {
    case ClientsSort.name:
      keyed.sort((a, b) => a.nameKey.compareTo(b.nameKey));
    case ClientsSort.mostJobs:
      keyed.sort((a, b) {
        final byCount = _descendingNullsLast(
          a.record.jobCount,
          b.record.jobCount,
        );
        return byCount != 0 ? byCount : a.nameKey.compareTo(b.nameKey);
      });
    case ClientsSort.recentlyAdded:
      keyed.sort((a, b) {
        final byDate = _descendingNullsLast(
          a.record.createdAt,
          b.record.createdAt,
        );
        return byDate != 0 ? byDate : a.nameKey.compareTo(b.nameKey);
      });
  }
  return [for (final entry in keyed) entry.record];
}

int _descendingNullsLast<T extends Comparable<Object>>(T? a, T? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return b.compareTo(a);
}
