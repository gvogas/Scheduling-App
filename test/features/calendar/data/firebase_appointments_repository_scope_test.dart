// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
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

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

class _MockDocSnap extends Mock
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

class _FakeDocSnap extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

/// History is one business-wide terminal archive: no query is narrowed by
/// `employeeIds`, and the index carries only the `all:` scope.
void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDocSnap());
    registerFallbackValue(<String, dynamic>{});
  });

  late _MockFirestore firestore;
  late _MockCollection collection;
  late _MockDoc doc;
  late _MockQuery archiveQuery;
  late _MockQuerySnapshot archiveSnapshot;

  _MockDocSnap hit(String id, Map<String, dynamic> data) {
    final d = _MockDocSnap();
    when(() => d.id).thenReturn(id);
    when(d.data).thenReturn(data);
    return d;
  }

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    doc = _MockDoc();
    archiveQuery = _MockQuery();
    archiveSnapshot = _MockQuerySnapshot();

    when(() => firestore.collection('appointments')).thenReturn(collection);
    when(() => collection.doc(any())).thenReturn(doc);
    when(() => doc.update(any())).thenAnswer((_) async {});

    when(
      () => collection.where('status', whereIn: any(named: 'whereIn')),
    ).thenReturn(archiveQuery);
    when(
      () => archiveQuery.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(archiveQuery);
    when(() => archiveQuery.limit(any())).thenReturn(archiveQuery);
    when(() => archiveQuery.startAfterDocument(any())).thenReturn(archiveQuery);
    when(() => archiveQuery.get()).thenAnswer((_) async => archiveSnapshot);

    final docs = [
      hit('a1', {
        'clientName': 'Sophie Tremblay',
        'employeeIds': ['e1'],
        'employeeNames': ['Marc'],
        'status': 'done',
        'startTime': Timestamp.fromDate(DateTime(2026, 6, 24, 9)),
        'endTime': Timestamp.fromDate(DateTime(2026, 6, 24, 10)),
      }),
      hit('a2', {
        'clientName': 'Sophie Tremblay',
        'employeeIds': ['e2'],
        'employeeNames': ['Zoé'],
        'status': 'done',
        'startTime': Timestamp.fromDate(DateTime(2026, 6, 23, 9)),
        'endTime': Timestamp.fromDate(DateTime(2026, 6, 23, 10)),
      }),
    ];
    when(() => archiveSnapshot.docs).thenReturn(docs);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore);

  AppointmentRecord reassigned() => AppointmentRecord(
    id: 'a1',
    title: 'Leak',
    clientName: 'Sophie Tremblay',
    startTime: DateTime(2026, 6, 24, 9),
    endTime: DateTime(2026, 6, 24, 10),
    employeeIds: const ['e2'],
    employeeNames: const ['Zoé'],
    status: 'done',
  );

  test('the paged history query is never narrowed by assignee', () async {
    await repo().fetchHistoryPage(limit: 25);

    verifyNever(
      () => collection.where(
        'employeeIds',
        arrayContains: any(named: 'arrayContains'),
      ),
    );
  });

  test('a reassigned job stays in the patched search window', () async {
    final r = repo();
    await r.searchHistory('sophie');

    await r.updateAppointment(reassigned());
    final after = await r.searchHistory('sophie');

    expect(after.map((a) => a.id), ['a1', 'a2']);
    // Patched, not re-paged.
    verify(() => archiveQuery.get()).called(1);
  });

  test('clearCaches forgets the window', () async {
    final r = repo();
    await r.searchHistory('sophie');

    r.clearCaches();
    await r.searchHistory('sophie');

    verify(() => archiveQuery.get()).called(2);
  });

  test('a write indexes only the all: scope', () async {
    await repo().updateAppointment(reassigned());

    final written =
        (verify(() => doc.update(captureAny())).captured.single as Map)
            .cast<String, dynamic>();
    final scopes = written['historySearchScopes'] as List;
    expect(scopes, contains('all:t:sophie'));
    expect(scopes.every((t) => (t as String).startsWith('all:')), isTrue);
  });
}
