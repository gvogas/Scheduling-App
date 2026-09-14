// Mocktail fakes must subclass cloud_firestore's sealed types.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
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

class _FakeDoc extends Fake
    implements DocumentReference<Map<String, dynamic>> {}

AppointmentRecord _record({String? id = 'a1', String status = 'confirmed'}) =>
    AppointmentRecord(
      id: id,
      title: 'Leak',
      startTime: DateTime(2026, 6, 24, 9),
      endTime: DateTime(2026, 6, 24, 10),
      status: status,
    );

// Declared as a top-level function (not a closure) so its runtime type exactly
// matches mocktail's `any()` for the repo's transaction handler.
Future<Null> _fallbackHandler(Transaction _) async => null;

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDoc());
    registerFallbackValue(<String, dynamic>{});
    // The fallback and the stub both need to match the transaction handler's
    // reified Null return type.
    registerFallbackValue(_fallbackHandler);
  });

  late _MockFirestore firestore;
  late _MockCollection collection;

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    when(() => firestore.collection('appointments')).thenReturn(collection);
    when(() => collection.firestore).thenReturn(firestore);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore);

  group('_toFirestoreMap (via updateAppointment)', () {
    test('writes status, Timestamp times, and a server updatedAt', () async {
      final doc = _MockDoc();
      when(() => collection.doc('a1')).thenReturn(doc);
      when(() => doc.update(any())).thenAnswer((_) async {});

      await repo().updateAppointment(_record(status: 'in_progress'));

      final payload =
          (verify(() => doc.update(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(payload['status'], 'in_progress');
      expect(payload['startTime'], isA<Timestamp>());
      expect(payload['endTime'], isA<Timestamp>());
      expect(payload['updatedAt'], isA<FieldValue>());
      // update must NOT stamp createdAt (only inserts do), or a re-save would
      // reset the original creation time.
      expect(payload.containsKey('createdAt'), isFalse);
      // Nor `pictureCount`: the recount trigger owns it after creation, and the
      // rules reject an update that moves it — so emitting the record's
      // possibly-stale copy here turns every edit of a job with photos into an
      // opaque permission-denied.
      expect(payload.containsKey('pictureCount'), isFalse);
      // Nor the retired `pictures` array.
      expect(payload.containsKey('pictures'), isFalse);
    });

    test('is a no-op when the record has no id', () async {
      final doc = _MockDoc();
      when(() => collection.doc(any())).thenReturn(doc);
      when(() => doc.update(any())).thenAnswer((_) async {});

      await repo().updateAppointment(_record(id: null));

      verifyNever(() => doc.update(any()));
    });
  });

  group('addAppointment', () {
    test('stamps both createdAt and updatedAt server timestamps', () async {
      final doc = _MockDoc();
      final batch = _MockBatch();
      // `addAppointments` reads the ref's id to patch the history scan window.
      when(() => doc.id).thenReturn('a1');
      when(() => collection.doc('a1')).thenReturn(doc);
      when(() => firestore.batch()).thenReturn(batch);
      when(
        () => batch.set<Map<String, dynamic>>(any(), any()),
      ).thenReturn(null);
      when(batch.commit).thenAnswer((_) async {});

      await repo().addAppointment(_record());

      final payload =
          (verify(
                    () => batch.set<Map<String, dynamic>>(any(), captureAny()),
                  ).captured.single
                  as Map)
              .cast<String, dynamic>();
      expect(payload['status'], 'confirmed');
      expect(payload['createdAt'], isA<FieldValue>());
      expect(payload['updatedAt'], isA<FieldValue>());
    });

    test('seeds pictureCount at zero — the one client write of it', () async {
      // A create is the only write the rules let touch this counter, and it has
      // to: the recount trigger fires on a photo write, so without the seed
      // every photo-less job would read as count-unknown forever.
      final doc = _MockDoc();
      final batch = _MockBatch();
      // `addAppointments` reads the ref's id to patch the history scan window.
      when(() => doc.id).thenReturn('a1');
      when(() => collection.doc('a1')).thenReturn(doc);
      when(() => firestore.batch()).thenReturn(batch);
      when(
        () => batch.set<Map<String, dynamic>>(any(), any()),
      ).thenReturn(null);
      when(batch.commit).thenAnswer((_) async {});

      await repo().addAppointment(_record());

      final payload =
          (verify(
                    () => batch.set<Map<String, dynamic>>(any(), captureAny()),
                  ).captured.single
                  as Map)
              .cast<String, dynamic>();
      expect(payload['pictureCount'], 0);
    });
  });

  group('updateAppointments (transaction)', () {
    test(
      'skips a concurrently-deleted sibling and updates the survivor',
      () async {
        final refA = _MockDoc();
        final refB = _MockDoc();
        final snapA = _MockDocSnap();
        final snapB = _MockDocSnap();
        final txn = _MockTransaction();

        when(() => collection.doc('a1')).thenReturn(refA);
        when(() => collection.doc('a2')).thenReturn(refB);
        when(() => snapA.exists).thenReturn(true); // survivor
        when(() => snapB.exists).thenReturn(false); // deleted mid-save
        when(() => txn.get(refA)).thenAnswer((_) async => snapA);
        when(() => txn.get(refB)).thenAnswer((_) async => snapB);
        when(() => txn.update(any(), any())).thenReturn(txn);
        when(() => firestore.runTransaction<Null>(any())).thenAnswer((
          invocation,
        ) async {
          final handler =
              invocation.positionalArguments.first
                  as Future<void> Function(Transaction);
          await handler(txn);
        });

        await repo().updateAppointments([_record(), _record(id: 'a2')]);

        verify(() => txn.update(refA, any())).called(1);
        verifyNever(() => txn.update(refB, any()));
      },
    );

    test('is a no-op (no transaction) when no record has an id', () async {
      await repo().updateAppointments([_record(id: null)]);
      verifyNever(() => firestore.runTransaction<Null>(any()));
    });
  });

  group('seriesOpId', () {
    /// Captures the `seriesOpId` written onto every document of one batch.
    Future<List<String>> opIdsFromRewrite() async {
      final batch = _MockBatch();
      when(() => collection.doc(any())).thenReturn(_MockDoc());
      when(() => firestore.batch()).thenReturn(batch);
      when(
        () => batch.update(
          any<DocumentReference<Map<String, dynamic>>>(),
          any<Map<String, dynamic>>(),
        ),
      ).thenReturn(null);
      when(() => batch.delete(any())).thenReturn(null);
      when(
        () => batch.set<Map<String, dynamic>>(any(), any()),
      ).thenReturn(null);
      when(batch.commit).thenAnswer((_) async {});

      await repo().rewriteSeries(
        updated: _record(),
        deleteIds: const ['a9'],
        copies: [
          _record(id: 'a2'),
          _record(id: 'a3'),
        ],
      );

      final written = <String>[
        for (final m in verify(
          () => batch.update(
            any<DocumentReference<Map<String, dynamic>>>(),
            captureAny<Map<String, dynamic>>(),
          ),
        ).captured)
          ((m as Map).cast<String, dynamic>()['seriesOpId'] as String),
        for (final m in verify(
          () => batch.set<Map<String, dynamic>>(any(), captureAny()),
        ).captured)
          ((m as Map).cast<String, dynamic>()['seriesOpId'] as String),
      ];
      return written;
    }

    test('is the SAME on every document of one batch', () async {
      // The producer half of the notification-collapse contract.
      final ids = await opIdsFromRewrite();

      expect(ids, hasLength(3));
      expect(ids.toSet(), hasLength(1));
      expect(ids.first, isNotEmpty);
    });

    test('is DIFFERENT across two separate calls', () async {
      // The other half, and the one that broke: reusing an id across two
      // independent edits made the server treat the second as a replay of the
      // first and drop its push entirely.
      final first = await opIdsFromRewrite();
      final second = await opIdsFromRewrite();

      expect(first.first, isNot(second.first));
    });

    test('a plain update stamps one too', () async {
      final doc = _MockDoc();
      when(() => collection.doc('a1')).thenReturn(doc);
      when(() => doc.update(any())).thenAnswer((_) async {});

      await repo().updateAppointment(_record());
      await repo().updateAppointment(_record());

      final ids = verify(() => doc.update(captureAny())).captured
          .map((m) => (m as Map).cast<String, dynamic>()['seriesOpId'])
          .toList();
      expect(ids, hasLength(2));
      expect(ids.first, isNot(ids.last));
    });

    test('a bulk status write stamps one shared op id, done included', () async {
      // The server reads a fresh op id as an admin write and skips the completion push.
      final batch = _MockBatch();
      when(() => collection.doc(any())).thenReturn(_MockDoc());
      when(() => firestore.batch()).thenReturn(batch);
      when(
        () => batch.update(
          any<DocumentReference<Map<String, dynamic>>>(),
          any<Map<String, dynamic>>(),
        ),
      ).thenReturn(null);
      when(batch.commit).thenAnswer((_) async {});

      await repo().updateAppointmentStatuses(
        ids: const ['a1', 'a2'],
        status: 'done',
      );

      final ids = verify(
        () => batch.update(
          any<DocumentReference<Map<String, dynamic>>>(),
          captureAny<Map<String, dynamic>>(),
        ),
      ).captured.map((m) => (m as Map).cast<String, dynamic>()['seriesOpId']);
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(1));
      expect(ids.first, isNotNull);
    });
  });
}
