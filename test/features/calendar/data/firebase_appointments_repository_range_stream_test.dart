// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  late _MockQuery tailQuery;
  late _RecordingLogger logger;
  late StreamController<QuerySnapshot<Map<String, dynamic>>> emissions;
  late StreamController<QuerySnapshot<Map<String, dynamic>>> tailEmissions;

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

  /// A wide personal block that started before [day]: what the tail serves.
  _FakeDoc block(String id, {required int daysAgo}) => _FakeDoc(id, {
    'title': 'Vacation',
    'startTime': Timestamp.fromDate(DateTime(2026, 8, 15 - daysAgo, 9)),
    'endTime': Timestamp.fromDate(DateTime(2026, 8, 20, 17)),
    'status': 'pending',
    'isPersonal': true,
    'employeeIds': const ['e1'],
  });

  /// One emission: [docs] in query order, with [changes] as its delta.
  void emit(List<_FakeDoc> docs, List<_FakeChange> changes) {
    final snapshot = _MockQuerySnapshot();
    when(() => snapshot.docs).thenReturn(docs);
    when(() => snapshot.docChanges).thenReturn(changes);
    emissions.add(snapshot);
  }

  /// The tail query's emission, same shape.
  void emitTail(List<_FakeDoc> docs, List<_FakeChange> changes) {
    final snapshot = _MockQuerySnapshot();
    when(() => snapshot.docs).thenReturn(docs);
    when(() => snapshot.docChanges).thenReturn(changes);
    tailEmissions.add(snapshot);
  }

  void resetEmissions() {
    emissions = StreamController<QuerySnapshot<Map<String, dynamic>>>();
    tailEmissions = StreamController<QuerySnapshot<Map<String, dynamic>>>();
    when(query.snapshots).thenAnswer((_) => emissions.stream);
    when(tailQuery.snapshots).thenAnswer((_) => tailEmissions.stream);
  }

  _FakeChange added(_FakeDoc d) => _FakeChange(DocumentChangeType.added, d);
  _FakeChange modified(_FakeDoc d) =>
      _FakeChange(DocumentChangeType.modified, d);
  _FakeChange removed(_FakeDoc d) => _FakeChange(DocumentChangeType.removed, d);

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    query = _MockQuery();
    tailQuery = _MockQuery();
    logger = _RecordingLogger();

    when(() => firestore.collection('appointments')).thenReturn(collection);
    // The tail chain opens on `isPersonal == true`, from the collection
    // (admin) or from the employee-scoped query.
    when(
      () => collection.where('isPersonal', isEqualTo: true),
    ).thenReturn(tailQuery);
    when(
      () => query.where('isPersonal', isEqualTo: true),
    ).thenReturn(tailQuery);
    when(
      () => tailQuery.where(
        'startTime',
        isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
      ),
    ).thenReturn(tailQuery);
    when(
      () => tailQuery.where('startTime', isLessThan: any(named: 'isLessThan')),
    ).thenReturn(tailQuery);
    when(() => tailQuery.orderBy(any())).thenReturn(tailQuery);
    when(() => tailQuery.limit(any())).thenReturn(tailQuery);
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
    resetEmissions();
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
    // Ending BOTH sources ends `retryStream`'s `await for`; a bare cancel
    // would hang until the generator reaches its next `yield`.
    await emissions.close();
    await tailEmissions.close();
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
      resetEmissions();

      final second = await collect(r.watchInRange(range), () {
        emit([a], [added(a)]);
      });

      expect(first.single.map((x) => x.id), ['a']);
      expect(second.single.map((x) => x.id), ['a']);
      // Both subscriptions parsed it: nothing leaks across listeners.
      expect(a.reads, 2);
    });
  });

  group('the personal tail query feeds the same list', () {
    test(
      'a tail block lands ahead of the window, in startTime order',
      () async {
        final a = doc('a', hour: 8);
        final wide = block('wide', daysAgo: 3);

        final lists = await collect(repo().watchInRange(range), () {
          emit([a], [added(a)]);
          emitTail([wide], [added(wide)]);
        });

        // One emission per query, the second one merged.
        expect(lists, hasLength(2));
        expect(lists.last.map((r) => r.id), ['wide', 'a']);
        expect(a.reads, 1);
        expect(wide.reads, 1);
      },
    );

    test('a doc served by both queries appears once', () async {
      final a = doc('a', hour: 8);
      final both = block('both', daysAgo: 0);

      final lists = await collect(repo().watchInRange(range), () {
        emitTail([both], [added(both)]);
        emit([both, a], [added(both), added(a)]);
      });

      expect(lists.last.map((r) => r.id), ['both', 'a']);
    });

    test('a block removed from the tail drops out of the list', () async {
      final a = doc('a', hour: 8);
      final wide = block('wide', daysAgo: 3);

      final lists = await collect(repo().watchInRange(range), () {
        emit([a], [added(a)]);
        emitTail([wide], [added(wide)]);
        emitTail([], [removed(wide)]);
      });

      expect(lists.last.map((r) => r.id), ['a']);
    });

    test('the main query starts at the window, the tail 14 days back', () {
      repo().watchInRange(range);

      verify(
        () => collection.where(
          'startTime',
          isGreaterThanOrEqualTo: Timestamp.fromDate(day),
        ),
      ).called(1);
      verify(
        () => tailQuery.where(
          'startTime',
          isGreaterThanOrEqualTo: Timestamp.fromDate(DateTime(2026, 8)),
        ),
      ).called(1);
      verify(
        () => tailQuery.where('startTime', isLessThan: Timestamp.fromDate(day)),
      ).called(1);
      verify(() => tailQuery.limit(3000)).called(1);
    });

    test('the employee variant scopes the tail on employeeIds too', () async {
      final a = doc('a', hour: 8);
      final wide = block('wide', daysAgo: 3);

      final lists = await collect(
        repo().watchForEmployeeInRange('e1', range),
        () {
          emit([a], [added(a)]);
          emitTail([wide], [added(wide)]);
        },
      );

      expect(lists.last.map((r) => r.id), ['wide', 'a']);
      // Both chains open on the array-contains clause the rules check.
      verify(
        () => collection.where('employeeIds', arrayContains: 'e1'),
      ).called(2);
      verify(() => query.where('isPersonal', isEqualTo: true)).called(1);
    });

    test(
      'the composites both tails and the overdue review need are declared',
      () {
        final manifest =
            jsonDecode(File('firestore.indexes.json').readAsStringSync())
                as Map<String, dynamic>;
        final indexes = (manifest['indexes'] as List)
            .cast<Map<String, dynamic>>();
        final declared = [
          for (final index in indexes)
            if (index['collectionGroup'] == 'appointments')
              [
                for (final field
                    in (index['fields'] as List).cast<Map<String, dynamic>>())
                  '${field['fieldPath']}:${field['arrayConfig'] ?? field['order']}',
              ].join(','),
        ];

        expect(declared, contains('isPersonal:ASCENDING,startTime:ASCENDING'));
        expect(
          declared,
          contains(
            'employeeIds:CONTAINS,isPersonal:ASCENDING,startTime:ASCENDING',
          ),
        );
        expect(
          declared,
          contains('isPersonal:ASCENDING,status:ASCENDING,endTime:DESCENDING'),
        );
      },
    );
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
