/// How the client list is ordered, under every filter.
///
/// The field names are the Firestore field paths the repository orders by, so
/// this enum is the ONE owner of that mapping — a sort added here without a
/// matching composite in `firestore.indexes.json` fails the query, loudly,
/// which is the intended failure.
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
