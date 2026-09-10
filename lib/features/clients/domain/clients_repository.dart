import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';

abstract class ClientsRepository {
  /// Drops every cached client this repository is holding.
  ///
  /// The implementation is a process-scoped singleton, so its search windows
  /// outlive the session that filled them — full client records, with name,
  /// phone, email, address and contacts. Sign-out and account exit call this
  /// through `deregisterThisDevice`, which is the single owner of "forget this
  /// session".
  void clearCaches();

  Future<ClientRecord?> getClientById(String id);

  /// Live stream of one client doc; emits null once the doc is gone.
  ///
  /// The Wave sync badge is why this exists and why it cannot be a one-shot
  /// read. `wave.syncState` is written ONLY by Cloud Functions — the
  /// `waveUpsertCustomer` trigger stamps `pending` after the save has already
  /// returned, and the outbox worker flips it to `synced` up to five minutes
  /// later — so any record a screen was handed necessarily predates the state
  /// the badge is trying to show. See the sync-badge invariant in CLAUDE.md.
  Stream<ClientRecord?> watchClient(String id);

  /// Live stream of the clients the Wave customer contract REFUSED, so
  /// Settings can list them instead of showing a bare failure count.
  ///
  /// `blocked` is a server-owned state on `wave.syncState`: the client never
  /// became a queued job, so it is not a dead outbox job and does not appear
  /// in the outbox counters. Bounded — this is a list an admin acts on, not a
  /// report.
  Stream<List<ClientRecord>> watchBlockedClients({int limit});

  /// Persists a new client and returns it with the generated Firestore doc id, so the
  /// caller can link to it right away.
  Future<ClientRecord> addClient(ClientRecord client);

  Future<void> updateClient(ClientRecord client);

  /// Deletes a client. Refuses (throws `ClientsFailureHasHistory`) when the
  /// client still has appointments — the server re-checks with a live count()
  /// aggregate and is the real boundary. Archive is the normal removal.
  Future<void> deleteClient(String id);

  /// Archives or un-archives a client. Archived clients drop out of the
  /// paginated list and the type filter but stay searchable and stay bookable —
  /// their `clientId` links on existing appointments are untouched.
  Future<void> setClientArchived(String id, {required bool archived});

  /// Archived clients, name-sorted, from the same cached window
  /// `searchClients` scans — so the Archived chip costs no extra read inside
  /// the TTL and needs no composite index.
  Future<List<ClientRecord>> fetchArchivedClients();

  Future<List<ClientRecord>> searchClients(String query);

  /// One page of non-archived clients in [sort] order.
  ///
  /// [after] is the last record of the previous page; the cursor tuple is
  /// (sort field, doc id), so a page fetched under one sort can never be used
  /// to resume another.
  Future<List<ClientRecord>> fetchClientsPage({
    required int limit,
    ClientRecord? after,
    ClientsSort sort = ClientsSort.name,
  });

  /// One-shot fetch of clients created since [since], used for dashboard
  /// trends. Legacy docs without `createdAt` (old imports) are excluded.
  Future<List<ClientRecord>> fetchClientsCreatedSince(DateTime since);

  /// Clients of [type], name-sorted, from the same cached window
  /// `searchClients` scans — so the filter costs no extra read inside the TTL
  /// and needs no composite index.
  ///
  /// A SEPARATE bounded read, deliberately not a filter over `fetchClientsPage`:
  /// filtering a server page in Dart shortens a page the server actually filled,
  /// which stops the paginated list early. See the "never removed" invariant in
  /// CLAUDE.md for the full reasoning.
  Future<List<ClientRecord>> fetchClientsByType(ClientType type);

  /// Clients at one building, keyed by `buildingKeyFor`. Same bounded cached
  /// window as the type filter, so the Building menu costs no extra read.
  Future<List<ClientRecord>> fetchClientsByBuilding(String key);

  /// Every address shared by two or more clients, busiest first — the Building
  /// menu's options and the per-row pill's counts.
  Future<List<ClientBuilding>> fetchBuildings();
}
