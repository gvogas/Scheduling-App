// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/data/appointment_history_scan.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _FakeDoc extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeDoc(this.id, this._data);

  @override
  final String id;

  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> data() => _data;
}

class _FakeFieldValue extends Fake implements FieldValue {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

final _t1 = DateTime(2026, 8, 1, 9);
final _t2 = DateTime(2026, 8, 2, 9);
final _t3 = DateTime(2026, 8, 3, 9);
final _t4 = DateTime(2026, 8, 4, 9);
final _t5 = DateTime(2026, 8, 5, 9);

AppointmentRecord _record(
  String id, {
  String status = 'done',
  String clientName = 'Ann',
  String clientPhone = '5145550100',
  List<String> employeeNames = const ['Bob'],
  String notes = '',
  DateTime? start,
}) => AppointmentRecord(
  id: id,
  startTime: start ?? _t3,
  endTime: (start ?? _t3).add(const Duration(hours: 1)),
  status: status,
  clientName: clientName,
  clientPhone: clientPhone,
  employeeNames: employeeNames,
  notes: notes,
);

void main() {
  var now = DateTime(2026, 9, 1, 12);
  late List<Map<String, dynamic>> windowSeed;
  late AppointmentHistoryScan scan;

  setUp(() {
    now = DateTime(2026, 9, 1, 12);
    windowSeed = [];
    final base = _MockQuery();
    final root = _MockQuery();
    final page = _MockQuerySnapshot();
    final limited = _MockQuery();
    when(() => root.orderBy('startTime', descending: true)).thenReturn(base);
    when(() => base.limit(any())).thenReturn(limited);
    when(limited.get).thenAnswer((_) async => page);
    when(() => page.docs).thenAnswer(
      (_) => [
        for (final d in windowSeed)
          _FakeDoc(d['id'] as String, d['data'] as Map<String, dynamic>),
      ],
    );
    scan = AppointmentHistoryScan(
      query: () => root,
      logger: AppLogger(),
      clock: () => now,
    );
  });

  Map<String, dynamic> raw(String id, DateTime? start, {String? status}) => {
    'id': id,
    'data': <String, dynamic>{
      'status': status ?? 'done',
      'startTime': start,
      'notes': '',
    },
  };

  Future<List<String>> windowIds() async => [
    for (final d in await scan.window()) d.id,
  ];

  group('cached answers', () {
    test('renaming clientName drops the cached answer', () {
      scan.results.write('q', [_record('a'), _record('b')]);
      scan.patch({
        'a': {'clientName': 'Zed'},
      });
      expect(scan.results.read('q'), isNull);
    });

    test('changing clientPhone drops the cached answer', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'a': {'clientPhone': '4385550199'},
      });
      expect(scan.results.read('q'), isNull);
    });

