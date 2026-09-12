import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/clients/data/firebase_clients_repository.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

final clientsRepositoryProvider = Provider<ClientsRepository>((ref) {
  final firestore = ref.watch(firestoreProvider);
  final functions = ref.watch(firebaseFunctionsProvider);
  return FirebaseClientsRepository(firestore, functions: functions);
});

/// Bumped after any client write so paginated list refreshes.
final clientsRefreshProvider = NotifierProvider<ClientsRefresh, int>(
  ClientsRefresh.new,
);

class ClientsRefresh extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Live view of one client doc, keyed by doc id. AutoDispose so the listener is
/// dropped the moment the detail surface closes.
///
/// The Wave sync badge is the reason this is a listener and not a read: every
/// other client surface here is a one-shot read (a paginated page, or the
/// cached scan window), and `wave.syncState` is function-owned — it goes
/// `pending` after the save returns and `synced` up to five minutes later, so
/// a record handed to a screen can never show it. It also deliberately does
/// NOT patch the repository's search/scan cache: that cache is patched on
/// WRITE (`_patchWindow`), and `ClientRecord.toMap()` omits `wave` there, so
/// the cached copy keeps a stale sync state by design.
final clientStreamProvider = StreamProvider.autoDispose
    .family<ClientRecord?, String>(
      (ref, id) => ref.watch(clientsRepositoryProvider).watchClient(id),
    );

/// Full client search with relevance scoring. AutoDispose frees the results once each
/// query instance is no longer watched.
final clientSearchProvider = FutureProvider.autoDispose
    .family<List<ClientRecord>, String>((ref, query) async {
      if (!ClientSearchPolicy.shouldSearch(query)) return const [];
      // Watching bump invalidates results so deleted clients don't linger.
      ref.watch(clientsRefreshProvider);
      final repo = ref.watch(clientsRepositoryProvider);
      return await repo.searchClients(query);
    });

/// Clients of one type, for the list's filter row. AutoDispose frees it as soon
/// as the filter is cleared.
final clientsByTypeProvider = FutureProvider.autoDispose
    .family<List<ClientRecord>, ClientType>((ref, type) async {
      ref.watch(clientsRefreshProvider);
      return await ref
          .watch(clientsRepositoryProvider)
          .fetchClientsByType(type);
    });

/// Clients at one building, from the same cached window as the type filter.
final clientsByBuildingProvider = FutureProvider.autoDispose
    .family<List<ClientRecord>, String>((ref, key) async {
      ref.watch(clientsRefreshProvider);
      return await ref
          .watch(clientsRepositoryProvider)
          .fetchClientsByBuilding(key);
    });

/// Every address two or more clients share — the Building menu's options.
///
/// **This is EAGER on Clients-tab open, and that is a decision rather than an
/// oversight** (owner call, 2026-09-01). `ClientsListView.build` watches this
/// before the filter switch, so opening the
/// tab pays the paged `orderBy('name')` scan window (capped at
/// `_clientScanLimit`, ~700 clients today) on top of the paginated list's
/// first 50 — roughly 14× read amplification on the first open per session,
/// where it used to be paid only on a search or a filter-chip tap.
///
/// It is not deferrable as the surface stands. `ClientAddressFilterMenu`
/// renders NOTHING when no address is shared — deliberately, since an empty
/// menu reads as a broken control — so it cannot decide whether to appear
/// without the very data a deferral would be withholding. Loading on first
/// open would mean always showing the chip, which reverses that decision.
///
/// The cost is also not wasted: this is the SAME cached, TTL'd window that
/// search, the type chips and the Archived chip read, so the tab open warms
/// what the next interaction would have fetched anyway.
///
/// Removing it for real means not deriving buildings from the client
/// collection at all — a small server-maintained `buildings` aggregate would
/// make both the menu and the per-row pill cost O(buildings) instead of
/// O(clients). That is a design change (function, backfill, index), not a
/// tweak here.
final clientBuildingsProvider =
    FutureProvider.autoDispose<List<ClientBuilding>>((ref) async {
      ref.watch(clientsRefreshProvider);
      return await ref.watch(clientsRepositoryProvider).fetchBuildings();
    });

/// How many non-archived clients exist, so the list header can say "250 of
/// 500" rather than calling the rows it happens to have loaded "all".
final clientsTotalCountProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(clientsRefreshProvider);
  return await ref.watch(clientsRepositoryProvider).countClients();
});

/// Archived clients, read from the same bounded cached window as search and
/// the type filter — so the Archived chip costs no extra read inside the TTL.
final archivedClientsProvider = FutureProvider.autoDispose<List<ClientRecord>>((
  ref,
) async {
  ref.watch(clientsRefreshProvider);
  return await ref.watch(clientsRepositoryProvider).fetchArchivedClients();
});
