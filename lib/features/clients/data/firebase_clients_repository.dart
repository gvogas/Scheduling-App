import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:scheduling/core/data/paged_scan.dart';
import 'package:scheduling/core/data/search_result_cache.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/core/validators/email_format.dart';
import 'package:scheduling/core/validators/phone_format.dart';
import 'package:scheduling/features/clients/domain/clients_failure.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
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
       _functions = functions,
       _logger = logger ?? AppLogger(),
       _clock = clock ?? DateTime.now,
       _useCallableSearch = useCallableSearch ?? functions != null;

  final CollectionReference<Map<String, dynamic>> _clients;
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
  void _patchWindow(String id, {Map<String, dynamic>? data}) {
    final window = _scanWindow;
    if (window != null && _isFresh(window.fetchedAt)) {
      final previous = window.docs
          .where((doc) => doc.id == id)
          .firstOrNull
          ?.data;
      final docs = [
        for (final doc in window.docs)
          if (doc.id != id) doc,
        if (data != null) (id: id, data: {...?previous, ...data}),
      ];
      _scanWindow = window.patched(docs, id, at: _patchedFetchedAt(window));
    } else {
      _scanWindow = null;
    }
    _searchCache.clear();
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
    _pageBoundaryValues.clear();
  }

  @override
  Future<List<ClientRecord>> fetchClientsPage({
    required int limit,
    ClientRecord? after,
    ClientsSort sort = ClientsSort.name,
  }) async {
    var query = _clients
        .where('archived', isEqualTo: false)
        .orderBy(sort.field, descending: sort.descending)
        .orderBy(FieldPath.documentId);
    if (after != null) {
      query = query.startAfter([
        _pageBoundaryValues['${sort.name}:${after.id}'] ??
            _fallbackCursorValue(after, sort),
        after.id,
      ]);
    }
    final snapshot = await query.limit(limit).get();
    final docs = snapshot.docs;
    if (docs.isNotEmpty) {
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
    _patchWindow(id, data: {'archived': archived});
  }

  @override
  Future<List<ClientRecord>> fetchArchivedClients() async {
    final window = await _clientScanWindow();
    if (window == null) return const [];
    return sortClients([
      for (final doc in window.docs)
        if (doc.data['archived'] == true)
          ClientRecord.fromMap(doc.id, doc.data),
    ], ClientsSort.name);
  }

  @override
  Future<List<ClientRecord>> fetchClientsByType(ClientType type) async {
    if (type == ClientType.unset) return const [];
    final records = await _windowRecords();
    return sortClients([
      for (final record in records)
        if (record.type == type) record,
    ], ClientsSort.name);
  }

  @override
  Future<List<ClientRecord>> fetchClientsByBuilding(String key) async {
    if (key.trim().isEmpty) return const [];
    final window = await _clientScanWindow();
    if (window == null) return const [];
    // The keys are already on the window — deriving them again here was a
    // second full O(window) pass on every building-filter selection.
    final matches = [
      for (final record in window.records)
        if (window.buildingKeys[record.id] == key) record,
    ];
    return sortClients(matches, ClientsSort.name);
  }

  @override
  Future<List<ClientBuilding>> fetchBuildings() async =>
      (await _clientScanWindow())?.buildings ?? const [];

  /// The cached scan window as live records, archived clients dropped — the
  /// shape the type filter and the Building menu both reduce over.
  Future<List<ClientRecord>> _windowRecords() async =>
      (await _clientScanWindow())?.records ?? const [];

  @override
  Future<List<ClientRecord>> searchClients(String query) async {
    final q = query.trim();
    if (!ClientSearchPolicy.shouldSearch(q)) return [];

    final cacheKey = ClientSearchPolicy.cacheKey(q);
    final cached = _searchCache.read(cacheKey);
    if (cached != null) return cached;

    final results = _useCallableSearch
        ? await _searchClientsCallable(q)
        : await _searchClientsLocal(q);
    _searchCache.write(cacheKey, results);
    return results;
  }

  Future<List<ClientRecord>> _searchClientsCallable(String query) async {
    final response = await _callables
        .httpsCallable('searchClients')
        .call<Map<String, dynamic>>({'query': query});
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

  Future<List<ClientRecord>> _searchClientsLocal(String query) async {
    final window = await _clientScanWindow();
    if (window == null) return const [];
    return matchClientDocs(ClientSearchScan(docs: window.docs, query: query));
  }

  Future<_CachedClientScanWindow?> _clientScanWindow() async {
    final cached = _scanWindow;
    if (cached != null && _isFresh(cached.fetchedAt)) return cached;
    _scanWindow = null;

    try {
      final scanned = await pageToCap(
        _clients.orderBy('name').orderBy(FieldPath.documentId),
        pageSize: _clientScanPageSize,
        cap: _clientScanLimit,
        onCapReached: () => _logger.warn(
          'CLI-SEARCH scan window hit the $_clientScanLimit-doc cap - '
          'clients past it are invisible to search and to the filter chips',
        ),
        advance: (query, last) =>
            query.startAfter([(last.data()['name'] ?? '').toString(), last.id]),
      );
      final docs = <RawClientDoc>[
        for (final doc in scanned) (id: doc.id, data: doc.data()),
      ];
      final window = _CachedClientScanWindow(docs, _clock());
      _scanWindow = window;
      return window;
    } on FirebaseException catch (e, st) {
      _logger.warn('CLI-SEARCH searchClients failed', e, st);
      return null;
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
    this._records,
    this._buildingKeys,
  );

  final List<RawClientDoc> docs;

  /// When this window was last considered current.
  final DateTime fetchedAt;

  /// When the underlying Firestore read actually happened.
  final DateTime firstFetchedAt;

  List<ClientRecord>? _records;
  Map<String, String?>? _buildingKeys;
  List<ClientBuilding>? _buildings;

  /// Materialized once per window.
  List<ClientRecord> get records => _records ??= [
    for (final doc in docs)
      if (doc.data['archived'] != true) ClientRecord.fromMap(doc.id, doc.data),
  ];

  /// Every record's building key, derived ONCE per window.
  Map<String, String?> get buildingKeys =>
      _buildingKeys ??= buildingKeysIn(records);

  /// `buildingsIn` runs `buildingKeyFor` over every record, so it is memoized
  /// on the same key rather than recomputed per Building-menu build — and it
  /// reads [buildingKeys] rather than deriving them again.
  List<ClientBuilding> get buildings =>
      _buildings ??= buildingsIn(records, keys: buildingKeys);

  /// The window after a local write, carrying the derived maps ACROSS it.
  _CachedClientScanWindow patched(
    List<RawClientDoc> next,
    String changedId, {
    required DateTime at,
  }) {
    final cachedRecords = _records;
    // Nothing has read the derived maps yet, so there is nothing to carry and a
    // plain window is both correct and free.
    if (cachedRecords == null) {
      return _CachedClientScanWindow._patched(
        next,
        at,
        firstFetchedAt,
        null,
        null,
      );
    }

    final doc = next.where((d) => d.id == changedId).firstOrNull;
    // Absent (a delete) or archived: it leaves `records`, which excludes
    // archived clients, so the key map must lose the entry rather than keep a
    // stale one.
    final record = doc == null || doc.data['archived'] == true
        ? null
        : ClientRecord.fromMap(doc.id, doc.data);

    final records = [
      for (final r in cachedRecords)
        if (r.id != changedId) r,
      ?record,
    ];

    final cachedKeys = _buildingKeys;
    final buildingKeys = cachedKeys == null
        ? null
        : {
            for (final entry in cachedKeys.entries)
              if (entry.key != changedId) entry.key: entry.value,
            if (record != null) record.id: buildingKeyFor(record),
          };

    return _CachedClientScanWindow._patched(
      next,
      at,
      firstFetchedAt,
      records,
      buildingKeys,
    );
  }
}
