// Fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/data/paged_scan.dart';

class _Doc extends Fake implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _Doc(this.id);

  @override
  final String id;
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _Snapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _Log {
  final limits = <int>[];
}

class _Query extends Fake implements Query<Map<String, dynamic>> {
  _Query(this._all, this._log, {this.offset = 0, this.max});

  final List<_Doc> _all;
  final _Log _log;
  final int offset;
  final int? max;

  @override
  Query<Map<String, dynamic>> limit(int limit) =>
      _Query(_all, _log, offset: offset, max: limit);

  @override
  Query<Map<String, dynamic>> startAfterDocument(
    DocumentSnapshot documentSnapshot,
  ) => _Query(
    _all,
    _log,
    offset: _all.indexWhere((d) => d.id == documentSnapshot.id) + 1,
    max: max,
  );

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    _log.limits.add(max!);
    return _Snapshot(_all.skip(offset).take(max!).toList());
  }
}

void main() {
  late _Log log;
  late int warnings;

  setUp(() {
    log = _Log();
    warnings = 0;
  });

  Query<Map<String, dynamic>> collection(int count) =>
      _Query([for (var i = 0; i < count; i++) _Doc('d$i')], log);

  Future<List<String>> scan(
    Query<Map<String, dynamic>> base, {
    int pageSize = 10,
    int cap = 25,
    PageCursor? advance,
  }) async {
    final docs = await pageToCap(
      base,
      pageSize: pageSize,
      cap: cap,
      onCapReached: () => warnings++,
      advance: advance ?? startAfterLastDocument,
    );
    return docs.map((d) => d.id).toList();
  }

  test('a short first page returns what it has and does not warn', () async {
    final ids = await scan(collection(3));

    expect(ids, ['d0', 'd1', 'd2']);
    expect(warnings, 0);
  });

  test('a partial final page is appended after the full ones', () async {
    final ids = await scan(collection(14), pageSize: 5);

    expect(ids, [for (var i = 0; i < 14; i++) 'd$i']);
    expect(warnings, 0);
  });

  test('exactly the cap many docs does not warn', () async {
    final ids = await scan(collection(25));

    expect(ids, hasLength(25));
    expect(warnings, 0);
  });

  test('more docs than the cap warns once and trims to the cap', () async {
    final ids = await scan(collection(40));

    expect(ids, [for (var i = 0; i < 25; i++) 'd$i']);
    expect(warnings, 1);
  });

  test('the last page asks only for the one probe doc past the cap', () async {
    await scan(collection(40));

    expect(log.limits, [10, 10, 6]);
  });

  test('a custom advance builds the next page query', () async {
    var advanced = 0;
    final ids = await scan(
      collection(7),
      pageSize: 3,
      cap: 100,
      advance: (query, last) {
        advanced++;
        return startAfterLastDocument(query, last);
      },
    );

    expect(ids, hasLength(7));
    expect(advanced, 2);
  });
}
