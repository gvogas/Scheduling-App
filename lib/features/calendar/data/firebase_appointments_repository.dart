import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:scheduling/core/data/paged_scan.dart';
import 'package:scheduling/core/data/search_result_cache.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/calendar/data/appointment_field_notes_store.dart';
import 'package:scheduling/features/calendar/data/appointment_images_store.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/assignee_availability.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
import 'package:scheduling/features/calendar/domain/models/repeat_interval.dart';
import 'package:scheduling/features/calendar/domain/overdue_review.dart';
import 'package:scheduling/features/calendar/domain/policies/history_search_policy.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:uuid/uuid.dart';

class FirebaseAppointmentsRepository implements AppointmentsRepository {
  FirebaseAppointmentsRepository(
    FirebaseFirestore firestore, {
    FirebaseFunctions? functions,
    AppLogger? logger,
    DateTime Function()? clock,
  }) : _appointments = firestore.collection('appointments'),
       _functions = functions,
       _logger = logger ?? AppLogger(),
       _clock = clock ?? DateTime.now {
    _images = AppointmentImagesStore(
      appointments: _appointments,
      logger: _logger,
    );
    _fieldNotes = AppointmentFieldNotesStore(
      appointments: _appointments,
      logger: _logger,
    );
  }

  final CollectionReference<Map<String, dynamic>> _appointments;
  final FirebaseFunctions? _functions;
  final AppLogger _logger;

  /// The photo half — the `appointments/{id}/images` subcollection.
  late final AppointmentImagesStore _images;

  /// The crew-notes half — the `appointments/{id}/fieldNotes` subcollection.
  late final AppointmentFieldNotesStore _fieldNotes;

  /// Lets tests inject a fake clock so the search-cache TTL is testable.
  final DateTime Function() _clock;

  /// Generates a fresh id for each write op, so all the notifications a single
  /// write triggers collapse into one per employee.
  String _newSeriesOpId() => const Uuid().v4();

  /// Ceiling on the live business-wide range listeners.
  static const int _rangeStreamLimit = 3000;

  /// Ceiling on one client's paged job history.
  static const int _clientHistoryScanLimit = 1000;

  /// Page size for that scan. Kept off the caller's `limit` so a busy client
  /// costs two round-trips to reach the ceiling, not twenty.
  static const int _clientHistoryPageSize = 500;

  /// Raw rows the overdue review's live query reads; mirrors the server's
  /// `MONTH_END_SCAN_MAX`, since personal blocks and days off never close.
  static const int _overdueScanLimit = 5000;

  /// Overdue jobs the review lists; mirrors `MONTH_END_REVIEW_MAX`.
  static const int _overdueReviewLimit = 1000;

  /// Bounded LRU of recent results.
  late final SearchResultCache<AppointmentRecord> _searchCache =
      SearchResultCache(clock: _clock);

  final Map<String, _CachedHistoryScanWindow> _historyWindows = {};

  /// The map key for a scope: `''` for the admin archive, `'emp:<id>'` for one
  /// person's.
  static String _scopeKey(String? employeeId) =>
      employeeId == null ? '' : 'emp:$employeeId';

  /// Clears callable search results after local appointment writes.
  void _patchWindow(Map<String, Map<String, dynamic>?> changes) {
    _searchCache.clear();
    // EVERY scope's window: a technician's is the same archive narrowed, so a
    // write that changes what history holds changes it for them too.
    for (final scope in _historyWindows.keys.toList()) {
      final window = _historyWindows[scope]!;
      if (!_searchCache.isFresh(window.fetchedAt)) {
        _historyWindows.remove(scope);
        continue;
      }
      _historyWindows[scope] = _CachedHistoryScanWindow(
        _patchHistoryDocs(window.docs, changes, scope: scope),
        _clock(),
      );
    }
    if (!_localWrites.isClosed) _localWrites.add(null);
  }

  /// Wakes `onLocalWrite` without touching the search cache.
  void _notifyLocalWrite() {
    if (!_localWrites.isClosed) _localWrites.add(null);
  }

