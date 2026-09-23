import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:scheduling/core/data/paged_scan.dart';
import 'package:scheduling/core/data/search_result_cache.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/performance/performance_trace.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/features/clients/domain/clients_failure.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/wave/domain/models/wave_sync_state.dart';

class FirebaseClientsRepository implements ClientsRepository {
  FirebaseClientsRepository(
    FirebaseFirestore firestore, {
    FirebaseFunctions? functions,
    AppLogger? logger,
    DateTime Function()? clock,
    bool? useCallableSearch,
  }) : _clients = firestore.collection('clients'),
       _firestore = firestore,
       _functions = functions,
       _logger = logger ?? AppLogger(),
       _clock = clock ?? DateTime.now,
       _useCallableSearch = useCallableSearch ?? functions != null;

  final CollectionReference<Map<String, dynamic>> _clients;
  final FirebaseFirestore _firestore;
  final FirebaseFunctions? _functions;
  final AppLogger _logger;
  final bool _useCallableSearch;

  FirebaseFunctions get _callables => _functions ?? FirebaseFunctions.instance;

  /// Injectable time source so the search-cache TTL is testable.
  final DateTime Function() _clock;

  /// Bounded LRU of recent results.
  late final SearchResultCache<ClientRecord> _searchCache = SearchResultCache(
    clock: _clock,
  );

  /// How long a window may be kept alive by local patches before it is re-paged
  /// regardless.
  static const Duration _scanWindowMaxAge = Duration(minutes: 10);

  // Shared name-ordered scan window serving all queries within the TTL.
  _CachedClientScanWindow? _scanWindow;
  Future<_CachedClientScanWindow>? _pendingScan;

  static const int _clientScanPageSize = 500;

  /// Ceiling on the paged client scan windows.
  static const int _clientScanLimit = 5000;

  bool _isFresh(DateTime fetchedAt) => _searchCache.isFresh(fetchedAt);

  /// The freshness stamp a patched [window] should carry.
  DateTime _patchedFetchedAt(_CachedClientScanWindow window) {
    final now = _clock();
    return now.difference(window.firstFetchedAt) < _scanWindowMaxAge
        ? now
        : window.fetchedAt;
  }

  // For local writes we patch the written doc into the scan window directly, so
  // search can recompute without an extra read.
  void _patchWindow(
    String id, {
    Map<String, dynamic>? data,
    bool partial = false,
  }) {
    final window = _scanWindow;
    if (window != null && _isFresh(window.fetchedAt)) {
      final previous = window.docs
          .where((doc) => doc.id == id)
          .firstOrNull
          ?.data;
      if (partial && previous == null) {
        // A patch cannot reconstruct a record outside the loaded window.
        clearCaches();
        return;
      }
      final docs = [
        for (final doc in window.docs)
          if (doc.id != id) doc,
        if (data != null) (id: id, data: {...?previous, ...data}),
      ];
      _scanWindow = window.patched(docs, at: _patchedFetchedAt(window));
    } else {
      _scanWindow = null;
    }
    _searchCache.clear();
    _pendingScan = null;
  }

  /// The raw stored value of each page's LAST document's sort field, keyed by
  /// `"<sort name>:<doc id>"`.
  ///
  /// Keyed by sort as well as id because the cursor tuple follows the sort: a
  /// boundary captured under `name` resumes a `jobCount` query from a string
  /// and returns the wrong slice. `ClientRecord.name` is composed and need not
  /// equal the stored field, which is why the raw value is cached at all.
  final Map<String, Object?> _pageBoundaryValues = {};

  /// Page boundaries retained — ~`_clientsPageSize` × this many clients deep.
  static const _pageBoundaryMax = 200;

  @override
  void clearCaches() {
    _searchCache.clear();
    _scanWindow = null;
    _pendingScan = null;
    _pageBoundaryValues.clear();
  }

