import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/features/clients/data/firebase_clients_repository.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

final clientsRepositoryProvider = Provider<ClientsRepository>((ref) {
  final firestore = ref.watch(firestoreProvider);
  final functions = ref.watch(firebaseFunctionsProvider);
  return FirebaseClientsRepository(firestore, functions: functions);
});

/// The last client write, so dependents can refresh (counts, searches, the
/// building catalog) or patch a loaded page in place (the paginated list).
///
/// Instances are deliberately NOT value-equal: two archives of the same client
/// must both notify.
sealed class ClientsWrite {
  ClientsWrite();
}

/// A new client; the page it belongs on is the server's to decide.
class ClientsWriteAdded extends ClientsWrite {
  ClientsWriteAdded(this.client);
  final ClientRecord client;
}

/// An edit of an existing client, carrying the record as saved.
class ClientsWriteUpdated extends ClientsWrite {
  ClientsWriteUpdated(this.client);
  final ClientRecord client;
}

/// An archive / un-archive toggle.
class ClientsWriteArchived extends ClientsWrite {
  ClientsWriteArchived(this.clientId, {required this.archived});
  final String clientId;
  final bool archived;
}

/// A delete; the record is gone.
class ClientsWriteDeleted extends ClientsWrite {
  ClientsWriteDeleted(this.clientId);
  final String clientId;
}

/// A write with no record to patch from — every dependent refreshes.
class ClientsWriteRefresh extends ClientsWrite {
  ClientsWriteRefresh();
}

/// Bumped after any client write; null until the first one.
final clientsRefreshProvider = NotifierProvider<ClientsRefresh, ClientsWrite?>(
  ClientsRefresh.new,
);

class ClientsRefresh extends Notifier<ClientsWrite?> {
  @override
  ClientsWrite? build() => null;

  void bump([ClientsWrite? write]) => state = write ?? ClientsWriteRefresh();
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

/// Full client search with relevance scoring, scoped to one list filter.
/// AutoDispose frees the results once each query instance is no longer watched.
final clientSearchProvider = FutureProvider.autoDispose
    .family<List<ClientRecord>, (String, ClientsFilter)>((ref, key) async {
      final (query, filter) = key;
      if (!ClientSearchPolicy.shouldSearch(query)) return const [];
      // Watching bump invalidates results so deleted clients don't linger.
      ref.watch(clientsRefreshProvider);
      final repo = ref.watch(clientsRepositoryProvider);
      return await repo.searchClients(query, filter: filter);
    });

/// Shared addresses from the server-maintained catalog. This reads summary
/// documents rather than downloading the roster to derive building counts.
/// Reopening the filter sheet or a local refresh reloads the catalog; backend
/// projections are eventually consistent with client writes.
final clientBuildingsProvider =
    FutureProvider.autoDispose<List<ClientBuilding>>((ref) async {
      ref.watch(clientsRefreshProvider);
      return await ref.watch(clientsRepositoryProvider).fetchBuildings();
    });

/// How many clients a list filter matches, so the list header can say "250 of
/// 500" rather than calling the rows it happens to have loaded "all".
final clientsTotalCountProvider = FutureProvider.autoDispose
    .family<int, ClientsFilter>((ref, filter) async {
      ref.watch(clientsRefreshProvider);
      return await ref
          .watch(clientsRepositoryProvider)
          .countClients(filter: filter);
    });