  /// Unlike [_patchWindow] this does NOT poke `_localWrites`.
  @override
  void clearCaches() {
    _searchCache.clear();
    _historyWindows.clear();
  }

  final StreamController<void> _localWrites = StreamController.broadcast();

  @override
  Stream<void> get onLocalWrite => _localWrites.stream;

  void dispose() {
    unawaited(_localWrites.close());
  }

  @override
  String newDocId() => _appointments.doc().id;

  @override
  Future<AppointmentRecord?> getAppointmentById(String id) async {
    final doc = await _appointments.doc(id).get();
    if (!doc.exists) return null;
    return _recordFrom(doc.id, doc.data() ?? {});
  }

  AppointmentRecord _recordFrom(String id, Map<String, dynamic> data) {
    if (data['startTime'] == null || data['endTime'] == null) {
      _logger.breadcrumb(
        'APPT-LOAD $id has no startTime/endTime; substituting now',
      );
    }
    return AppointmentRecord.fromMap(id, data);
  }

  @override
  Future<int> countFutureAssignments(String employeeId) async {
    final now = DateTime.now();
    final snapshot = await _appointments
        .where('employeeIds', arrayContains: employeeId)
        .where('endTime', isGreaterThanOrEqualTo: Timestamp.fromDate(now))
        .limit(_futureAssignmentScanLimit)
        .get();
    if (snapshot.docs.length >= _futureAssignmentScanLimit) {
      _logger.warn(
        'APPT-COUNT future-assignment query hit the '
        '$_futureAssignmentScanLimit-doc cap - the caption is understating',
      );
    }
    return snapshot.docs
        .map((d) => AppointmentRecord.fromMap(d.id, d.data()))
        .where((a) => !isTerminalStatusRaw(a.status))
        .length;
  }

  @override
  Future<void> addAppointment(AppointmentRecord appointment) =>
      addAppointments([appointment]);

