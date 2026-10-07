// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

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

class _FakeDoc extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeDoc(this.id, this._data);

  @override
  final String id;

  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> data() => _data;
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
  late _MockQuerySnapshot snapshot;
  late _RecordingLogger logger;

  final now = DateTime(2026, 8, 15, 9);

  setUpAll(() {
    registerFallbackValue(_FakeDoc('fallback', const {}));
  });

  setUp(() {
    firestore = _MockFirestore();
    collection = _MockCollection();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();
    logger = _RecordingLogger();

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
      () => collection.where('status', whereIn: any(named: 'whereIn')),
    ).thenReturn(query);
    when(
      () => collection.where('clientId', isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(
      () => collection.where('seriesId', isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(
      () => query.where(
        'endTime',
        isGreaterThanOrEqualTo: any(named: 'isGreaterThanOrEqualTo'),
      ),
    ).thenReturn(query);
    when(
      () => query.where('startTime', isLessThan: any(named: 'isLessThan')),
    ).thenReturn(query);
    when(
      () => query.where('endTime', isLessThan: any(named: 'isLessThan')),
    ).thenReturn(query);
    when(
      () => query.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(query);
    when(() => query.orderBy(any())).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.startAfterDocument(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    when(() => snapshot.docs).thenReturn(const []);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore, logger: logger);

  void withJobs(int count) => when(() => snapshot.docs).thenReturn([
    for (var i = 0; i < count; i++)
      _FakeDoc('a$i', {
        'startTime': Timestamp.fromDate(now.subtract(const Duration(hours: 1))),
        'endTime': Timestamp.fromDate(now.add(const Duration(hours: 4))),
        'status': 'pending',
        'employeeIds': const ['e1'],
      }),
  ]);

  group('countFutureAssignments warns at its cap', () {
    test('a full page warns', () async {
      withJobs(200);

      expect(await repo().countFutureAssignments('e1'), 200);
      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('APPT-COUNT'));
      expect(logger.warnings.single, contains('200'));
    });

    test('a short page is silent', () async {
      withJobs(199);

      await repo().countFutureAssignments('e1');
      expect(logger.warnings, isEmpty);
    });
  });

  group('getSeries warns at its cap', () {
    void withSiblings(int count) => when(() => snapshot.docs).thenReturn([
      for (var i = 0; i < count; i++)
        _FakeDoc('s$i', {
          'startTime': Timestamp.fromDate(now),
          'endTime': Timestamp.fromDate(now.add(const Duration(hours: 1))),
          'status': 'pending',
          'seriesId': 'ser-1',
        }),
    ]);

    test('a full page warns, naming the consequence', () async {
      // The last bounded read in this repository whose warn nothing exercised.
      // Truncation here is not cosmetic: the result feeds `rewriteSeries`'
      // `deleteIds`, so a silently short series edit leaves orphan occurrences
      // behind with nothing anywhere reporting it.
      withSiblings(121);

      final result = await repo().getSeries('ser-1');

      expect(result, hasLength(121));
      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('APPT-LOAD'));
      expect(logger.warnings.single, contains('121'));
      verify(() => query.limit(121)).called(1);
    });

    test('a short page is silent', () async {
      withSiblings(12);

      await repo().getSeries('ser-1');

      expect(logger.warnings, isEmpty);
    });
  });

  group('the range query stays bounded', () {
    test('it names a ceiling', () async {
      await repo().fetchInRange(
        AppointmentDateRange(start: DateTime(2026, 8), end: DateTime(2026, 9)),
      );

      verify(() => query.limit(3000)).called(1);
    });

    test('a snapshot that comes back at the cap warns', () async {
      withJobs(3000);

      await repo().fetchInRange(
        AppointmentDateRange(start: DateTime(2026, 8), end: DateTime(2026, 9)),
      );

      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('APPT-LOAD'));
      expect(logger.warnings.single, contains('3000'));
    });

    test('a short snapshot is silent', () async {
      withJobs(2999);

      await repo().fetchInRange(
        AppointmentDateRange(start: DateTime(2026, 8), end: DateTime(2026, 9)),
      );

      expect(logger.warnings, isEmpty);
    });
  });

  test(
    'history search walks additional pages instead of warning at a cap',
    () async {
      final firstPage = [
        for (var i = 0; i < 500; i++)
          _FakeDoc('h$i', {
            'clientName': 'Sophie Tremblay',
            'employeeNames': const <String>[],
            'status': 'done',
          }),
      ];
      final secondPage = [
        _FakeDoc('h500', {
          'clientName': 'Sophie Tremblay',
          'employeeNames': const <String>[],
          'status': 'done',
        }),
      ];
      final secondSnapshot = _MockQuerySnapshot();
      when(() => snapshot.docs).thenReturn(firstPage);
      when(() => secondSnapshot.docs).thenReturn(secondPage);
      var call = 0;
      when(() => query.get()).thenAnswer((_) async {
        call++;
        return call == 1 ? snapshot : secondSnapshot;
      });

      final result = await repo().searchHistory('sophie');

      expect(result, hasLength(501));
      expect(result.last.id, 'h500');
      expect(logger.warnings, isEmpty);
      verify(() => query.startAfterDocument(firstPage.last)).called(1);
    },
  );

  test('history search stops at its scan ceiling and warns', () async {
    when(() => snapshot.docs).thenReturn([
      for (var i = 0; i < 500; i++)
        _FakeDoc('h$i', {
          'clientName': 'Sophie Tremblay',
          'employeeNames': const <String>[],
          'status': 'done',
        }),
    ]);

    await repo().searchHistory('sophie');

    // 5000 / 500 per page, PLUS one 1-document probe past the cap: that read
    // is the only way to tell an archive of exactly 5000 (nothing hidden) from
    // a larger one, and it happens only in the cap case. It must stop there
    // rather than walk the archive.
    verify(() => query.get()).called(11);
    expect(logger.warnings, hasLength(1));
    expect(logger.warnings.single, startsWith('HIST-SEARCH'));
    expect(logger.warnings.single, contains('5000'));
  });

  test('a client with EXACTLY the cap many visits does not warn', () async {
    // The false alarm the probe read exists to remove. `pageToCap` used to
    // test `docs.length >= cap` before the short-page test, so a client with
    // exactly 1000 visits filed a Crashlytics warn claiming "older visits are
    // not listed" when there were none — and this is a scan window whose warn
    // is the ONLY signal a real truncation gives.
    final full = [
      for (var i = 0; i < 500; i++)
        _FakeDoc('c$i', {
          'startTime': Timestamp.fromDate(now),
          'endTime': Timestamp.fromDate(now.add(const Duration(hours: 1))),
          'status': 'done',
        }),
    ];
    final empty = _MockQuerySnapshot();
    when(() => snapshot.docs).thenReturn(full);
    when(() => empty.docs).thenReturn(const []);
    var call = 0;
    when(() => query.get()).thenAnswer((_) async {
      call++;
      // Two full pages, then the probe finds nothing past the cap.
      return call <= 2 ? snapshot : empty;
    });

    final result = await repo().fetchClientHistory(clientId: 'c1');

    expect(result, hasLength(1000));
    expect(logger.warnings, isEmpty);
  });

  test('client history stops at its scan ceiling and warns', () async {
    when(() => snapshot.docs).thenReturn([
      for (var i = 0; i < 500; i++)
        _FakeDoc('c$i', {
          'startTime': Timestamp.fromDate(now),
          'endTime': Timestamp.fromDate(now.add(const Duration(hours: 1))),
          'status': 'done',
        }),
    ]);

    await repo().fetchClientHistory(clientId: 'c1');

    // 1000 / 500 per page - a busy client costs two round-trips, not twenty,
    // plus the one 1-document probe past the cap (see the sibling test above).
    verify(() => query.get()).called(3);
    expect(logger.warnings, hasLength(1));
    expect(logger.warnings.single, startsWith('APPT-LOAD'));
    expect(logger.warnings.single, contains('1000'));
  });

  group('the overdue review scans past blocks that never close', () {
    Map<String, dynamic> past(int hoursAgo, {bool isPersonal = false}) => {
      'startTime': Timestamp.fromDate(
        now.subtract(Duration(hours: hoursAgo + 1)),
      ),
      'endTime': Timestamp.fromDate(now.subtract(Duration(hours: hoursAgo))),
      'status': 'pending',
      'isPersonal': isPersonal,
    };

    /// Serves [newestFirst] the way the `endTime DESC` query would, cut at the
    /// limit the repository asked for.
    void withWindow(List<_FakeDoc> newestFirst) {
      var limit = 0;
      when(() => query.limit(any())).thenAnswer((call) {
        limit = call.positionalArguments.single as int;
        return query;
      });
      when(query.snapshots).thenAnswer((_) {
        when(() => snapshot.docs).thenReturn(newestFirst.take(limit).toList());
        return Stream.value(snapshot);
      });
    }

    test(
      '600 newer personal blocks do not hide an older overdue job',
      () async {
        withWindow([
          for (var i = 0; i < 600; i++)
            _FakeDoc('block$i', past(i + 1, isPersonal: true)),
          _FakeDoc('job', past(24 * 30)),
        ]);

        final jobs = await repo().watchOverdueOpen(now).first;

        expect(jobs.map((j) => j.id), ['job']);
        expect(logger.warnings, isEmpty);
      },
    );

    test(
      'more overdue jobs than the list holds warns once, oldest kept',
      () async {
        withWindow([
          for (var i = 0; i < 1001; i++) _FakeDoc('job$i', past(i + 1)),
        ]);

        final jobs = await repo().watchOverdueOpen(now).first;

        expect(jobs, hasLength(1000));
        expect(jobs.first.id, 'job1000');
        expect(logger.warnings, hasLength(1));
        expect(logger.warnings.single, startsWith('APPT-REVIEW 1001'));
      },
    );

    test('a scan window filled by personal blocks warns', () async {
      withWindow([
        for (var i = 0; i < 5001; i++)
          _FakeDoc('block$i', past(i + 1, isPersonal: true)),
      ]);

      final jobs = await repo().watchOverdueOpen(now).first;

      expect(jobs, isEmpty);
      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('APPT-REVIEW'));
      expect(logger.warnings.single, contains('5000'));
    });

    test('exactly the scan cap of rows is silent', () async {
      withWindow([
        for (var i = 0; i < 5000; i++)
          _FakeDoc('block$i', past(i + 1, isPersonal: true)),
      ]);

      await repo().watchOverdueOpen(now).first;

      expect(logger.warnings, isEmpty);
    });
  });
}
