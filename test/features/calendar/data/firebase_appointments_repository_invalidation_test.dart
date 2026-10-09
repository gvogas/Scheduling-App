// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_image.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockDoc extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

class _MockBatch extends Mock implements WriteBatch {}

class _MockTransaction extends Mock implements Transaction {}

class _MockDocSnap extends Mock
    implements DocumentSnapshot<Map<String, dynamic>> {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

class _MockQueryDocSnap extends Mock
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

class _FakeDoc extends Fake
    implements DocumentReference<Map<String, dynamic>> {}

class _FakeSetOptions extends Fake implements SetOptions {}

// Declared as a top-level function (not a closure) so its runtime type exactly
// matches mocktail's `any()` for the repo's transaction handler.
Future<Null> _fallbackHandler(Transaction _) async => null;

AppointmentRecord _record({String? id = 'a1'}) => AppointmentRecord(
  id: id,
  title: 'Leak',
  startTime: DateTime(2026, 6, 24, 9),
  endTime: DateTime(2026, 6, 24, 10),
);

const _photo = AppointmentImage(
  storagePath: 'appointments/a1/images/1754835600000_p.jpg',
);

/// One public write method, how to call it, and what it should leave behind in
/// the history scan window.
typedef _WriteCase = ({
  String method,
  Future<void> Function(FirebaseAppointmentsRepository) run,
  bool keepsA1,
  String why,
});

/// Every public method of the repository that mutates Firestore.
final List<_WriteCase> _writeCases = [
  (
    method: 'addAppointment',
    run: (r) => r.addAppointment(_record()),
    keepsA1: false,
    why: 'a create is pending, so it does not belong in a terminal window',
  ),
  (
    method: 'addAppointments',
    run: (r) => r.addAppointments([_record()]),
    keepsA1: false,
    why: 'a create is pending, so it does not belong in a terminal window',
  ),
  (
    method: 'rewriteSeries',
    run: (r) => r.rewriteSeries(
      updated: _record(),
      deleteIds: const ['a2'],
      copies: [_record(id: 'a3')],
    ),
    keepsA1: false,
    why: 'the rewritten occurrence is pending again',
  ),
  (
    method: 'updateAppointment',
    run: (r) => r.updateAppointment(_record()),
    keepsA1: false,
    why: 'the edited record is pending, so history no longer holds it',
  ),
  (
    method: 'updateAppointments',
    run: (r) => r.updateAppointments([_record()]),
    keepsA1: false,
    why: 'the edited record is pending, so history no longer holds it',
  ),
  (
    method: 'appendAppointmentPictures',
    run: (r) => r.appendAppointmentPictures('a1', const [_photo]),
    keepsA1: true,
    why: 'a photo write touches no field matchHistoryDocs reads',
  ),
  (
    method: 'removeAppointmentPictures',
    run: (r) => r.removeAppointmentPictures('a1', const [_photo]),
    keepsA1: true,
    why: 'a photo write touches no field matchHistoryDocs reads',
  ),
  (
    method: 'appendFieldNote',
    run: (r) => r.appendFieldNote(
      appointmentId: 'a1',
      text: 'Valve replaced',
      authorId: 'e1',
      authorName: 'Marc Tremblay',
    ),
    keepsA1: true,
    why: 'a crew note touches no field matchHistoryDocs reads',
  ),
  (
    method: 'updateAppointmentStatus',
    run: (r) => r.updateAppointmentStatus(id: 'a1', status: 'done'),
    keepsA1: true,
    why: 'done is terminal, and only the status field is merged',
  ),
  (
    method: 'updateAppointmentStatuses',
    run: (r) =>
        r.updateAppointmentStatuses(ids: const ['a1'], status: 'cancelled'),
    keepsA1: true,
    why: 'cancelled is terminal too',
  ),
  (
    method: 'deleteAppointment',
    run: (r) => r.deleteAppointment('a1'),
    keepsA1: false,
    why: 'a deleted job must never surface in a search result',
  ),
  (
    method: 'deleteAppointments',
    run: (r) => r.deleteAppointments(const ['a1']),
    keepsA1: false,
    why: 'a deleted job must never surface in a search result',
  ),
  (
    // No `FirebaseFunctions` is injected here, so this takes the local
    // fallback; the callable path and its own patch live in
    // `firebase_appointments_repository_restore_test.dart`.
    method: 'restoreAppointmentStatus',
    run: (r) => r.restoreAppointmentStatus(id: 'a1', previousStatus: 'pending'),
    keepsA1: false,
    why: 'an undone mark-complete is open again, so history no longer holds it',
  ),
];

/// The writes that touch only a subcollection, so wake `onLocalWrite` alone.
const _noRecordEvent = {
  'appendAppointmentPictures',
  'removeAppointmentPictures',
  'appendFieldNote',
};

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDoc());
    registerFallbackValue(_FakeSetOptions());
    registerFallbackValue(<String, dynamic>{});
    // The fallback and the stub both need to match the transaction handler's
    // reified Null return type.
    registerFallbackValue(_fallbackHandler);
  });

  late _MockFirestore firestore;
  late _MockCollection appointments;
  late _MockDoc parentDoc;
  late _MockCollection images;
  late _MockCollection fieldNotes;
  late _MockBatch batch;
  late _MockTransaction txn;
  late _MockQuery query;
  late _MockQuerySnapshot snapshot;

  setUp(() {
    firestore = _MockFirestore();
    appointments = _MockCollection();
    parentDoc = _MockDoc();
    images = _MockCollection();
    fieldNotes = _MockCollection();
    batch = _MockBatch();
    txn = _MockTransaction();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();

    when(() => firestore.collection('appointments')).thenReturn(appointments);
    when(() => appointments.firestore).thenReturn(firestore);
    when(() => appointments.doc(any())).thenReturn(parentDoc);
    when(() => parentDoc.id).thenReturn('a1');
    when(() => parentDoc.collection('images')).thenReturn(images);
    when(() => images.doc(any())).thenReturn(_MockDoc());
    when(() => parentDoc.collection('fieldNotes')).thenReturn(fieldNotes);
    when(() => fieldNotes.add(any())).thenAnswer((_) async => _MockDoc());
    when(() => parentDoc.update(any())).thenAnswer((_) async {});

    when(firestore.batch).thenReturn(batch);
    when(() => batch.set<Map<String, dynamic>>(any(), any())).thenReturn(null);
    when(
      () => batch.set<Map<String, dynamic>>(any(), any(), any()),
    ).thenReturn(null);
    when(
      () => batch.update(
        any<DocumentReference<Map<String, dynamic>>>(),
        any<Map<String, dynamic>>(),
      ),
    ).thenReturn(null);
    when(() => batch.delete(any())).thenReturn(null);
    when(batch.commit).thenAnswer((_) async {});

    final txnSnap = _MockDocSnap();
    when(() => txnSnap.exists).thenReturn(true);
    when(
      () => txn.get<Map<String, dynamic>>(any()),
    ).thenAnswer((_) async => txnSnap);
    when(() => txn.update(any(), any())).thenReturn(txn);
    when(() => firestore.runTransaction<Null>(any())).thenAnswer((
      invocation,
    ) async {
      final handler =
          invocation.positionalArguments.first
              as Future<void> Function(Transaction);
      await handler(txn);
    });

    // The history-search scan window.
    when(
      () => appointments.where('status', whereIn: any(named: 'whereIn')),
    ).thenReturn(query);
    when(
      () => query.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);

    // Built before `docs` is stubbed — mocktail forbids calling `when` while
    // another stub is being defined.
    final hit = _MockQueryDocSnap();
    when(() => hit.id).thenReturn('a1');
    when(hit.data).thenReturn({
      'clientName': 'Sophie Tremblay',
      'status': 'done',
      'startTime': Timestamp.fromDate(DateTime(2026, 6, 24, 9)),
      'endTime': Timestamp.fromDate(DateTime(2026, 6, 24, 10)),
    });
    when(() => snapshot.docs).thenReturn([hit]);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore);

  group('a local write PATCHES the history scan window', () {
    // The repository is a long-lived singleton, so the window outlives every
    // autoDispose provider reading it.

    test(
      'control: without a write, the second search is served from cache',
      () async {
        // Without this, every case below would pass against a repository that
        // simply never caches.
        final r = repo();
        await r.searchHistory('sophie');
        await r.searchHistory('sophie');

        verify(() => query.get()).called(1);
      },
    );

    for (final c in _writeCases) {
      test('${c.method} costs NO second scan', () async {
        final r = repo();
        await r.searchHistory('sophie');
        await c.run(r);
        await r.searchHistory('sophie');

        verify(() => query.get()).called(1);
      });

      test('${c.method} wakes onLocalWrite', () async {
        // The behavioural half of the static guard below: an open detail sheet
        // and both history providers re-read off this stream, so a write that
        // pokes neither `_patchWindow` nor `_notifyLocalWrite` leaves every
        // one of them showing what the write just changed.
        final r = repo();
        var wakes = 0;
        final sub = r.onLocalWrite.listen((_) => wakes++);
        await c.run(r);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(wakes, greaterThan(0));
      });

      final isPoke = _noRecordEvent.contains(c.method);
      test(
        '${c.method} ${isPoke ? 'does NOT wake' : 'wakes'} onRecordWrite',
        () async {
          // The client Job history re-reads off this stream, and a photo or
          // crew-note append changes nothing it lists.
          final r = repo();
          var wakes = 0;
          final sub = r.onRecordWrite.listen((_) => wakes++);
          await c.run(r);
          await Future<void>.delayed(Duration.zero);
          await sub.cancel();

          expect(wakes, isPoke ? 0 : greaterThan(0));
        },
      );

      test('${c.method}: ${c.why}', () async {
        final r = repo();
        await r.searchHistory('sophie');
        await c.run(r);
        final after = await r.searchHistory('sophie');

        expect(
          after.map((a) => a.id),
          c.keepsA1 ? ['a1'] : isEmpty,
          reason: c.why,
        );
      });
    }

    test('an expired window is re-paged rather than patched forever', () async {
      // The TTL is the safety net under the patch: a REMOTE write (another
      // admin, a Cloud Function) changes nothing locally, so the window has to
      // age out on its own.
      var now = DateTime(2026, 9, 1, 12);
      final r = FirebaseAppointmentsRepository(firestore, clock: () => now);

      await r.searchHistory('sophie');
      await r.updateAppointmentStatus(id: 'a1', status: 'done');
      now = now.add(const Duration(seconds: 121));
      await r.searchHistory('sophie');

      verify(() => query.get()).called(2);
    });
  });

  group('the table above covers the repository', () {
    // Dart has no reflection here, so the guard is the source itself: the same
    // read-the-file posture `text_limits_test.dart` uses against
    // `firestore.rules`.

    /// Method name -> body, for the members of
    /// `FirebaseAppointmentsRepository`, with comments stripped so a token
    /// quoted in prose can't count as code.
    Map<String, String> repositoryMembers() {
      final source = File(
        'lib/features/calendar/data/firebase_appointments_repository.dart',
      ).readAsStringSync();
      final code = source
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .where((l) => !l.trimLeft().startsWith('///'))
          .toList();
      // A member declaration sits at exactly two spaces of indent and names its
      // return type; a statement inside a body is indented further.
      final decl = RegExp(r'^  (?:static\s+)?[A-Za-z_][\w<>?,\[\] ]*\s(\w+)\(');

      final members = <String, StringBuffer>{};
      StringBuffer? current;
      for (final line in code) {
        final match = decl.firstMatch(line);
        if (match != null) {
          current = members[match.group(1)!] = StringBuffer();
        }
        current?.writeln(line);
      }
      return {for (final e in members.entries) e.key: e.value.toString()};
    }

    /// Anything that changes a document: every public write returns
    /// `Future<void>`.
    ///
    /// Scanning the body for `.set(`/`.update(`/`.delete(`/`batch.commit`/
    /// `runTransaction` missed four — the three that delegate to a store and
    /// `restoreAppointmentStatus`, which writes through a callable — so the
    /// guard was blind to exactly the shapes it was there to catch next. A read
    /// returns its data and `dispose`/`clearCaches` are bare `void`, so the
    /// return type names the write set and no new delegation can evade it.
    bool mutates(String body) => body.trimLeft().startsWith('Future<void> ');

    late final members = repositoryMembers();
    late final mutating = members.entries
        .where((e) => !e.key.startsWith('_') && mutates(e.value))
        .map((e) => e.key);

    test('parsed the source at all', () {
      // A regex that silently matched nothing would make both tests below
      // vacuous, which is the failure mode this whole group exists to prevent.
      expect(members.keys, containsAll(['searchHistory', 'findBusyEmployees']));
      expect(mutating, isNotEmpty);
    });

    test('every mutating public method is in the table', () {
      expect(
        mutating,
        everyElement(isIn(_writeCases.map((c) => c.method))),
        reason:
            'a new write method must be added to _writeCases, or nothing '
            'checks what it leaves in the history scan window',
      );
    });

    test('every mutating public method patches or pokes', () {
      // The static half of the same rule: it fails on the method that forgot
      // the call, rather than only on the ones somebody remembered to add to
      // the table.
      for (final name in mutating) {
        final body = members[name]!;
        // A one-line singular that hands off to its plural is covered by the
        // call it makes, so the delegation counts as telling the window.
        final delegates = mutating.any(
          (other) => other != name && body.contains('$other('),
        );
        expect(
          delegates ||
              body.contains('_patchWindow(') ||
              body.contains('_notifyLocalWrite()'),
          isTrue,
          reason:
              '$name mutates Firestore without telling the history scan '
              'window, so search can serve a row that no longer exists',
        );
      }
    });
  });
}