  @override
  Future<List<ClientRecord>> fetchClientsPage({
    required int limit,
    ClientRecord? after,
    ClientsSort sort = ClientsSort.name,
    ClientsFilter filter = const ClientsFilterAll(),
  }) async {
    final generation = _searchCache.generation;
    var query = _filteredQuery(filter)
        .orderBy(sort.field, descending: sort.descending)
        .orderBy(FieldPath.documentId);
    if (after != null) {
      query = query.startAfter([
        _pageBoundaryValues['${sort.name}:${after.id}'] ??
            _fallbackCursorValue(after, sort),
        after.id,
      ]);
    }
    final snapshot = await PerformanceTrace.measure(
      PerformanceOperation.clientsPage,
      () => query.limit(limit).get(),
    );
    final docs = snapshot.docs;
    if (docs.isNotEmpty && generation == _searchCache.generation) {
      final last = docs.last;
      final cacheKey = '${sort.name}:${last.id}';
      _pageBoundaryValues.remove(cacheKey);
      if (_pageBoundaryValues.length >= _pageBoundaryMax) {
        _pageBoundaryValues.remove(_pageBoundaryValues.keys.first);
      }
      _pageBoundaryValues[cacheKey] = last.data()[sort.field];
    }
    return docs.map((doc) => ClientRecord.fromMap(doc.id, doc.data())).toList();
  }

  Query<Map<String, dynamic>> _filteredQuery(ClientsFilter filter) {
    final query = _clients.where(
      'archived',
      isEqualTo: filter is ClientsFilterArchived,
    );
    return switch (filter) {
      ClientsFilterType(:final type) => query.where(
        'type',
        isEqualTo: type.raw,
      ),
      ClientsFilterBuilding(:final key) => query.where(
        'buildingKey',
        isEqualTo: key,
      ),
      _ => query,
    };
  }

