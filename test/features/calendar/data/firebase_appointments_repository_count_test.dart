// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

class _MockDocSnap extends Mock
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

void main() {
  late _MockFirestore firestore;
  late _MockCollection collection;
  late _MockQuery query;
  late _MockQuerySnapshot snapshot;

  final now = DateTime.now();

  _MockDocSnap job({
    required String id,
    required DateTime start,
    required DateTime end,
    String status = 'pending',
  }) {
    final d = _MockDocSnap();
    when(() => d.id).thenReturn(id);
    when(d.data).thenReturn({
      'startTime': Timestamp.fromDate(start),
      'endTime': Timestamp.fromDate(end),
      'status': status,
      'employeeIds': const ['e1'],
    });
    return d;
  }

  void withDocs(List<_MockDocSnap> docs) =>
      when(() => snapshot.docs).thenReturn(docs);

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();

    when(() => firestore.collection('appointments')).thenReturn(collection);
    when(
      () => collection.where(
        'employeeIds',
        arrayContains: any(named: 'arrayContains'),
      ),
    ).thenReturn(query);
    when(
      () => query.where(
        'endTime',
        isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
      ),
    ).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    withDocs([]);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore, clock: () => now);

  test('counts a run already under way, not just one starting later', () async {
    // Day 3 of a 10-day job: a `startTime >= now` query reported 0 and the
    // admin disabled someone standing on a job site.
    withDocs([
      job(
        id: 'a',
        start: now.subtract(const Duration(days: 3)),
        end: now.add(const Duration(days: 7)),
      ),
    ]);

    expect(await repo().countFutureAssignments('e1'), 1);
  });

  group('"has work left" is a QUERY bound, not a Dart filter', () {
    // The query used to be `startTime >= now - maxAppointmentSpanDays` with no
    // upper bound — every job this person was ever assigned to from a
    // fortnight ago to the end of time — and then dropped the ended ones in
    // Dart. Bounding `endTime` instead is what makes the read proportional to
    // the answer, so the constraint itself is the thing worth pinning.

    test('constrains endTime forward of now', () async {
      await repo().countFutureAssignments('e1');

      final captured = verify(
        () => query.where(
          'endTime',
          isGreaterThanOrEqualTo: captureAny(named: 'isGreaterThanOrEqualTo'),
        ),
      ).captured.single;

      expect(captured, isA<Timestamp>());
      final floor = (captured as Timestamp).toDate();
      expect(floor, now);
    });

    test(
      'adds no startTime floor, so the read is proportional to the answer',
      () async {
        await repo().countFutureAssignments('e1');

        verifyNever(
          () => query.where(
            'startTime',
            isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
          ),
        );
        verifyNever(
          () => collection.where(
            'startTime',
            isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
          ),
        );
      },
    );

    test('caps the read, so the repeat horizon cannot set its size', () async {
      // `endTime >= now` has no upper bound, and a repeat series pre-books up
      // to 120 occurrences five years out — so without a cap the size of this
      // read is set by how far ahead the business books, not by how much the
      // caption needs. This was the last unbounded query in the repository.
      await repo().countFutureAssignments('e1');

      final cap = verify(() => query.limit(captureAny())).captured.single;
      expect(cap, isA<int>());
      expect(cap, lessThanOrEqualTo(500));
    });
  });

  group('status is still tested in Dart', () {
    // Deliberately not a `whereIn` constraint: an `in` over the open statuses
    // would drop anything the allowlist does not name, and this caption must
    // err towards telling the admin to reassign.

    test('excludes a job completed earlier today', () async {
      // Its window has not closed, so the query admits it — only the status
      // test keeps it from reading as "still assigned, reassign it".
      withDocs([
        job(
          id: 'a',
          start: now.subtract(const Duration(hours: 4)),
          end: now.add(const Duration(hours: 4)),
          status: 'done',
        ),
      ]);

      expect(await repo().countFutureAssignments('e1'), 0);
    });

    test('excludes a cancelled job whose window is still open', () async {
      withDocs([
        job(
          id: 'a',
          start: now.subtract(const Duration(hours: 4)),
          end: now.add(const Duration(hours: 4)),
          status: 'cancelled',
        ),
      ]);

      expect(await repo().countFutureAssignments('e1'), 0);
    });

    test('counts an unknown status as open work', () async {
      withDocs([
        job(
          id: 'a',
          start: now.add(const Duration(days: 1)),
          end: now.add(const Duration(days: 1, hours: 8)),
          status: 'legacy_confirmed',
        ),
      ]);

      expect(await repo().countFutureAssignments('e1'), 1);
    });
  });
}
