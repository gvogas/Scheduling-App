// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

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

/// A plain fake, not a `Mock`: it is only ever the `startAfterDocument`
/// fallback value, which mocktail requires for a custom argument type.
class _FakeDocSnap extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeDocSnap()));

  late _MockFirestore firestore;
  late _MockCollection collection;
  late _MockQuery query;
  late _MockQuerySnapshot snapshot;

  _MockDocSnap doc(String id, Map<String, dynamic> data) {
    final d = _MockDocSnap();
    when(() => d.id).thenReturn(id);
    when(d.data).thenReturn(data);
    return d;
  }

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();

    when(() => firestore.collection('appointments')).thenReturn(collection);
    when(
      () => collection.where('status', whereIn: any(named: 'whereIn')),
    ).thenReturn(query);
    when(
      () => query.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    when(() => query.startAfterDocument(any())).thenReturn(query);

    // Build the doc mocks before stubbing `docs` — mocktail forbids calling
    // `when` (inside the doc() helper) while another stub is being defined.
    final docs = [
      doc('a1', {
        'clientName': 'Sophie Tremblay',
        'clientPhone': '438-555-0199',
        'employeeNames': ['Marc Lefebvre'],
        'status': 'done',
      }),
      doc('a2', {
        'clientName': 'John Smith',
        'clientPhone': '514-555-0100',
        'employeeNames': ['Zoé Bélanger'],
        'status': 'cancelled',
      }),
    ];
    when(() => snapshot.docs).thenReturn(docs);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore);

  test('different concurrent queries share their history scan', () async {
    final r = repo();
    final response = Completer<QuerySnapshot<Map<String, dynamic>>>();
    when(() => query.get()).thenAnswer((_) => response.future);
    final sophie = r.searchHistory('sophie');
    final john = r.searchHistory('john');
    response.complete(snapshot);
    expect((await sophie).map((a) => a.id), ['a1']);
    expect((await john).map((a) => a.id), ['a2']);
    verify(() => query.get()).called(1);
  });

  test('a scan completing after clear cannot repopulate history', () async {
    final r = repo();
    final response = Completer<QuerySnapshot<Map<String, dynamic>>>();
    when(() => query.get()).thenAnswer((_) => response.future);
    final old = r.searchHistory('sophie');
    r.clearCaches();
    response.complete(snapshot);
    await old;
    when(() => snapshot.docs).thenReturn([]);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    expect(await r.searchHistory('sophie'), isEmpty);
  });

  test('an unsuccessful scan is released for the next request', () async {
    final r = repo();
    when(() => query.get()).thenThrow(StateError('offline'));
    await expectLater(r.searchHistory('sophie'), throwsStateError);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    expect((await r.searchHistory('sophie')).map((a) => a.id), ['a1']);
  });

  test('returns empty without querying for a blank query', () async {
    expect(await repo().searchHistory('   '), isEmpty);
    verifyNever(() => query.get());
  });

  test('matches by client name', () async {
    final results = await repo().searchHistory('sophie');
    expect(results.map((a) => a.id), ['a1']);
  });

  test('matches by employee name (accent-insensitive)', () async {
    final results = await repo().searchHistory('zoe');
    expect(results.map((a) => a.id), ['a2']);
  });

  test('matches by phone digits when the query is formatted', () async {
    final results = await repo().searchHistory('(438) 555');
    expect(results.map((a) => a.id), ['a1']);
  });

  test('keeps newest-first order from the query (no resort)', () async {
    // Both rows match "555" on phone — order must match the docs order.
    final results = await repo().searchHistory('555');
    expect(results.map((a) => a.id), ['a1', 'a2']);
  });

  test('an unrelated query matches nothing', () async {
    final results = await repo().searchHistory('Xavier');
    expect(results, isEmpty);
  });

  // The `_clock` parameter exists so these are testable — its own comment says
  // so — and `clock:` appeared in ZERO calendar test files.
  group('the search-result cache', () {
    late DateTime now;
    FirebaseAppointmentsRepository clocked() =>
        FirebaseAppointmentsRepository(firestore, clock: () => now);

    setUp(() => now = DateTime(2026, 9, 1, 12));

    test(
      'a repeat query inside the TTL serves the cache, not Firestore',
      () async {
        final r = clocked();
        await r.searchHistory('sophie');
        now = now.add(const Duration(seconds: 119));
        final again = await r.searchHistory('sophie');

        expect(again.map((a) => a.id), ['a1']);
        // One scan for the two calls.
        verify(() => query.get()).called(1);
      },
    );

    test('a repeat query PAST the TTL re-reads', () async {
      final r = clocked();
      await r.searchHistory('sophie');
      now = now.add(const Duration(seconds: 121));
      await r.searchHistory('sophie');

      verify(() => query.get()).called(2);
    });

    test('a DIFFERENT query inside the TTL reuses the scan window', () async {
      // The per-query cache and the scan window are two separate dials on the
      // same clock.
      final r = clocked();
      await r.searchHistory('sophie');
      now = now.add(const Duration(seconds: 60));
      await r.searchHistory('john');

      verify(() => query.get()).called(1);
    });

    test(
      'an expired window is re-paged for a query that was never cached',
      () async {
        final r = clocked();
        await r.searchHistory('sophie');
        now = now.add(const Duration(seconds: 121));
        await r.searchHistory('john');

        verify(() => query.get()).called(2);
      },
    );
  });
}
