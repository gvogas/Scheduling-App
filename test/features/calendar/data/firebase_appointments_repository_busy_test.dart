// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

class _MockDocSnap extends Mock
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

class _RecordingLogger extends AppLogger {
  final warnings = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    warnings.add(message);
  }
}

void main() {
  late _MockFirestore firestore;
  late _MockCollection collection;
  late _MockQuery query;
  late _MockQuerySnapshot snapshot;

  setUpAll(() => registerFallbackValue(_MockDocSnap()));

  _MockDocSnap doc(Map<String, dynamic> data, {String id = 'appt'}) {
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
      () => collection.where(
        'employeeIds',
        arrayContainsAny: any(named: 'arrayContainsAny'),
      ),
    ).thenReturn(query);
    when(
      () => query.where('startTime', isLessThan: any(named: 'isLessThan')),
    ).thenReturn(query);
    when(
      () => query.where('endTime', isGreaterThan: any(named: 'isGreaterThan')),
    ).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    when(() => snapshot.docs).thenReturn(const []);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore);

  List<EmployeeRecord> employees(int n) => [
    for (var i = 0; i < n; i++) EmployeeRecord(id: 'e$i'),
  ];

  final start = DateTime(2026, 6, 24, 9);
  final end = DateTime(2026, 6, 24, 10);

  test('returns empty without querying when there are no candidates', () async {
    final result = await repo().findBusyEmployees(
      candidates: const [],
      start: start,
      end: end,
    );
    expect(result, isEmpty);
    verifyNever(() => query.get());
  });

  test('chunks >30 candidate ids into batches of 30 (whereArrayContainsAny '
      'limit) and covers every id exactly once', () async {
    await repo().findBusyEmployees(
      candidates: employees(31),
      start: start,
      end: end,
    );

    final captured = verify(
      () => collection.where(
        'employeeIds',
        arrayContainsAny: captureAny(named: 'arrayContainsAny'),
      ),
    ).captured;

    expect(captured.length, 2, reason: '31 ids -> two batches');
    final batch1 = (captured[0] as List).cast<String>();
    final batch2 = (captured[1] as List).cast<String>();
    expect(batch1.length, 30);
    expect(batch2.length, 1);
    expect({...batch1, ...batch2}.length, 31, reason: 'no overlap, full cover');
  });

  test(
    'bounds every chunk, so a wide booking cannot read without a ceiling',
    () async {
      // Two inequalities bound this in practice, so it is tail risk rather than
      // steady state — but a 14-day booking across a large roster reads every
      // overlapping job for up to 30 assignees per chunk on every Save, and
      // this was the last query in the repository naming no ceiling at all.
      await repo().findBusyEmployees(
        candidates: employees(31),
        start: start,
        end: end,
      );

      final caps = verify(() => query.limit(captureAny())).captured;
      expect(caps.length, 2, reason: 'one cap per chunk, not one for the lot');
      expect(caps.toSet().single, isA<int>());
    },
  );

  test('issues a single query for <=30 candidates', () async {
    await repo().findBusyEmployees(
      candidates: employees(30),
      start: start,
      end: end,
    );
    verify(() => query.get()).called(1);
  });

  test(
    'merges + dedupes busy ids and returns only matching candidates',
    () async {
      // Build the doc mock before stubbing `docs` — mocktail forbids calling
      // `when` (inside doc()) while another stub is being defined.
      final busyDoc = doc({
        'employeeIds': ['e0', 'e5', 'e30'],
      });
      when(() => snapshot.docs).thenReturn([busyDoc]);

      final result = await repo().findBusyEmployees(
        candidates: employees(31),
        start: start,
        end: end,
      );

      expect(result.map((e) => e.id).toSet(), {'e0', 'e5', 'e30'});
    },
  );

  test(
    'excludes the appointment being edited from its own conflicts',
    () async {
      // The only overlapping doc IS the one under edit — editing a job's notes
      // must not report its own assignees as busy.
      final ownDoc = doc({
        'employeeIds': ['e0'],
      }, id: 'a1');
      when(() => snapshot.docs).thenReturn([ownDoc]);

      final result = await repo().findBusyEmployees(
        candidates: employees(1),
        start: start,
        end: end,
        excludeAppointmentId: 'a1',
      );

      expect(result, isEmpty);
    },
  );

  group('the daily-window filter is actually WIRED IN', () {
    // `dailyWindowsOverlap`'s maths is pinned in its own suite, but nothing
    // ever reached it from here: every fixture above omits parseable times, so
    // the `docStart != null && docEnd != null` guard short-circuits and the
    // filter never runs.

    test(
      'a multi-day run does NOT clash with an evening job inside it',
      () async {
        // The phantom clash the helper exists to remove: instant-overlap said a
        // Mon–Fri 9-5 run collides with Wednesday 19:00, so the admin had to
        // force every evening job through the conflict dialog.
        final run = doc({
          'employeeIds': ['e0'],
          'startTime': Timestamp.fromDate(DateTime(2026, 6, 22, 9)),
          'endTime': Timestamp.fromDate(DateTime(2026, 6, 26, 17)),
        }, id: 'run');
        when(() => snapshot.docs).thenReturn([run]);

        final result = await repo().findBusyEmployees(
          candidates: employees(1),
          start: DateTime(2026, 6, 24, 19),
          end: DateTime(2026, 6, 24, 20),
        );

        expect(result, isEmpty);
      },
    );

    test('a genuine same-window clash is still reported', () async {
      final run = doc({
        'employeeIds': ['e0'],
        'startTime': Timestamp.fromDate(DateTime(2026, 6, 22, 9)),
        'endTime': Timestamp.fromDate(DateTime(2026, 6, 26, 17)),
      }, id: 'run');
      when(() => snapshot.docs).thenReturn([run]);

      final result = await repo().findBusyEmployees(
        candidates: employees(1),
        start: DateTime(2026, 6, 24, 10),
        end: DateTime(2026, 6, 24, 11),
      );

      expect(result.map((e) => e.id), ['e0']);
    });

    test('a doc with unparseable times is kept, not silently dropped', () async {
      // Fail toward REPORTING a clash: a legacy or console-written row with no
      // usable times must not quietly disappear from a booking-conflict check.
      final legacy = doc({
        'employeeIds': ['e0'],
        'startTime': 'not-a-time',
      }, id: 'legacy');
      when(() => snapshot.docs).thenReturn([legacy]);

      final result = await repo().findBusyEmployees(
        candidates: employees(1),
        start: start,
        end: end,
      );

      expect(result.map((e) => e.id), ['e0']);
    });
  });

  test('still reports a clash with a different appointment', () async {
    final otherDoc = doc({
      'employeeIds': ['e0'],
    }, id: 'a2');
    when(() => snapshot.docs).thenReturn([otherDoc]);

    final result = await repo().findBusyEmployees(
      candidates: employees(1),
      start: start,
      end: end,
      excludeAppointmentId: 'a1',
    );

    // The exclusion is by doc id, so a sibling occurrence of the same series
    // still surfaces.
    expect(result.map((e) => e.id), ['e0']);
  });

  group('findClashingAppointments', () {
    Map<String, dynamic> jobData({
      List<String> employeeIds = const ['e0'],
      String status = 'pending',
      bool isPersonal = false,
    }) => {
      'employeeIds': employeeIds,
      'status': status,
      'isPersonal': isPersonal,
      'startTime': Timestamp.fromDate(DateTime(2026, 6, 24, 9)),
      'endTime': Timestamp.fromDate(DateTime(2026, 6, 24, 10)),
    };

    test('returns empty without querying when there are no ids', () async {
      final result = await repo().findClashingAppointments(
        employeeIds: const [],
        start: start,
        end: end,
      );
      expect(result, isEmpty);
      verifyNever(() => query.get());
    });

    test('chunks >30 ids the same way findBusyEmployees does', () async {
      await repo().findClashingAppointments(
        employeeIds: [for (var i = 0; i < 31; i++) 'e$i'],
        start: start,
        end: end,
      );
      final captured = verify(
        () => collection.where(
          'employeeIds',
          arrayContainsAny: captureAny(named: 'arrayContainsAny'),
        ),
      ).captured;
      expect(captured.length, 2);
      expect((captured[0] as List).length, 30);
      expect((captured[1] as List).length, 1);
    });

    test('returns the clashing RECORDS, not the busy people', () async {
      final clashing = doc(jobData(), id: 'a1');
      when(() => snapshot.docs).thenReturn([clashing]);

      final result = await repo().findClashingAppointments(
        employeeIds: const ['e0'],
        start: start,
        end: end,
      );
      expect(result.map((r) => r.id), ['a1']);
    });

    test('a doc returned by two chunks is deduped by id', () async {
      final shared = doc(jobData(employeeIds: const ['e0', 'e30']), id: 'a1');
      when(() => snapshot.docs).thenReturn([shared]);

      final result = await repo().findClashingAppointments(
        employeeIds: [for (var i = 0; i < 31; i++) 'e$i'],
        start: start,
        end: end,
      );
      expect(result.length, 1);
    });

    test('clientJobsOnly excludes personal blocks', () async {
      final personal = doc(jobData(isPersonal: true), id: 'block');
      when(() => snapshot.docs).thenReturn([personal]);

      expect(
        await repo().findClashingAppointments(
          employeeIds: const ['e0'],
          start: start,
          end: end,
          clientJobsOnly: true,
        ),
        isEmpty,
      );
      // Still a real clash for busy-ness purposes — only the swap list drops
      // it, because a swap on someone else's own block is nonsense.
      expect(
        await repo().findClashingAppointments(
          employeeIds: const ['e0'],
          start: start,
          end: end,
        ),
        isNotEmpty,
      );
    });

    test('a terminal-status job is not a clash', () async {
      final done = doc(jobData(status: 'done'), id: 'a1');
      when(() => snapshot.docs).thenReturn([done]);

      expect(
        await repo().findClashingAppointments(
          employeeIds: const ['e0'],
          start: start,
          end: end,
        ),
        isEmpty,
      );
    });

    test('excludeAppointmentId drops the record being edited', () async {
      final self = doc(jobData(), id: 'self');
      when(() => snapshot.docs).thenReturn([self]);

      expect(
        await repo().findClashingAppointments(
          employeeIds: const ['e0'],
          start: start,
          end: end,
          excludeAppointmentId: 'self',
        ),
        isEmpty,
      );
    });
  });
  group('the conflict query stays bounded', () {
    // Every other ceiling in this repository has a paired test; this one had
    // none.
    _MockDocSnap clash(int i) => doc({
      'startTime': Timestamp.fromDate(start),
      'endTime': Timestamp.fromDate(end),
      'status': 'pending',
      'employeeIds': const ['e0'],
    }, id: 'c$i');

    void withRows(List<_MockDocSnap> docs) {
      var offset = 0;
      var limit = 0;
      when(() => query.limit(any())).thenAnswer((call) {
        limit = call.positionalArguments.single as int;
        return query;
      });
      when(() => query.startAfterDocument(any())).thenAnswer((call) {
        offset =
            docs.indexOf(call.positionalArguments.single as _MockDocSnap) + 1;
        return query;
      });
      when(
        () => snapshot.docs,
      ).thenAnswer((_) => docs.skip(offset).take(limit).toList());
    }

    test('it names a ceiling, once per 30-id chunk', () async {
      await repo().findClashingAppointments(
        employeeIds: const ['e0'],
        start: start,
        end: end,
      );

      verify(() => query.limit(500)).called(1);
    });

    test('a scan beyond the cap refuses to clear the booking', () async {
      final logger = _RecordingLogger();
      // Built BEFORE the stub: `clash` itself calls `when`, which mocktail
      // refuses inside a stub response.
      final docs = [for (var i = 0; i < 1001; i++) clash(i)];
      withRows(docs);

      await expectLater(
        FirebaseAppointmentsRepository(
          firestore,
          logger: logger,
        ).findClashingAppointments(
          employeeIds: const ['e0'],
          start: start,
          end: end,
        ),
        throwsStateError,
      );

      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('APPT-BUSY'));
      expect(logger.warnings.single, contains('incomplete'));
    });

    test('an exactly complete scan at the cap is silent', () async {
      final logger = _RecordingLogger();
      // Built BEFORE the stub: `clash` itself calls `when`, which mocktail
      // refuses inside a stub response.
      final docs = [for (var i = 0; i < 1000; i++) clash(i)];
      withRows(docs);

      await FirebaseAppointmentsRepository(
        firestore,
        logger: logger,
      ).findClashingAppointments(
        employeeIds: const ['e0'],
        start: start,
        end: end,
      );

      expect(logger.warnings, isEmpty);
    });

    test('the only open clash beyond a terminal first page is found', () async {
      withRows([
        for (var i = 0; i < 500; i++)
          doc({
            'startTime': Timestamp.fromDate(start),
            'endTime': Timestamp.fromDate(end),
            'status': 'done',
            'employeeIds': const ['e0'],
          }, id: 'done$i'),
        clash(500),
      ]);
      final result = await repo().findClashingAppointments(
        employeeIds: const ['e0'],
        start: start,
        end: end,
      );
      expect(result.map((job) => job.id), ['c500']);
    });
  });
}