  @override
  Future<void> addAppointments(List<AppointmentRecord> appointments) async {
    final batch = _appointments.firestore.batch();
    final written = <String, Map<String, dynamic>?>{};
    for (final appointment in appointments) {
      final doc = appointment.id == null
          ? _appointments.doc()
          : _appointments.doc(appointment.id);
      written[doc.id] = _toFirestoreMap(appointment);
      batch.set(doc, {
        ..._toFirestoreMap(appointment),
        // The one client write of this counter the rules allow, and the reason
        // "absent" is not a state anything downstream has to interpret: the
        // recount trigger only fires on a photo write, so a job created without
        // it would read as count-unknown until its first photo.
        'pictureCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    _patchWindow(written);
  }

  @override
  Future<List<AppointmentRecord>> getSeries(String seriesId) async {
    final snapshot = await _appointments
        .where('seriesId', isEqualTo: seriesId)
        .limit(_seriesScanLimit)
        .get();
    if (snapshot.docs.length >= _seriesScanLimit) {
      _logger.warn(
        'APPT-LOAD series $seriesId hit the '
        '$_seriesScanLimit-doc cap - siblings beyond it were not loaded',
      );
    }
    return snapshot.docs
        .map((doc) => AppointmentRecord.fromMap(doc.id, doc.data()))
        .toList();
  }

  @override
  Future<void> rewriteSeries({
    required AppointmentRecord updated,
    required List<String> deleteIds,
    required List<AppointmentRecord> copies,
  }) async {
    final opId = _newSeriesOpId();
    final batch = _appointments.firestore.batch()
      ..update(_appointments.doc(updated.id), {
        ..._toFirestoreMap(updated),
        'seriesOpId': opId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    final written = <String, Map<String, dynamic>?>{
      updated.id!: _toFirestoreMap(updated),
      for (final id in deleteIds) id: null,
      for (final copy in copies) copy.id!: _toFirestoreMap(copy),
    };
    for (final id in deleteIds) {
      batch.delete(_appointments.doc(id));
    }
    for (final copy in copies) {
      batch.set(_appointments.doc(copy.id), {
        ..._toFirestoreMap(copy),
        // A copied occurrence is a new document — same reasoning as
        // `addAppointments`, and photos never come along with one.
        'pictureCount': 0,
        'seriesOpId': opId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    _patchWindow(written);
  }

  @override
  Future<void> updateAppointment(AppointmentRecord appointment) async {
    if (appointment.id == null) return;
    await _appointments.doc(appointment.id).update({
      ..._toFirestoreMap(appointment),
      'seriesOpId': _newSeriesOpId(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow({appointment.id!: _toFirestoreMap(appointment)});
  }

  @override
  Future<void> updateAppointments(List<AppointmentRecord> appointments) async {
    final records = [
      for (final a in appointments)
        if (a.id != null) a,
    ];
    if (records.isEmpty) return;
    final opId = _newSeriesOpId();
    final written = <String, Map<String, dynamic>?>{};
    await _appointments.firestore.runTransaction((txn) async {
      final refs = [for (final r in records) _appointments.doc(r.id)];
      final snaps = await Future.wait([for (final ref in refs) txn.get(ref)]);
      // Rebuilt per attempt: a transaction can re-run, and a set carried over
      // from an abandoned attempt would name docs this commit never touched.
      written.clear();
      for (var i = 0; i < records.length; i++) {
        if (!snaps[i].exists) continue;
        written[records[i].id!] = _toFirestoreMap(records[i]);
        txn.update(refs[i], {
          ..._toFirestoreMap(records[i]),
          'seriesOpId': opId,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    });
    _patchWindow(written);
  }

  @override
  Future<void> appendAppointmentPictures(
    String id,
    List<AppointmentImage> pictures,
  ) async {
    await _images.append(id, pictures);
    _notifyLocalWrite();
  }

  @override
  Future<void> removeAppointmentPictures(
    String id,
    List<AppointmentImage> pictures,
  ) async {
    await _images.remove(id, pictures);
    _notifyLocalWrite();
  }

  @override
  Future<List<AppointmentImage>> fetchAppointmentPictures(String id) =>
      _images.fetch(id);

  @override
  Future<void> appendFieldNote({
    required String appointmentId,
    required String text,
    required String authorId,
    required String authorName,
  }) async {
    await _fieldNotes.append(
      appointmentId,
      text: text,
      authorId: authorId,
      authorName: authorName,
    );
    // The narrow poke: a note changes no field matchHistoryDocs reads, so the
    // window is woken rather than rebuilt.
    _notifyLocalWrite();
  }

  @override
  Future<FieldNoteThread> fetchFieldNotes(String appointmentId) =>
      _fieldNotes.fetch(appointmentId);

  static const _allowedStatuses = {
    'pending',
    'in_progress',
    'done',
    'cancelled',
  };

  // NOT delegated to `updateAppointmentStatuses([id])`, though the bodies look
  // duplicated: this writes the document DIRECTLY while the plural commits a
  // WriteBatch.
  @override
  Future<void> updateFieldNotes({
    required String id,
    required String notes,
  }) async {
    // EXACTLY the two keys the assignee rules branch allows.
    await _appointments.doc(id).update({
      'fieldNotes': notes,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow({
      id: {'fieldNotes': notes},
    });
  }

  @override
  Future<void> updateAppointmentStatus({
    required String id,
    required String status,
  }) async {
    final trimmed = status.trim();
    if (!_allowedStatuses.contains(trimmed)) {
      throw ArgumentError.value(
        status,
        'status',
        'must be one of $_allowedStatuses',
      );
    }
    await _appointments.doc(id).update({
      'status': trimmed,
      if (trimmed == 'cancelled') 'seriesOpId': _newSeriesOpId(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow({
      id: {'status': trimmed},
    });
  }

  @override
  Future<void> updateAppointmentStatuses({
    required List<String> ids,
    required String status,
  }) async {
    final trimmed = status.trim();
    if (!_allowedStatuses.contains(trimmed)) {
      throw ArgumentError.value(
        status,
        'status',
        'must be one of $_allowedStatuses',
      );
    }
    if (ids.isEmpty) return;
    // One shared op id for EVERY status: it collapses cancel pushes and marks a bulk Complete as an admin write.
    final opId = _newSeriesOpId();
    final batch = _appointments.firestore.batch();
    for (final id in ids) {
      batch.update(_appointments.doc(id), {
        'status': trimmed,
        'seriesOpId': opId,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    _patchWindow({
      for (final id in ids) id: {'status': trimmed},
    });
  }

  @override
  Future<void> deleteAppointment(String id) => deleteAppointments([id]);

  @override
  Future<void> deleteAppointments(List<String> ids) async {
    final batch = _appointments.firestore.batch();
    for (final id in ids) {
      batch.delete(_appointments.doc(id));
    }
    await batch.commit();
    _patchWindow({for (final id in ids) id: null});
  }

  List<AppointmentRecord> _mapRangeSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    if (snapshot.docs.length >= _rangeStreamLimit) {
      _logger.warn(
        'APPT-LOAD range query hit the $_rangeStreamLimit-doc cap - '
        'appointments beyond it are not shown',
      );
    }
    return snapshot.docs
        .map((doc) => AppointmentRecord.fromMap(doc.id, doc.data()))
        .toList();
  }

  Query<Map<String, dynamic>> _rangeQuery(
    AppointmentDateRange range, {
    String? employeeId,
  }) {
    Query<Map<String, dynamic>> query = _appointments;
    if (employeeId != null) {
      query = query.where('employeeIds', arrayContains: employeeId);
    }
    return query
        .where(
          'startTime',
          isGreaterThanOrEqualTo: Timestamp.fromDate(range.fetchStart),
        )
        .where('startTime', isLessThan: Timestamp.fromDate(range.end))
        .orderBy('startTime')
        .limit(_rangeStreamLimit);
  }

  @override
  Stream<List<AppointmentRecord>> watchInRange(AppointmentDateRange range) {
    return retryStream(
      () => _rangeQuery(range).snapshots().map(_mapRangeSnapshot),
    );
  }

  @override
  Stream<List<AppointmentRecord>> watchOverdueOpen(DateTime now) {
    var hasWarned = false;
    return retryStream(
      () => _appointments
          .where('status', whereIn: openStatusQueryValues)
          .where('endTime', isLessThan: Timestamp.fromDate(now))
          .orderBy('endTime', descending: true)
          // One past the cap tells a full window from an exactly-full one.
          .limit(_overdueScanLimit + 1)
          .snapshots()
          .map((snapshot) {
            final scanFull = snapshot.docs.length > _overdueScanLimit;
            final overdue = overdueJobsAt(
              snapshot.docs
                  .take(_overdueScanLimit)
                  .map((doc) => AppointmentRecord.fromMap(doc.id, doc.data())),
              now,
            );
            final isOverList = overdue.length > _overdueReviewLimit;
            if (!hasWarned && (scanFull || isOverList)) {
              hasWarned = true;
              _logger.warn(
                scanFull
                    ? 'APPT-REVIEW overdue query filled its '
                          '$_overdueScanLimit-row scan - any overdue job older '
                          'than the window is not listed'
                    : 'APPT-REVIEW ${overdue.length} overdue jobs past the '
                          '$_overdueReviewLimit-job list cap - the newest are '
                          'not listed',
              );
            }
            return isOverList
                ? overdue.sublist(0, _overdueReviewLimit)
                : overdue;
          }),
    );
  }

  @override
  Future<List<AppointmentRecord>> fetchInRange(
    AppointmentDateRange range,
  ) async {
    final snapshot = await retryAsync(() => _rangeQuery(range).get());
    return _mapRangeSnapshot(snapshot);
  }

  /// The terminal archive, business-wide or narrowed to one assignee.
  Query<Map<String, dynamic>> _historyQuery(String? employeeId) {
    Query<Map<String, dynamic>> query = _appointments;
    if (employeeId != null) {
      query = query.where('employeeIds', arrayContains: employeeId);
    }
    return query.where('status', whereIn: terminalStatusQueryValues);
  }

  @override
  Future<List<AppointmentRecord>> fetchHistoryPage({
    required int limit,
    AppointmentRecord? after,
    String? employeeId,
  }) async {
    var query = _historyQuery(employeeId)
        .orderBy('startTime', descending: true)
        .orderBy(FieldPath.documentId, descending: true);
    final afterId = after?.id;
    if (after != null && afterId != null) {
      query = query.startAfter([Timestamp.fromDate(after.startTime), afterId]);
    }
    final snapshot = await query.limit(limit).get();
    return snapshot.docs
        .map((doc) => AppointmentRecord.fromMap(doc.id, doc.data()))
        .toList();
  }

  @override
  Future<List<AppointmentRecord>> fetchClientHistory({
    required String clientId,
    int limit = _clientHistoryPageSize,
    int? cap,
  }) async {
    if (clientId.isEmpty) return const [];
    final scanCap = cap ?? _clientHistoryScanLimit;
    // The warn belongs to the DEFAULT cap, which is a silent truncation of a
    // list meant to be complete. An explicit cap is a deliberate window — the
    // booking form asks for the newest 20 — and reaching it is the normal case
    // for exactly the repeat clients it serves, so warning there files a
    // Crashlytics non-fatal on every form open and buries the real one.
    final docs = await pageToCap(
      _appointments
          .where('clientId', isEqualTo: clientId)
          .orderBy('startTime', descending: true),
      pageSize: limit,
      cap: scanCap,
      onCapReached: () {
        const message =
            'APPT-LOAD client history hit the cap - older visits are not listed';
        if (cap != null) {
          _logger.breadcrumb('$message (deliberate $scanCap-visit window)');
          return;
        }
        _logger.warn('$message ($scanCap)');
      },
    );
    // A multi-day run is ONE visit stored as one document per work day, so
    // listing every document rendered a Monday-to-Friday job as five identical
    // rows — and burned five of the section's 50-row render bound.
    return docs
        .map((doc) => _recordFrom(doc.id, doc.data()))
        .where((record) => record.dayIndex <= 1)
        .toList();
  }

  static const int _futureAssignmentScanLimit = 200;
  static const int _seriesScanLimit = RepeatInterval.maxOccurrences + 1;

  @override
  Future<List<AppointmentRecord>> searchHistory(
    String query, {
    String? employeeId,
  }) async {
    final q = query.trim();
    if (!ClientSearchPolicy.shouldSearch(q)) return const [];

    // Scope is part of the key: the same words searched by an admin and by a
    // technician are two different answers.
    final scope = _scopeKey(employeeId);
    final cacheKey = '$scope|${ClientSearchPolicy.cacheKey(q)}';
    final cached = _searchCache.read(cacheKey);
    if (cached != null) return cached;

    final functions = _functions;
    if (functions == null) {
      final window = await _historyScanWindow(employeeId, scope: scope);
      final matches = matchHistoryDocs(
        HistorySearchScan(docs: window.docs, query: q),
      );
      _searchCache.write(cacheKey, matches);
      return matches;
    }

    final payload = <String, Object>{'query': q};
    if (employeeId != null) payload['employeeId'] = employeeId;

    final response = await functions
        .httpsCallable('searchHistory')
        .call<Map<String, dynamic>>(payload);
    final matches = _appointmentsFromCallable(response.data);
    _searchCache.write(cacheKey, matches);
    return matches;
  }

  @override
  Stream<List<AppointmentRecord>> watchForEmployeeInRange(
    String employeeId,
    AppointmentDateRange range,
  ) {
    return retryStream(
      () => _rangeQuery(
        range,
        employeeId: employeeId,
      ).snapshots().map(_mapRangeSnapshot),
    );
  }

  @override
  Future<List<EmployeeRecord>> findBusyEmployees({
    required List<EmployeeRecord> candidates,
    required DateTime start,
    required DateTime end,
    String? excludeAppointmentId,
  }) async {
    if (candidates.isEmpty) return const [];

    // The busy PEOPLE are the clashing records' assignees: same query, same
    // rule, one owner.
    final clashes = await findClashingAppointments(
      employeeIds: candidates.map((e) => e.id).toList(),
      start: start,
      end: end,
      excludeAppointmentId: excludeAppointmentId,
    );
    final busyIds = {for (final a in clashes) ...a.employeeIds};
    return candidates.where((e) => busyIds.contains(e.id)).toList();
  }

  @override
  Future<List<AppointmentRecord>> findClashingAppointments({
    required List<String> employeeIds,
    required DateTime start,
    required DateTime end,
    String? excludeAppointmentId,
    bool clientJobsOnly = false,
  }) async {
    if (employeeIds.isEmpty) return const [];

    final functions = _functions;
    if (functions == null) {
      return await _findClashingAppointmentsLocal(
        employeeIds: employeeIds,
        start: start,
        end: end,
        excludeAppointmentId: excludeAppointmentId,
        clientJobsOnly: clientJobsOnly,
      );
    }

    final payload = <String, Object>{
      'employeeIds': employeeIds,
      'startMillis': start.millisecondsSinceEpoch,
      'endMillis': end.millisecondsSinceEpoch,
      'clientJobsOnly': clientJobsOnly,
    };
    if (excludeAppointmentId != null) {
      payload['excludeAppointmentId'] = excludeAppointmentId;
    }

    final response = await functions
        .httpsCallable('findAppointmentConflicts')
        .call<Map<String, dynamic>>(payload);
    return _appointmentsFromCallable(response.data);
  }

  /// The record as Firestore fields.
  Map<String, dynamic> _toFirestoreMap(AppointmentRecord appointment) {
    final base = Map<String, dynamic>.from(appointment.toMap());
    base['startTime'] = Timestamp.fromDate(appointment.startTime);
    base['endTime'] = Timestamp.fromDate(appointment.endTime);
    base['historySearchScopes'] = _historySearchScopes(base);
    return base;
  }

  /// Hand-mirrored by `appointmentHistoryScopes` in
  /// `functions/search_tokens.js`; change both together.
  List<String> _historySearchScopes(Map<String, dynamic> map) {
    final employeeIds = firestoreStringList(map['employeeIds']);
    // The field carries every token once per scope, so the per-scope budget is
    // the field cap divided by the scope count — NOT the query-side limit.
    final scopeCount = 1 + employeeIds.length;
    final tokens = searchIndexTokens(
      texts: [
        (map['clientName'] ?? '').toString(),
        for (final name in firestoreStringList(map['employeeNames'])) name,
      ],
      phones: [(map['clientPhone'] ?? '').toString()],
      limit: (kSearchTokenFieldLimit / scopeCount).floor().clamp(
        1,
        kSearchTokenFieldLimit,
      ),
    );
    return [
      for (final token in tokens) 'all:$token',
      for (final employeeId in employeeIds)
        for (final token in tokens) 'emp:$employeeId:$token',
    ].take(kSearchTokenFieldLimit).toList();
  }

  @override
  Future<void> restoreAppointmentStatus({
    required String id,
    required String previousStatus,
  }) async {
    final trimmed = previousStatus.trim();
    if (!_allowedStatuses.contains(trimmed) || isTerminalStatusRaw(trimmed)) {
      throw ArgumentError.value(
        previousStatus,
        'previousStatus',
        'must be pending or in_progress',
      );
    }
    final functions = _functions;
    if (functions == null) {
      await updateAppointmentStatus(id: id, status: trimmed);
      return;
    }
    await functions.httpsCallable('restoreAppointmentStatus').call<void>({
      'appointmentId': id,
      'previousStatus': trimmed,
    });
    _patchWindow({
      id: {'status': trimmed},
    });
  }

  static const int _historySearchPageSize = 500;
  static const int _historySearchScanLimit = 5000;
  static const int _conflictScanLimit = 1000;

  Future<_CachedHistoryScanWindow> _historyScanWindow(
    String? employeeId, {
    required String scope,
  }) async {
    final cached = _historyWindows[scope];
    if (cached != null && _searchCache.isFresh(cached.fetchedAt)) {
      return cached;
    }
    final docs = await pageToCap(
      _historyQuery(employeeId).orderBy('startTime', descending: true),
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
    _historyWindows[scope] = window;
    return window;
  }

  /// One pass over the window: every change is merged in place, and a doc the
  /// window has not seen is inserted at its `startTime` position rather than
  /// appended, because the window is `startTime` DESC.
  List<RawHistoryDoc> _patchHistoryDocs(
    List<RawHistoryDoc> docs,
    Map<String, Map<String, dynamic>?> changes, {
    required String scope,
  }) {
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
      if (data != null && _belongsInHistoryScope(data, scope)) {
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
      if (!_belongsInHistoryScope(data, scope)) continue;
      next.insert(_insertIndexFor(next, data), (id: entry.key, data: data));
    }
    return next;
  }

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

  bool _belongsInHistoryScope(Map<String, dynamic> data, String scope) {
    if (!isTerminalStatusRaw((data['status'] ?? '').toString())) return false;
    if (scope.isEmpty) return true;
    final employeeId = scope.startsWith('emp:') ? scope.substring(4) : scope;
    return firestoreStringList(data['employeeIds']).contains(employeeId);
  }

  Future<List<AppointmentRecord>> _findClashingAppointmentsLocal({
    required List<String> employeeIds,
    required DateTime start,
    required DateTime end,
    required String? excludeAppointmentId,
    required bool clientJobsOnly,
  }) async {
    final byId = <String, AppointmentRecord>{};
    final windowUnknownIds = <String>{};
    final snapshots = await Future.wait([
      for (var i = 0; i < employeeIds.length; i += 30)
        _appointments
            .where(
              'employeeIds',
              arrayContainsAny: employeeIds.skip(i).take(30).toList(),
            )
            .where('startTime', isLessThan: Timestamp.fromDate(end))
            .where('endTime', isGreaterThan: Timestamp.fromDate(start))
            .limit(_conflictScanLimit)
            .get(),
    ]);
    for (final snapshot in snapshots) {
      if (snapshot.docs.length >= _conflictScanLimit) {
        _logger.warn(
          'APPT-BUSY conflict query hit the $_conflictScanLimit-doc cap - '
          'some clashes may be missing',
        );
      }
      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (firestoreDateTime(data['startTime']) == null ||
            firestoreDateTime(data['endTime']) == null) {
          windowUnknownIds.add(doc.id);
        }
        byId[doc.id] = _recordFrom(doc.id, data);
      }
    }
    return clashingAppointments(
      appointments: byId.values,
      start: start,
      end: end,
      excludeAppointmentId: excludeAppointmentId,
      clientJobsOnly: clientJobsOnly,
      windowUnknownIds: windowUnknownIds,
    );
  }
}

List<AppointmentRecord> _appointmentsFromCallable(Object? data) {
  final raw = data;
  if (raw is! Map) return const [];
  final records = raw['appointments'];
  if (records is! List) return const [];
  return [
    for (final entry in records.whereType<Map<Object?, Object?>>())
      AppointmentRecord.fromMap(
        (entry['id'] ?? '').toString(),
        Map<String, dynamic>.from(entry['data'] as Map? ?? const {}),
      ),
  ];
}

class _CachedHistoryScanWindow {
  const _CachedHistoryScanWindow(this.docs, this.fetchedAt);

  final List<RawHistoryDoc> docs;
  final DateTime fetchedAt;
}
