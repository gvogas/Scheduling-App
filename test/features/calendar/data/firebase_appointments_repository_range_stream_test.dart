// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _RecordingLogger extends AppLogger {
  final warnings = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    warnings.add(message);
  }
}

/// Counts `data()` reads: one per PARSE, which is what the stream must save.
class _FakeDoc extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeDoc(this.id, this._data);

  @override
  final String id;

  final Map<String, dynamic> _data;
  int reads = 0;

  @override
  Map<String, dynamic> data() {
    reads++;
    return _data;
  }
}

class _FakeChange extends Fake implements DocumentChange<Map<String, dynamic>> {
  _FakeChange(this.type, this.doc);

  @override
  final DocumentChangeType type;

  @override
  final _FakeDoc doc;
}

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

void main() {
  late _MockFirestore firestore;
  late _MockCollection collection;
  late _MockQuery query;
  late _RecordingLogger logger;
  late StreamController<QuerySnapshot<Map<String, dynamic>>> emissions;

  final day = DateTime(2026, 8, 15);
  final range = AppointmentDateRange(start: day, end: DateTime(2026, 8, 16));

  _FakeDoc doc(String id, {required int hour, String title = 'Job'}) =>
      _FakeDoc(id, {
        'title': title,
        'startTime': Timestamp.fromDate(DateTime(2026, 8, 15, hour)),
        'endTime': Timestamp.fromDate(DateTime(2026, 8, 15, hour + 1)),
        'status': 'pending',
        'employeeIds': const ['e1'],
      });

  /// One emission: [docs] in query order, with [changes] as its delta.
  void emit(List<_FakeDoc> docs, List<_FakeChange> changes) {
    final snapshot = _MockQuerySnapshot();
    when(() => snapshot.docs).thenReturn(docs);
    when(() => snapshot.docChanges).thenReturn(changes);
    emissions.add(snapshot);
  }

  _FakeChange added(_FakeDoc d) => _FakeChange(DocumentChangeType.added, d);
  _FakeChange modified(_FakeDoc d) =>
      _FakeChange(DocumentChangeType.modified, d);
  _FakeChange removed(_FakeDoc d) => _FakeChange(DocumentChangeType.removed, d);

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    query = _MockQuery();
    logger = _RecordingLogger();
    emissions = StreamController<QuerySnapshot<Map<String, dynamic>>>();

    when(() => firestore.collection('appointments')).thenReturn(collection);
    when(
      () => collection.where(
        'employeeIds',
        arrayContains: any(named: 'arrayContains'),
      ),
    ).thenReturn(query);
    when(
      () => collection.where(
        'startTime',
        isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
      ),
    ).thenReturn(query);
    when(
      () => query.where(
        'startTime',
        isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
      ),
    ).thenReturn(query);
    when(
      () => query.where('startTime', isLessThan: any(named: 'isLessThan')),
    ).thenReturn(query);
    when(() => query.orderBy(any())).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(query.snapshots).thenAnswer((_) => emissions.stream);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore, logger: logger);

  /// Subscribes, runs [drive], ends the source and returns every list emitted.
  Future<List<List<AppointmentRecord>>> collect(
    Stream<List<AppointmentRecord>> stream,
    void Function() drive,
  ) async {
    final done = stream.toList();
    drive();
    // Ending the source ends `retryStream`'s `await for`; a bare cancel would
    // hang until the generator reaches its next `yield`.
    await emissions.close();
    return await done;
  }

  group('watchInRange applies docChanges', () {
    test('the first snapshot parses every added doc, in query order', () async {
      final a = doc('a', hour: 8);
      final b = doc('b', hour: 9);

      final lists = await collect(repo().watchInRange(range), () {
        emit([a, b], [added(a), added(b)]);
      });

      expect(lists.single.map((r) => r.id), ['a', 'b']);
      expect(a.reads, 1);
      expect(b.reads, 1);
    });

    test(
      'a modified doc replaces its record; untouched docs are not re-parsed',
      () async {
        final a = doc('a', hour: 8);
        final b = doc('b', hour: 9);
        final b2 = doc('b', hour: 9, title: 'Renamed');

        final lists = await collect(repo().watchInRange(range), () {
          emit([a, b], [added(a), added(b)]);
          emit([a, b2], [modified(b2)]);
        });

        expect(lists, hasLength(2));
        expect(lists.last.map((r) => r.title), ['Job', 'Renamed']);
        // `a` was parsed once, on the first snapshot, and never again.
        expect(a.reads, 1);
        expect(b.reads, 1);
        expect(b2.reads, 1);
      },
    );

    test('a removed doc disappears from the next list', () async {
      final a = doc('a', hour: 8);
      final b = doc('b', hour: 9);

      final lists = await collect(repo().watchInRange(range), () {
        emit([a, b], [added(a), added(b)]);
        emit([b], [removed(a)]);
      });

      expect(lists.last.map((r) => r.id), ['b']);
    });

    test('the list follows the query order, not insertion order', () async {
      final a = doc('a', hour: 8);
      final b = doc('b', hour: 9);
      final c = doc('c', hour: 7);

      final lists = await collect(repo().watchInRange(range), () {
        emit([a, b], [added(a), added(b)]);
        // A new earlier job sorts first under `orderBy('startTime')`.
        emit([c, a, b], [added(c)]);
      });

      expect(lists.last.map((r) => r.id), ['c', 'a', 'b']);
    });

    test('a doc the delta missed is still parsed, never dropped', () async {
      final a = doc('a', hour: 8);
      final b = doc('b', hour: 9);

      final lists = await collect(repo().watchInRange(range), () {
        emit([a], [added(a)]);
        emit([a, b], const []);
      });

      expect(lists.last.map((r) => r.id), ['a', 'b']);
    });

    test('a snapshot at the cap still warns', () async {
      final docs = [for (var i = 0; i < 3000; i++) doc('a$i', hour: 9)];

      await collect(repo().watchInRange(range), () {
        emit(docs, [for (final d in docs) added(d)]);
      });

      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('APPT-LOAD'));
      expect(logger.warnings.single, contains('3000'));
    });

    test('each subscription keeps its own parsed map', () async {
      final a = doc('a', hour: 8);
      final r = repo();
      final first = await collect(r.watchInRange(range), () {
        emit([a], [added(a)]);
      });
      emissions = StreamController<QuerySnapshot<Map<String, dynamic>>>();
      when(query.snapshots).thenAnswer((_) => emissions.stream);

      final second = await collect(r.watchInRange(range), () {
        emit([a], [added(a)]);
      });

      expect(first.single.map((x) => x.id), ['a']);
      expect(second.single.map((x) => x.id), ['a']);
      // Both subscriptions parsed it: nothing leaks across listeners.
      expect(a.reads, 2);
    });
  });

  test('watchForEmployeeInRange applies docChanges the same way', () async {
    final a = doc('a', hour: 8);
    final a2 = doc('a', hour: 8, title: 'Renamed');

    final lists = await collect(
      repo().watchForEmployeeInRange('e1', range),
      () {
        emit([a], [added(a)]);
        emit([a2], [modified(a2)]);
      },
    );

    expect(lists.last.single.title, 'Renamed');
  });
}
