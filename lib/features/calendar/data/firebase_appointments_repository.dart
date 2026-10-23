import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:scheduling/core/app/session_fence.dart';

import 'package:scheduling/core/data/paged_scan.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/performance/performance_trace.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/core/utils/firestore_parsing.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/calendar/data/appointment_field_notes_store.dart';
import 'package:scheduling/features/calendar/data/appointment_history_scan.dart';
import 'package:scheduling/features/calendar/data/appointment_images_store.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/assignee_availability.dart';
import 'package:scheduling/features/calendar/domain/calendar_failure.dart';
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
    SessionFence? session,
  }) : _appointments = firestore.collection('appointments'),
       _functions = functions,
       _session = session,
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
  final SessionFence? _session;

  @override
  bool Function()? captureWriteOwner() {
    final session = _session;
    if (session == null) return null;
    final lease = session.capture();
    return () => lease?.isCurrent == true;
  }

  final AppLogger _logger;

  /// The photo half — the `appointments/{id}/images` subcollection.
  late final AppointmentImagesStore _images;

  /// The crew-notes half — the `appointments/{id}/fieldNotes` subcollection.
  late final AppointmentFieldNotesStore _fieldNotes;

  /// Lets tests inject a fake clock so the search-cache TTL is testable.
  final DateTime Function() _clock;

  /// A fresh `seriesOpId` per write op, so one write notifies each employee once.
  String _newSeriesOpId() => const Uuid().v4();

  /// Ceiling on the live business-wide range listeners.
  static const int _rangeStreamLimit = 3000;

  /// Ceiling on one client's paged job history.
  static const int _clientHistoryScanLimit = 1000;

  /// Page size for that scan, deliberately not the caller's display `limit`.
  static const int _clientHistoryPageSize = 500;

  /// Raw rows the overdue review's live query reads; mirrors `MONTH_END_SCAN_MAX`.
  static const int _overdueScanLimit = 5000;

  /// Overdue jobs the review lists; mirrors `MONTH_END_REVIEW_MAX`.
  static const int _overdueReviewLimit = 1000;

  /// History search's cached answers and scan window.
  late final AppointmentHistoryScan _historyScan = AppointmentHistoryScan(
    query: () => _historyQuery,
    logger: _logger,
    clock: _clock,
  );

  /// Patches cached search answers and the scan window after a local write.
  void _patchWindow(Map<String, Map<String, dynamic>?> changes) {
    _historyScan.patch(changes);
    if (!_recordWrites.isClosed) {
      _recordWrites.add({
        for (final change in changes.entries)
          change.key: firestoreDateTime(change.value?['startTime']),
      });
    }
    if (!_localWrites.isClosed) _localWrites.add(null);
  }

  /// Wakes `onLocalWrite` only: a photo or crew-note write changes no field.
  void _notifyLocalWrite() {
    if (!_localWrites.isClosed) _localWrites.add(null);
  }

  /// Unlike [_patchWindow] this does NOT poke `_localWrites`.
  @override
  void clearCaches() {
    _acknowledgedWrites.clear();
    _historyScan.clear();
  }

  final StreamController<void> _localWrites = StreamController.broadcast();
  final StreamController<Map<String, DateTime?>> _recordWrites =
      StreamController.broadcast();

  @override
  Stream<void> get onLocalWrite => _localWrites.stream;

  @override
  Stream<Map<String, DateTime?>> get onRecordWrite => _recordWrites.stream;

  void dispose() {
    unawaited(_localWrites.close());
    unawaited(_recordWrites.close());
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
    final now = _clock();
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
  Future<void> addAppointment(
    AppointmentRecord appointment, {
    bool checkConflicts = false,
  }) => addAppointments([appointment], checkConflicts: checkConflicts);

  @override
  Future<void> addAppointments(
    List<AppointmentRecord> appointments, {
    bool checkConflicts = false,
  }) async {
    final records = [
      for (final appointment in appointments)
        if (appointment.id == null)
          appointment.copyWith(id: _appointments.doc().id)
        else
          appointment,
    ];
    if (_functions != null) {
      await _commitEdits(creates: records, checkConflicts: checkConflicts);
      return;
    }
    if (checkConflicts) await _refuseLocalClash(records);
    final batch = _appointments.firestore.batch();
    final written = <String, Map<String, dynamic>?>{};
    for (final appointment in records) {
      final doc = _appointments.doc(appointment.id);
      written[doc.id] = _toFirestoreMap(appointment);
      batch.set(doc, {
        ..._toFirestoreMap(appointment),
        // The one client write of this counter the rules allow (see images.md).
        'pictureCount': 0,
        'editProtocol': 1,
        'editRevision': 0,
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
    AppointmentRecord? base,
    List<AppointmentRecord> deleteBases = const [],
    bool checkConflicts = false,
  }) async {
    if (_functions != null) {
      if (base == null || deleteBases.length != deleteIds.length) {
        throw StateError('Appointment rewrite requires every original record');
      }
      await _commitEdits(
        edits: [(base: base, updated: updated)],
        creates: copies,
        deletes: deleteBases,
        checkConflicts: checkConflicts,
      );
      return;
    }
    if (checkConflicts) {
      await _refuseLocalClash(
        [updated, ...copies],
        excludeIds: {?updated.id, ...deleteIds},
      );
    }
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
        // A copied occurrence is a new document with no photos.
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
  Future<void> updateAppointment(
    AppointmentRecord appointment, {
    AppointmentRecord? base,
    bool checkConflicts = false,
  }) async {
    if (appointment.id == null) return;
    if (_functions != null) {
      if (base == null) {
        throw StateError('Appointment edit requires original record');
      }
      await _commitEdits(
        edits: [(base: base, updated: appointment)],
        checkConflicts: checkConflicts,
      );
      return;
    }
    if (checkConflicts) {
      await _refuseLocalClash([appointment], excludeIds: {appointment.id!});
    }
    await _appointments.doc(appointment.id).update({
      ..._toFirestoreMap(appointment),
      'seriesOpId': _newSeriesOpId(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    _patchWindow({appointment.id!: _toFirestoreMap(appointment)});
  }

  @override
  Future<void> updateAppointments(
    List<AppointmentRecord> appointments, {
    List<AppointmentRecord> bases = const [],
    bool checkConflicts = false,
  }) async {
    if (_functions != null) {
      final original = {for (final record in bases) record.id: record};
      if (appointments.any((record) => !original.containsKey(record.id))) {
        throw StateError('Appointment edits require every original record');
      }
      await _commitEdits(
        edits: [
          for (final record in appointments)
            (base: original[record.id]!, updated: record),
        ],
        checkConflicts: checkConflicts,
      );
      return;
    }
    final records = [
      for (final a in appointments)
        if (a.id != null) a,
    ];
    if (records.isEmpty) return;
    if (checkConflicts) {
      await _refuseLocalClash(
        records,
        excludeIds: {for (final record in records) record.id!},
      );
    }
    final opId = _newSeriesOpId();
    final written = <String, Map<String, dynamic>?>{};
    await _appointments.firestore.runTransaction((txn) async {
      final refs = [for (final r in records) _appointments.doc(r.id)];
      final snaps = await Future.wait([for (final ref in refs) txn.get(ref)]);
      // Rebuilt per attempt: a transaction body can re-run.
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

  final Map<String, AppointmentRecord> _acknowledgedWrites = {};

  @override
  AppointmentRecord? takeAcknowledgedWrite(String id) =>
      _acknowledgedWrites.remove(id);

  static Map<String, dynamic> _editablePayload(AppointmentRecord record) => {
    ...record.toMap(),
    'startTime': record.startTime.millisecondsSinceEpoch,
    'endTime': record.endTime.millisecondsSinceEpoch,
  };

  Future<void> _commitEdits({
    List<({AppointmentRecord base, AppointmentRecord updated})> edits =
        const [],
    List<AppointmentRecord> creates = const [],
    List<AppointmentRecord> deletes = const [],
    bool checkConflicts = false,
  }) async {
    final isCurrent = captureWriteOwner();
    if (isCurrent != null && !isCurrent()) throw StateError('Session ended');
    final HttpsCallableResult<Map<String, dynamic>> result;
    try {
      result = await _functions!
          .httpsCallable('saveAppointmentEdits')
          .call<Map<String, dynamic>>({
            if (checkConflicts) 'checkConflicts': true,
            'edits': [
              for (final edit in edits)
                {
                  'id': edit.updated.id,
                  'base': _editablePayload(edit.base),
                  'data': _editablePayload(edit.updated),
                },
            ],
            'creates': [
              for (final record in creates)
                {'id': record.id, 'data': _editablePayload(record)},
            ],
            'deletes': [
              for (final record in deletes)
                {'id': record.id, 'base': _editablePayload(record)},
            ],
          });
    } on FirebaseFunctionsException catch (e) {
      final busy = _employeesBusyOf(e);
      if (busy == null) rethrow;
      throw busy;
    }
    if (isCurrent != null && !isCurrent()) return;
    if (result.data['appointments'] is! List) {
      throw const FormatException('Missing appointment edit acknowledgement');
    }
    final records = _appointmentsFromCallable(result.data);
    for (final record in records) {
      if (record.id != null) _acknowledgedWrites[record.id!] = record;
    }
    while (_acknowledgedWrites.length > 400) {
      _acknowledgedWrites.remove(_acknowledgedWrites.keys.first);
    }
    _patchWindow({
      for (final record in records)
        record.id!: AppointmentHistoryScan.rawOf(record),
      for (final record in deletes) record.id!: null,
    });
  }

  /// The server's `appointment-employee-busy` refusal as a typed failure.
  static CalendarFailureEmployeesBusy? _employeesBusyOf(
    FirebaseFunctionsException e,
  ) {
    if (e.code != 'failed-precondition' ||
        e.message != 'appointment-employee-busy') {
      return null;
    }
    final details = (e.details as Map?)?.cast<String, dynamic>();
    final start = details?['startMillis'];
    final end = details?['endMillis'];
    if (start is! int || end is! int) {
      throw const FormatException('Malformed busy-employee refusal');
    }
    return CalendarFailureEmployeesBusy(
      busyEmployeeIds: firestoreStringList(details?['busyEmployeeIds']),
      start: DateTime.fromMillisecondsSinceEpoch(start),
      end: DateTime.fromMillisecondsSinceEpoch(end),
    );
  }

  /// The local twin of the server's folded check, for the no-functions path.
  Future<void> _refuseLocalClash(
    List<AppointmentRecord> bookings, {
    Set<String> excludeIds = const {},
  }) async {
    for (final booking in bookings) {
      if (booking.isPersonal || booking.employeeIds.isEmpty) continue;
      final clashes = await _findClashingAppointmentsLocal(
        employeeIds: booking.employeeIds,
        start: booking.startTime,
        end: booking.endTime,
        excludeAppointmentId: null,
        clientJobsOnly: false,
      );
      final busy = {
        for (final clash in clashes)
          if (!excludeIds.contains(clash.id))
            ...clash.employeeIds.where(booking.employeeIds.contains),
      };
      if (busy.isNotEmpty) {
        throw CalendarFailureEmployeesBusy(
          busyEmployeeIds: busy.toList(),
          start: booking.startTime,
          end: booking.endTime,
        );
      }
    }
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
    // A note changes no field matchHistoryDocs reads.
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

  // Not delegated to the plural: see appointments.md, mark-complete.
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

  void _warnAtRangeCap(QuerySnapshot<Map<String, dynamic>> snapshot) {
    if (snapshot.docs.length >= _rangeStreamLimit) {
      _logger.warn(
        'APPT-LOAD range query hit the $_rangeStreamLimit-doc cap - '
        'appointments beyond it are not shown',
      );
    }
  }

  /// Parses only `docChanges` into [parsed].
  void _applyRangeChanges(
    Map<String, AppointmentRecord> parsed,
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    _warnAtRangeCap(snapshot);
    for (final change in snapshot.docChanges) {
      final doc = change.doc;
      if (change.type == DocumentChangeType.removed) {
        parsed.remove(doc.id);
      } else {
        parsed[doc.id] = AppointmentRecord.fromMap(doc.id, doc.data() ?? {});
      }
    }
  }

  /// [snapshots] tail first: every tail doc starts before every main doc.
  List<AppointmentRecord> _orderedRangeRecords(
    Map<String, AppointmentRecord> parsed,
    Iterable<QuerySnapshot<Map<String, dynamic>>> snapshots,
  ) {
    final seen = <String>{};
    return [
      for (final snapshot in snapshots)
        for (final doc in snapshot.docs)
          if (seen.add(doc.id))
            parsed[doc.id] ??= AppointmentRecord.fromMap(doc.id, doc.data()),
    ];
  }

  /// One parsed map per subscription fed by both queries; emits once both land.
  Stream<List<AppointmentRecord>> _watchRange(
    Query<Map<String, dynamic>> main,
    Query<Map<String, dynamic>> tail,
  ) {
    return retryStream(() {
      final parsed = <String, AppointmentRecord>{};
      final latest = <QuerySnapshot<Map<String, dynamic>>?>[null, null];
      final subscriptions = <StreamSubscription<void>>[];
      late final StreamController<List<AppointmentRecord>> controller;
      var open = 2;
      void listen(int slot, Query<Map<String, dynamic>> query) {
        subscriptions.add(
          query.snapshots().listen(
            (snapshot) {
              latest[slot] = snapshot;
              _applyRangeChanges(parsed, snapshot);
              // A first emission before both land would paint a partial window.
              if (latest.contains(null)) return;
              controller.add(_orderedRangeRecords(parsed, latest.nonNulls));
            },
            onError: controller.addError,
            onDone: () {
              if (--open == 0) unawaited(controller.close());
            },
          ),
        );
      }

      controller = StreamController(
        onListen: () {
          listen(0, tail);
          listen(1, main);
        },
        onCancel: () => Future.wait([
          for (final subscription in subscriptions) subscription.cancel(),
        ]),
      );
      return controller.stream;
    });
  }

  Query<Map<String, dynamic>> _scopedAppointments(String? employeeId) =>
      employeeId == null
      ? _appointments
      : _appointments.where('employeeIds', arrayContains: employeeId);

  Query<Map<String, dynamic>> _rangeQuery(
    AppointmentDateRange range, {
    String? employeeId,
  }) => _scopedAppointments(employeeId)
      .where(
        'startTime',
        isGreaterThanOrEqualTo: Timestamp.fromDate(range.start),
      )
      .where('startTime', isLessThan: Timestamp.fromDate(range.end))
      .orderBy('startTime')
      .limit(_rangeStreamLimit);

  /// The 14-day tail: since ADR-0050 only a personal block is one wide document.
  Query<Map<String, dynamic>> _rangeTailQuery(
    AppointmentDateRange range, {
    String? employeeId,
  }) => _scopedAppointments(employeeId)
      .where('isPersonal', isEqualTo: true)
      .where(
        'startTime',
        isGreaterThanOrEqualTo: Timestamp.fromDate(range.fetchStart),
      )
      .where('startTime', isLessThan: Timestamp.fromDate(range.start))
      .orderBy('startTime')
      .limit(_rangeStreamLimit);

  @override
  Stream<List<AppointmentRecord>> watchInRange(AppointmentDateRange range) =>
      _watchRange(_rangeQuery(range), _rangeTailQuery(range));

  @override
  Stream<List<AppointmentRecord>> watchOverdueOpen(DateTime now) {
    var hasWarned = false;
    return retryStream(
      () => _appointments
          .where('status', whereIn: openStatusQueryValues)
          // A doc with no `isPersonal` field is dropped here: backfilled, see appointments.md.
          .where('isPersonal', isEqualTo: false)
          // Bounded at next midnight, not [now]: the query stays identical
          // all day, so a quarter-hour re-issue resumes instead of re-billing
          // the whole backlog. `overdueJobsAt(now)` below makes the cut.
          .where(
            'endTime',
            isLessThan: Timestamp.fromDate(
              DateTime(now.year, now.month, now.day + 1),
            ),
          )
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
    final snapshots = await PerformanceTrace.measure(
      PerformanceOperation.calendarRange,
      () => retryAsync(
        () => Future.wait([
          _rangeTailQuery(range).get(),
          _rangeQuery(range).get(),
        ]),
      ),
    );
    snapshots.forEach(_warnAtRangeCap);
    return _orderedRangeRecords({}, snapshots);
  }

  /// The business-wide terminal archive.
  Query<Map<String, dynamic>> get _historyQuery =>
      _appointments.where('status', whereIn: terminalStatusQueryValues);

  @override
  Future<List<AppointmentRecord>> fetchHistoryPage({
    required int limit,
    AppointmentRecord? after,
    List<String>? statuses,
  }) async {
    final narrowed = statuses?.where(terminalStatusRawValues.contains).toList();
    // Same `(status ASC, startTime DESC)` composite as the unfiltered archive.
    final base = narrowed == null || narrowed.isEmpty
        ? _historyQuery
        : narrowed.length == 1
        ? _appointments.where('status', isEqualTo: narrowed.single)
        : _appointments.where('status', whereIn: narrowed);
    var query = base
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
    bool pastOnly = false,
  }) async {
    if (clientId.isEmpty) return const [];
    final scanCap = cap ?? _clientHistoryScanLimit;
    var query = _appointments.where('clientId', isEqualTo: clientId);
    if (pastOnly) {
      // Same `(clientId, startTime DESC)` composite as the orderBy below.
      query = query.where(
        'startTime',
        isLessThan: Timestamp.fromDate(_clock()),
      );
    }
    // Only the DEFAULT cap warns; an explicit cap is a deliberate window and breadcrumbs.
    final docs = await pageToCap(
      query.orderBy('startTime', descending: true),
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
    // A multi-day run is one job: list only its first day.
    return docs
        .map((doc) => _recordFrom(doc.id, doc.data()))
        .where((record) => record.dayIndex <= 1)
        .toList();
  }

  static const int _futureAssignmentScanLimit = 200;
  static const int _seriesScanLimit = RepeatInterval.maxOccurrences + 1;

  @override
  Future<List<AppointmentRecord>> searchHistory(String query) async {
    final q = query.trim();
    if (!ClientSearchPolicy.shouldSearch(q)) return const [];
    return await _historyScan.results.getOrLoad(
      ClientSearchPolicy.cacheKey(q),
      () => _searchHistory(q),
    );
  }

  Future<List<AppointmentRecord>> _searchHistory(String query) async {
    final functions = _functions;
    if (functions == null) {
      final docs = await _historyScan.window();
      return matchHistoryDocs(HistorySearchScan(docs: docs, query: query));
    }

    final response = await functions
        .httpsCallable('searchHistory')
        .call<Map<String, dynamic>>({'query': query});
    return _appointmentsFromCallable(response.data);
  }

  @override
  Stream<List<AppointmentRecord>> watchForEmployeeInRange(
    String employeeId,
    AppointmentDateRange range,
  ) => _watchRange(
    _rangeQuery(range, employeeId: employeeId),
    _rangeTailQuery(range, employeeId: employeeId),
  );

  @override
  Future<List<EmployeeRecord>> findBusyEmployees({
    required List<EmployeeRecord> candidates,
    required DateTime start,
    required DateTime end,
    String? excludeAppointmentId,
  }) async {
    if (candidates.isEmpty) return const [];

    // The busy people are the clashing records' assignees.
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
    base['historySearchScopes'] = appointmentHistoryScopes(base);
    return base;
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

  static const int _conflictScanLimit = 1000;

  Future<List<AppointmentRecord>> _findClashingAppointmentsLocal({
    required List<String> employeeIds,
    required DateTime start,
    required DateTime end,
    required String? excludeAppointmentId,
    required bool clientJobsOnly,
  }) async {
    final byId = <String, AppointmentRecord>{};
    final windowUnknownIds = <String>{};
    var scanned = 0;
    for (var i = 0; i < employeeIds.length; i += 30) {
      final docs = await pageToCap(
        _appointments
            .where(
              'employeeIds',
              arrayContainsAny: employeeIds.skip(i).take(30).toList(),
            )
            .where('startTime', isLessThan: Timestamp.fromDate(end))
            .where('endTime', isGreaterThan: Timestamp.fromDate(start)),
        pageSize: 500,
        cap: _conflictScanLimit - scanned,
        onCapReached: () {
          _logger.warn(
            'APPT-BUSY conflict scan incomplete; booking not cleared',
          );
          throw StateError('conflict-scan-incomplete');
        },
      );
      scanned += docs.length;
      for (final doc in docs) {
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