    test('changing employeeNames drops the cached answer', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'a': {
          'employeeNames': ['Cy'],
        },
      });
      expect(scan.results.read('q'), isNull);
    });

    test('restating the same search fields keeps the answer', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'a': {
          'clientName': 'Ann',
          'clientPhone': '5145550100',
          'employeeNames': ['Bob'],
          'notes': 'same people, new note',
        },
      });
      final kept = scan.results.read('q');
      expect(kept, isNotNull);
      expect(kept!.single.notes, 'same people, new note');
    });

    test('a newly terminal doc missing from the answer drops it', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'new': {'status': 'done', 'startTime': _t2},
      });
      expect(scan.results.read('q'), isNull);
    });

    test('a newly cancelled doc also drops it (cancelled is terminal)', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'new': {'status': 'cancelled', 'startTime': _t2},
      });
      expect(scan.results.read('q'), isNull);
    });

    test('a non-terminal doc outside the answer leaves it alone', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'new': {'status': 'pending', 'startTime': _t2},
      });
      expect(scan.results.read('q')!.map((r) => r.id), ['a']);
    });

    test('a field patch with no status is not terminal, answer kept', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'other': {'notes': 'x'},
      });
      expect(scan.results.read('q')!.map((r) => r.id), ['a']);
    });

    test('a deleted doc (null change) is removed, answer kept', () {
      scan.results.write('q', [_record('a'), _record('b')]);
      scan.patch({'a': null});
      expect(scan.results.read('q')!.map((r) => r.id), ['b']);
    });

    test('a reopened doc is removed from the answer', () {
      scan.results.write('q', [_record('a'), _record('b'), _record('c')]);
      scan.patch({
        'b': {'status': 'pending'},
      });
      expect(scan.results.read('q')!.map((r) => r.id), ['a', 'c']);
    });

    test('a reopened doc is removed even when it also renames the client', () {
      scan.results.write('q', [_record('a'), _record('b')]);
      scan.patch({
        'a': {'status': 'in_progress', 'clientName': 'Zed'},
      });
      // The non-terminal check runs before the rename check.
      expect(scan.results.read('q')!.map((r) => r.id), ['b']);
    });

    test('FieldValue entries are skipped in the merge', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'a': {'notes': 'n', 'updatedAt': _FakeFieldValue()},
      });
      final patched = scan.results.read('q')!.single;
      expect(patched.notes, 'n');
      expect(patched.updatedAt, isNull);
    });

    test('a FieldValue status never reopens or drops the doc', () {
      scan.results.write('q', [_record('a')]);
      scan.patch({
        'a': {'status': _FakeFieldValue()},
      });
      final patched = scan.results.read('q')!.single;
      expect(patched.status, 'done');
    });

    test('a plain non-search field edit patches in place, order kept', () {
      scan.results.write('q', [_record('a'), _record('b'), _record('c')]);
      scan.patch({
        'b': {'notes': 'edited', 'address': '12 Main'},
      });
      final out = scan.results.read('q')!;
      expect(out.map((r) => r.id), ['a', 'b', 'c']);
      expect(out[1].notes, 'edited');
      expect(out[1].address, '12 Main');
      expect(out[1].clientName, 'Ann');
      expect(out[0].notes, '');
    });

    test('patching applies to every cached query', () {
      scan.results.write('q1', [_record('a')]);
      scan.results.write('q2', [_record('a'), _record('b')]);
      scan.patch({
        'a': {'notes': 'n'},
      });
      expect(scan.results.read('q1')!.single.notes, 'n');
      expect(scan.results.read('q2')!.first.notes, 'n');
    });

    test('a stale answer is evicted rather than patched', () {
      scan.results.write('q', [_record('a')]);
      now = now.add(const Duration(minutes: 3));
      scan.patch({
        'a': {'notes': 'n'},
      });
      expect(scan.results.length, 0);
    });
  });

  group('scan window', () {
    test('a plain edit merges in place without moving the doc', () async {
      windowSeed = [raw('a', _t5), raw('b', _t3), raw('c', _t1)];
      expect(await windowIds(), ['a', 'b', 'c']);
      scan.patch({
        'b': {'notes': 'edited', 'updatedAt': _FakeFieldValue()},
      });
      final docs = await scan.window();
      expect(docs.map((d) => d.id), ['a', 'b', 'c']);
      expect(docs[1].data['notes'], 'edited');
      expect(docs[1].data.containsKey('updatedAt'), isFalse);
      expect(docs[1].data['status'], 'done');
    });

    test('a reopened doc leaves the window', () async {
      windowSeed = [raw('a', _t5), raw('b', _t3)];
      await scan.window();
      scan.patch({
        'a': {'status': 'pending'},
      });
      expect(await windowIds(), ['b']);
    });

    test('a deleted doc leaves the window', () async {
      windowSeed = [raw('a', _t5), raw('b', _t3)];
      await scan.window();
      scan.patch({'b': null});
      expect(await windowIds(), ['a']);
    });

    test('a new doc lands in startTime DESC position', () async {
      windowSeed = [raw('a', _t5), raw('b', _t3), raw('c', _t1)];
      await scan.window();
      scan.patch({
        'n': {'status': 'done', 'startTime': _t4},
      });
      expect(await windowIds(), ['a', 'n', 'b', 'c']);
    });

    test('a new newest doc lands first, a new oldest last', () async {
      windowSeed = [raw('b', _t3)];
      await scan.window();
      scan.patch({
        'newest': {'status': 'done', 'startTime': _t5},
        'oldest': {'status': 'cancelled', 'startTime': _t1},
      });
      expect(await windowIds(), ['newest', 'b', 'oldest']);
    });

    test('a new doc goes ahead of a null-startTime neighbour', () async {
      windowSeed = [raw('a', _t5), raw('nullStart', null)];
      await scan.window();
      scan.patch({
        'n': {'status': 'done', 'startTime': _t1},
      });
      expect(await windowIds(), ['a', 'n', 'nullStart']);
    });

    test('a field patch with no startTime is not inserted', () async {
      windowSeed = [raw('a', _t5)];
      await scan.window();
      scan.patch({
        'ghost': {'status': 'done'},
      });
      expect(await windowIds(), ['a']);
    });

    test('a new non-terminal doc is not inserted', () async {
      windowSeed = [raw('a', _t5)];
      await scan.window();
      scan.patch({
        'n': {'status': 'pending', 'startTime': _t4},
      });
      expect(await windowIds(), ['a']);
    });

    test('an expired window is dropped and re-read', () async {
      windowSeed = [raw('a', _t5)];
      await scan.window();
      now = now.add(const Duration(minutes: 3));
      scan.patch({
        'n': {'status': 'done', 'startTime': _t4},
      });
      windowSeed = [raw('z', _t2)];
      expect(await windowIds(), ['z']);
    });
  });
}
