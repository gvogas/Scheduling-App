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

  _MockDocSnap doc(String id, Map<String, dynamic> data) {
    final d = _MockDocSnap();
    when(() => d.id).thenReturn(id);
    when(d.data).thenReturn(data);
    return d;
  }

  setUpAll(() {
    registerFallbackValue(_MockDocSnap());
  });

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();

    when(() => firestore.collection('appointments')).thenReturn(collection);
    when(
      () => collection.where('clientId', isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(
      () => query.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    when(() => query.startAfterDocument(any())).thenReturn(query);

    final docs = [
      doc('older', {
        'clientId': 'c1',
        'title': 'Leak repair',
        'startTime': Timestamp.fromDate(DateTime(2026, 1, 10, 9)),
        'endTime': Timestamp.fromDate(DateTime(2026, 1, 10, 10)),
        'status': 'done',
      }),
      doc('newer', {
        'clientId': 'c1',
        'title': 'Water heater',
        'startTime': Timestamp.fromDate(DateTime(2026, 6, 1, 14)),
        'endTime': Timestamp.fromDate(DateTime(2026, 6, 1, 15)),
        'status': 'done',
      }),
    ];
    when(() => snapshot.docs).thenReturn(docs);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore);

  test('filters by clientId and uses the provided page size', () async {
    await repo().fetchClientHistory(clientId: 'c1', limit: 25);
    verify(() => collection.where('clientId', isEqualTo: 'c1')).called(1);
    verify(() => query.limit(25)).called(1);
  });

  test('orders newest-first on the server before paging', () async {
    await repo().fetchClientHistory(clientId: 'c1');
    verify(() => query.orderBy('startTime', descending: true)).called(1);
  });

  test('returns the server order as-is, without re-sorting in Dart', () async {
    final result = await repo().fetchClientHistory(clientId: 'c1');
    expect(result.map((a) => a.id), ['older', 'newer']);
  });

  test(
    'defaults to a page size of 500 when collecting the full history',
    () async {
      await repo().fetchClientHistory(clientId: 'c1');
      verify(() => query.limit(500)).called(1);
    },
  );

  test('walks additional pages until the history is complete', () async {
    final firstPage = [
      doc('a1', {
        'clientId': 'c1',
        'title': 'One',
        'startTime': Timestamp.fromDate(DateTime(2026, 7, 2)),
        'endTime': Timestamp.fromDate(DateTime(2026, 7, 2, 1)),
        'status': 'done',
      }),
      doc('a2', {
        'clientId': 'c1',
        'title': 'Two',
        'startTime': Timestamp.fromDate(DateTime(2026, 7)),
        'endTime': Timestamp.fromDate(DateTime(2026, 7, 1, 1)),
        'status': 'done',
      }),
    ];
    final secondPage = [
      doc('a3', {
        'clientId': 'c1',
        'title': 'Three',
        'startTime': Timestamp.fromDate(DateTime(2026, 6, 30)),
        'endTime': Timestamp.fromDate(DateTime(2026, 6, 30, 1)),
        'status': 'done',
      }),
    ];
    when(() => snapshot.docs).thenReturn(firstPage);
    when(() => query.get()).thenAnswer((_) async => snapshot);

    final secondSnapshot = _MockQuerySnapshot();
    when(() => secondSnapshot.docs).thenReturn(secondPage);
    when(() => query.startAfterDocument(firstPage.last)).thenReturn(query);
    var call = 0;
    when(() => query.get()).thenAnswer((_) async {
      call++;
      return call == 1 ? snapshot : secondSnapshot;
    });

    final result = await repo().fetchClientHistory(clientId: 'c1', limit: 2);

    expect(result.map((a) => a.id), ['a1', 'a2', 'a3']);
  });

  group('pastOnly', () {
    setUp(() {
      when(
        () => query.where('startTime', isLessThan: any(named: 'isLessThan')),
      ).thenReturn(query);
    });

    test('bounds startTime below the injected clock', () async {
      final now = DateTime(2026, 9, 28, 14, 30);
      await FirebaseAppointmentsRepository(
        firestore,
        clock: () => now,
      ).fetchClientHistory(clientId: 'c1', pastOnly: true);

      verify(
        () => query.where('startTime', isLessThan: Timestamp.fromDate(now)),
      ).called(1);
    });

    test('is off by default, so upcoming bookings still come back', () async {
      await repo().fetchClientHistory(clientId: 'c1');

      verifyNever(
        () => query.where('startTime', isLessThan: any(named: 'isLessThan')),
      );
    });
  });

  test('returns empty without querying for a blank clientId', () async {
    expect(await repo().fetchClientHistory(clientId: ''), isEmpty);
    verifyNever(() => query.get());
  });
}