  @override
  Future<int> countClients() async {
    final snapshot = await _clients
        .where('archived', isEqualTo: false)
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  // Only reached when the boundary cache has evicted the entry — the record's
  // own value is a good enough cursor for every sort except `name`, which is
  // composed rather than stored.
  Object? _fallbackCursorValue(ClientRecord after, ClientsSort sort) =>
      switch (sort) {
        ClientsSort.name => after.name,
        ClientsSort.mostJobs => after.jobCount,
        ClientsSort.recentlyAdded => after.createdAt,
      };

  @override
  Future<ClientRecord?> getClientById(String id) async {
    final doc = await _clients.doc(id).get();
    if (!doc.exists) return null;
    return ClientRecord.fromMap(doc.id, doc.data() ?? {});
  }

  @override
  Stream<ClientRecord?> watchClient(String id) => _clients
      .doc(id)
      .snapshots()
      .map(
        (doc) =>
            doc.exists ? ClientRecord.fromMap(doc.id, doc.data() ?? {}) : null,
      );

  @override
  Stream<List<ClientRecord>> watchBlockedClients({int limit = 50}) => _clients
      .where('wave.syncState', isEqualTo: kWaveSyncStateBlocked)
      .orderBy('name')
      .limit(limit)
      .snapshots()
      .map(
        (snap) => snap.docs
            .map((doc) => ClientRecord.fromMap(doc.id, doc.data()))
            .toList(growable: false),
      )
      .handleError((Object e, StackTrace st) {
        _logger.warn('WAVE-BLOCKED watch blocked clients failed', e, st);
      });

  @override
  Future<List<ClientRecord>> fetchClientsCreatedSince(DateTime since) async {
    final docs = await pageToCap(
      _clients
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
          .orderBy('createdAt', descending: true),
      pageSize: _clientScanPageSize,
      cap: _clientScanLimit,
      onCapReached: () => _logger.warn(
        'CLI-LIST createdSince scan hit the $_clientScanLimit-doc cap - '
        'older clients are not included',
      ),
    );
    return docs.map((doc) => ClientRecord.fromMap(doc.id, doc.data())).toList();
  }

  @override
  Future<ClientRecord> addClient(ClientRecord client) async {
    final map = _normalizedMap(client);
    final docRef = await _clients.add({
      ...map,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow(docRef.id, data: map);
    return client.copyWith(id: docRef.id);
  }

  @override
  Future<void> updateClient(ClientRecord client) async {
    final map = _normalizedMap(client);
    await _clients.doc(client.id).update({
      ...map,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow(client.id, data: map);
  }

  @override
  Future<void> deleteClient(String id) async {
    try {
      await _callables.httpsCallable('deleteClient').call<void>({
        'clientId': id,
      });
    } on FirebaseFunctionsException catch (e) {
      if (e.message == 'client-has-history') {
        throw const ClientsFailureHasHistory();
      }
      if (e.message == 'client-not-found') {
        throw const ClientsFailureNotFound();
      }
      rethrow;
    }
    _patchWindow(id);
  }

  @override
  Future<void> setClientArchived(String id, {required bool archived}) async {
    await _clients.doc(id).update({
      'archived': archived,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow(id, data: {'archived': archived}, partial: true);
  }

  /// Compatibility read for non-paged consumers. Lists and search use bounded queries.
  Future<List<ClientRecord>> _readFiltered(ClientsFilter filter) async {
    final docs = await pageToCap(
      _filteredQuery(filter).orderBy('name').orderBy(FieldPath.documentId),
      pageSize: _clientScanPageSize,
      cap: _clientScanLimit,
      onCapReached: () =>
          _logger.warn('CLI-FILTER matching clients reached the display cap'),
    );
    return docs.map((doc) => ClientRecord.fromMap(doc.id, doc.data())).toList();
  }

  @override
  Future<List<ClientRecord>> fetchArchivedClients() =>
      _readFiltered(const ClientsFilterArchived());

  @override
  Future<List<ClientRecord>> fetchClientsByType(ClientType type) async =>
      type == ClientType.unset
      ? const []
      : await _readFiltered(ClientsFilterType(type));

  @override
  Future<List<ClientRecord>> fetchClientsByBuilding(String key) async =>
      key.trim().isEmpty
      ? const []
      : await _readFiltered(ClientsFilterBuilding(key));

  @override
  Future<List<ClientBuilding>> fetchBuildings() async {
    final docs = await pageToCap(
      _firestore
          .collection('clientBuildings')
          .where('clientCount', isGreaterThanOrEqualTo: 2)
          .orderBy('clientCount', descending: true),
      pageSize: _clientScanPageSize,
      cap: _clientScanLimit,
      onCapReached: () =>
          _logger.warn('CLI-BUILDINGS catalog reached the display cap'),
    );
    final buildings =
        [
          for (final doc in docs)
            ClientBuilding(
              key: doc.data()['key'] as String,
              street: doc.data()['street'] as String,
              city: doc.data()['city'] as String,
              clientCount: (doc.data()['clientCount'] as num).toInt(),
            ),
        ]..sort((a, b) {
          final count = b.clientCount.compareTo(a.clientCount);
          return count != 0 ? count : a.street.compareTo(b.street);
        });
    return buildings;
  }

  @override
  Future<List<ClientRecord>> searchClients(
    String query, {
    ClientsFilter filter = const ClientsFilterAll(),
  }) async {
    final q = query.trim();
    if (!ClientSearchPolicy.shouldSearch(q)) return [];

    final cacheKey = jsonEncode([
      ClientSearchPolicy.cacheKey(q),
      _filterPayload(filter),
    ]);
    return await _searchCache.getOrLoad(
      cacheKey,
      () => _useCallableSearch
          ? _searchClientsCallable(q, filter)
          : _searchClientsLocal(q, filter),
    );
  }

  Map<String, Object> _filterPayload(ClientsFilter filter) => switch (filter) {
    ClientsFilterAll() => {},
    ClientsFilterArchived() => {'archived': true},
    ClientsFilterType(:final type) => {'archived': false, 'type': type.raw},
    ClientsFilterBuilding(:final key) => {
      'archived': false,
      'buildingKey': key,
    },
  };

  Future<List<ClientRecord>> _searchClientsCallable(
    String query,
    ClientsFilter filter,
  ) async {
    final response = await _callables
        .httpsCallable('searchClients')
        .call<Map<String, dynamic>>({
          'query': query,
          ..._filterPayload(filter),
        });
    final records = _clientsFromCallable(response.data);
    // The callable ends `orderBy("name")`, so without this the closest number
    // on a fallback rung can land third. This re-ranks the 25 it chose; WHICH
    // 25 come back is still the server's alphabetical read cap.
    final queryText = ClientSearchPolicy.normalize(query);
    final queryDigits = ClientSearchPolicy.digitsOnly(query);
    // Decorate-sort-undecorate, like `sortClients`: scoring inside the
    // comparator re-normalizes both operands on every comparison.
    final ranked =
        [
          for (final record in records)
            (
              score: ClientSearchPolicy.scoreRecord(
                record,
                queryText: queryText,
                queryDigits: queryDigits,
              ),
              sortKey: record.displayName.toLowerCase(),
              record: record,
            ),
        ]..sort((a, b) {
          final byScore = a.score.compareTo(b.score);
          return byScore != 0 ? byScore : a.sortKey.compareTo(b.sortKey);
        });
    return [for (final entry in ranked) entry.record];
  }

  Future<List<ClientRecord>> _searchClientsLocal(
    String query,
    ClientsFilter filter,
  ) async {
    final window = await _clientScanWindow();
    final docs = window.docs
        .where(
          (doc) => switch (filter) {
            ClientsFilterAll() => true,
            ClientsFilterArchived() => doc.data['archived'] == true,
            ClientsFilterType(:final type) =>
              doc.data['archived'] != true &&
                  ClientType.fromRaw(doc.data['type'] as String?) == type,
            ClientsFilterBuilding(:final key) =>
              doc.data['archived'] != true &&
                  buildingKeyFor(ClientRecord.fromMap(doc.id, doc.data)) == key,
          },
        )
        .toList();
    return matchClientDocs(ClientSearchScan(docs: docs, query: query));
  }

  Future<_CachedClientScanWindow> _clientScanWindow() async {
    final cached = _scanWindow;
    if (cached != null && _isFresh(cached.fetchedAt)) return cached;
    final existing = _pendingScan;
    if (existing != null) return await existing;
    _scanWindow = null;

    final pending = _loadClientScanWindow(_searchCache.generation);
    _pendingScan = pending;
    try {
      return await pending;
    } finally {
      if (identical(_pendingScan, pending)) _pendingScan = null;
    }
  }

  Future<_CachedClientScanWindow> _loadClientScanWindow(int generation) async {
    try {
      final scanned = await pageToCap(
        _clients.orderBy('name').orderBy(FieldPath.documentId),
        pageSize: _clientScanPageSize,
        cap: _clientScanLimit,
        onCapReached: () => _logger.warn(
          'CLI-SEARCH scan window hit the $_clientScanLimit-doc cap - '
          'clients past it are invisible to local fallback search',
        ),
        advance: (query, last) =>
            query.startAfter([(last.data()['name'] ?? '').toString(), last.id]),
      );
      final docs = <RawClientDoc>[
        for (final doc in scanned) (id: doc.id, data: doc.data()),
      ];
      final window = _CachedClientScanWindow(docs, _clock());
      if (generation == _searchCache.generation) _scanWindow = window;
      return window;
    } on FirebaseException catch (e, st) {
      _logger.warn('CLI-SEARCH searchClients failed', e, st);
      rethrow;
    }
  }

  Map<String, dynamic> _normalizedMap(ClientRecord client) {
    final base = Map<String, dynamic>.from(client.toMap());
    base['email'] = normalizeEmail(base['email'] as String? ?? '');
    base['phone'] = normalizePhoneForStorage(base['phone'] as String? ?? '');
    base['mobile'] = normalizePhoneForStorage(base['mobile'] as String? ?? '');
    final contacts = base['contacts'] as List? ?? const [];
    base['contacts'] = contacts.whereType<Map<Object?, Object?>>().map((c) {
      final m = Map<String, dynamic>.from(c);
      m['email'] = normalizeEmail(m['email'] as String? ?? '');
      m['phone'] = normalizePhoneForStorage(m['phone'] as String? ?? '');
      return m;
    }).toList();
    // Same field list the client-side matcher reads, so what is INDEXED and
    // what MATCHES can never drift apart.
    base['searchTokens'] = searchIndexTokens(
      texts: ClientSearchPolicy.rawTexts(base),
      phones: ClientSearchPolicy.rawPhones(base),
    );
    return base;
  }
}

List<ClientRecord> _clientsFromCallable(Object? data) {
  final raw = data;
  if (raw is! Map) return const [];
  final records = raw['clients'];
  if (records is! List) return const [];
  return [
    for (final entry in records.whereType<Map<Object?, Object?>>())
      ClientRecord.fromMap(
        (entry['id'] ?? '').toString(),
        Map<String, dynamic>.from(entry['data'] as Map? ?? const {}),
      ),
  ];
}

/// Raw doc without Firestore handles, safe to cross `compute` isolate boundary.
typedef RawClientDoc = ({String id, Map<String, dynamic> data});

/// `compute` payload for [matchClientDocs].
class ClientSearchScan {
  const ClientSearchScan({required this.docs, required this.query});

  final List<RawClientDoc> docs;
  final String query;
}

/// Parses scan window and returns clients matching [ClientSearchScan.query]
/// across all fields with relevance scoring.
List<ClientRecord> matchClientDocs(ClientSearchScan scan) {
  final normalizedQuery = ClientSearchPolicy.normalize(scan.query);
  final queryDigits = ClientSearchPolicy.digitsOnly(scan.query);

  final scoredClients = <({int score, String sortKey, ClientRecord record})>[];

  for (final doc in scan.docs) {
    final data = doc.data;

    // The MATCH TEST COMES FIRST, and everything the scoring ladder needs is
    // built below it — INCLUDING the record itself.
    if (!ClientSearchPolicy.rawMatches(
      data,
      queryText: normalizedQuery,
      queryDigits: queryDigits,
    )) {
      continue;
    }

    final client = ClientRecord.fromMap(doc.id, data);

    final rawDisplayName = client.displayName;
    final displayName = ClientSearchPolicy.normalize(rawDisplayName);
    final personName = ClientSearchPolicy.normalize(
      [
        data['firstName'],
        data['lastName'],
      ].whereType<Object>().map((v) => v.toString()).join(' '),
    );
    scoredClients.add((
      score: ClientSearchPolicy.relevanceScore(
        displayName: displayName,
        personName: personName,
        phoneDigits: ClientSearchPolicy.rawOwnPhoneDigits(data),
        contactsDigits: ClientSearchPolicy.rawContactPhoneDigits(data),
        queryText: normalizedQuery,
        queryDigits: queryDigits,
      ),
      sortKey: rawDisplayName.toLowerCase(),
      record: client,
    ));
  }

  scoredClients.sort((a, b) {
    final scoreCompare = a.score.compareTo(b.score);
    if (scoreCompare != 0) return scoreCompare;
    return a.sortKey.compareTo(b.sortKey);
  });

  return scoredClients
      .take(ClientSearchPolicy.resultDisplayLimit)
      .map((entry) => entry.record)
      .toList();
}

class _CachedClientScanWindow {
  _CachedClientScanWindow(this.docs, this.fetchedAt)
    : firstFetchedAt = fetchedAt;

  _CachedClientScanWindow._patched(
    this.docs,
    this.fetchedAt,
    this.firstFetchedAt,
  );

  final List<RawClientDoc> docs;
  final DateTime fetchedAt;
  final DateTime firstFetchedAt;

  _CachedClientScanWindow patched(
    List<RawClientDoc> next, {
    required DateTime at,
  }) => _CachedClientScanWindow._patched(next, at, firstFetchedAt);
}
