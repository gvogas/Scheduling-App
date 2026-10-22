import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:scheduling/core/data/paged_scan.dart';
import 'package:scheduling/core/data/search_result_cache.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/policies/history_search_policy.dart';

/// History search's cached answers and its local scan window, patched on write.
class AppointmentHistoryScan {
  AppointmentHistoryScan({
    required Query<Map<String, dynamic>> Function() query,
    required AppLogger logger,
    required DateTime Function() clock,
  }) : _query = query,
       _logger = logger,
       _clock = clock;

  /// The business-wide terminal archive, built only when a scan runs.
  final Query<Map<String, dynamic>> Function() _query;
  final AppLogger _logger;
  final DateTime Function() _clock;

  static const int _historySearchPageSize = 500;
  static const int _historySearchScanLimit = 5000;

  /// Bounded LRU of recent results.
  late final SearchResultCache<AppointmentRecord> results = SearchResultCache(
    clock: _clock,
  );

  _CachedHistoryScanWindow? _historyWindow;
  Future<_CachedHistoryScanWindow>? _pendingHistoryScan;

  /// The newest terminal docs, `startTime` DESC, paged to the cap.
  Future<List<RawHistoryDoc>> window() async => (await _scanWindow()).docs;

  /// Patches cached answers and the window after a local write.
  void patch(Map<String, Map<String, dynamic>?> changes) {
    results.patchAll((_, cached) => _patchSearchResults(cached, changes));
    _pendingHistoryScan = null;
    final window = _historyWindow;
    if (window != null) {
      _historyWindow = results.isFresh(window.fetchedAt)
          ? _CachedHistoryScanWindow(
              _patchHistoryDocs(window.docs, changes),
              _clock(),
            )
          : null;
    }
  }

  void clear() {
    results.clear();
    _historyWindow = null;
    _pendingHistoryScan = null;
  }

  Future<_CachedHistoryScanWindow> _scanWindow() async {
    final cached = _historyWindow;
    if (cached != null && results.isFresh(cached.fetchedAt)) {
      return cached;
    }
    final existing = _pendingHistoryScan;
    if (existing != null) return await existing;
    final pending = _loadHistoryScanWindow(generation: results.generation);
    _pendingHistoryScan = pending;
    try {
      return await pending;
    } finally {
      if (identical(_pendingHistoryScan, pending)) _pendingHistoryScan = null;
    }
  }

  Future<_CachedHistoryScanWindow> _loadHistoryScanWindow({
    required int generation,
  }) async {
    final docs = await pageToCap(
      _query().orderBy('startTime', descending: true),
      pageSize: _historySearchPageSize,
      cap: _historySearchScanLimit,
      onCapReached: () => _logger.warn(
        'HIST-SEARCH scan window hit the $_historySearchScanLimit-doc cap - '
        'older appointments are invisible to search',
      ),
    );
    final window = _CachedHistoryScanWindow([
      for (final doc in docs) (id: doc.id, data: doc.data()),
    ], _clock());
    if (generation == results.generation) _historyWindow = window;
    return window;
  }

  /// Merges changes in place; a new doc is inserted at its `startTime` DESC position.
  List<RawHistoryDoc> _patchHistoryDocs(
    List<RawHistoryDoc> docs,
    Map<String, Map<String, dynamic>?> changes,
  ) {
    final merged = <String, Map<String, dynamic>?>{};
    final next = <RawHistoryDoc>[];
    for (final doc in docs) {
      if (!changes.containsKey(doc.id)) {
        next.add(doc);
        continue;
      }
      final patch = changes[doc.id];
      final data = patch == null
          ? null
          : {
              ...doc.data,
              for (final e in patch.entries)
                if (e.value is! FieldValue) e.key: e.value,
            };
      merged[doc.id] = data;
      if (data != null && _belongsInHistory(data)) {
        next.add((id: doc.id, data: data));
      }
    }
    for (final entry in changes.entries) {
      if (merged.containsKey(entry.key)) continue;
      final data = entry.value;
      // Only a whole document can be placed: a field patch has no date.
      if (data == null || firestoreDateTime(data['startTime']) == null) {
        continue;
      }
      if (!_belongsInHistory(data)) continue;
      next.insert(_insertIndexFor(next, data), (id: entry.key, data: data));
    }
    return next;
  }

  /// A cached answer patched like the window; null when it may now be short.
  List<AppointmentRecord>? _patchSearchResults(
    List<AppointmentRecord> results,
    Map<String, Map<String, dynamic>?> changes,
  ) {
    final seen = <String>{};
    final next = <AppointmentRecord>[];
    for (final record in results) {
      final id = record.id;
      if (id == null || !changes.containsKey(id)) {
        next.add(record);
        continue;
      }
      seen.add(id);
      final patch = changes[id];
      if (patch == null) continue;
      final data = {
        ...rawOf(record),
        for (final e in patch.entries)
          if (e.value is! FieldValue) e.key: e.value,
      };
      if (!_belongsInHistory(data)) continue;
      // A renamed client or crew may no longer match the query.
      if (_movesSearchFields(record, patch)) return null;
      next.add(AppointmentRecord.fromMap(id, data));
    }
    for (final entry in changes.entries) {
      final data = entry.value;
      if (seen.contains(entry.key) || data == null) continue;
      // Only the query knows whether a newly terminal doc matches it.
      if (_belongsInHistory(data)) return null;
    }
    return next;
  }

  /// Whether [patch] changes a field `historyEntryOf` reads.
  static bool _movesSearchFields(
    AppointmentRecord record,
    Map<String, dynamic> patch,
  ) {
    bool moved(String key, String current) =>
        patch.containsKey(key) && (patch[key] ?? '').toString() != current;
    return moved('clientName', record.clientName) ||
        moved('clientPhone', record.clientPhone) ||
        (patch.containsKey('employeeNames') &&
            firestoreStringList(patch['employeeNames']).join('\n') !=
                record.employeeNames.join('\n'));
  }

  /// A record's fields in stored shape, including those `toMap` leaves out.
  static Map<String, dynamic> rawOf(AppointmentRecord record) => {
    ...record.toMap(),
    'createdAt': record.createdAt,
    'updatedAt': record.updatedAt,
    'pictureCount': record.pictureCount,
    'startedAt': record.startedAt,
    'completedAt': record.completedAt,
  };

  /// Where [doc] belongs in a `startTime` DESC window.
  static int _insertIndexFor(
    List<RawHistoryDoc> docs,
    Map<String, dynamic> doc,
  ) {
    final at = firestoreDateTime(doc['startTime'])!;
    for (var i = 0; i < docs.length; i++) {
      final other = firestoreDateTime(docs[i].data['startTime']);
      if (other == null || other.isBefore(at)) return i;
    }
    return docs.length;
  }

  static bool _belongsInHistory(Map<String, dynamic> data) =>
      isTerminalStatusRaw((data['status'] ?? '').toString());
}

class _CachedHistoryScanWindow {
  const _CachedHistoryScanWindow(this.docs, this.fetchedAt);

  final List<RawHistoryDoc> docs;
  final DateTime fetchedAt;
}
