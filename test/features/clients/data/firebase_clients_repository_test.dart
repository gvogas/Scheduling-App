// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/clients/data/firebase_clients_repository.dart';
import 'package:scheduling/features/clients/domain/clients_failure.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';

class _RecordingLogger extends AppLogger {
  final warnings = <String>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    warnings.add(message);
  }
}

/// A plain fake rather than a `Mock`: the cap test builds a thousand of them,
/// and only `id` and `data()` are ever read.
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

class _MockQueryDocSnap extends Mock
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

class _MockDocRef extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

class _FakeFieldValue extends Fake implements FieldValue {}

class _MockFunctions extends Mock implements FirebaseFunctions {}

class _MockCallable extends Mock implements HttpsCallable {}

class _MockCallableResult extends Mock implements HttpsCallableResult<void> {}

void main() {
  late _MockFirestore firestore;
  late _RecordingLogger logger;
  late _MockCollection collection;
  late _MockQuery query;
  late _MockQuerySnapshot snapshot;
  late _MockDocRef docRef;
  late _MockFunctions functions;
  late _MockCallable callable;

  setUpAll(() {
    registerFallbackValue(_FakeFieldValue());
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(<Object?>[]);
  });

  _MockQueryDocSnap doc(String id, Map<String, dynamic> data) {
    final d = _MockQueryDocSnap();
    when(() => d.id).thenReturn(id);
    when(d.data).thenReturn(data);
    return d;
  }

  setUp(() {
    firestore = _MockFirestore();
    logger = _RecordingLogger();
    collection = _MockCollection();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();
    docRef = _MockDocRef();

    when(() => firestore.collection('clients')).thenReturn(collection);
    when(
      () => collection.where(any(), isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(
      () => collection.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(query);
    when(
      () => query.orderBy(any(), descending: any(named: 'descending')),
    ).thenReturn(query);
    when(
      () => query.where(any(), isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(() => query.startAfter(any())).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    when(() => snapshot.docs).thenReturn(const []);

    when(() => collection.doc(any())).thenReturn(docRef);
    when(() => docRef.id).thenReturn('new-id');
    when(() => docRef.update(any())).thenAnswer((_) async {});
    when(() => docRef.delete()).thenAnswer((_) async {});
    when(() => collection.add(any())).thenAnswer((_) async => docRef);

    functions = _MockFunctions();
    callable = _MockCallable();
    when(() => functions.httpsCallable(any())).thenReturn(callable);
    when(
      () => callable.call<void>(any<Object?>()),
    ).thenAnswer((_) async => _MockCallableResult());
  });

  FirebaseClientsRepository repo({DateTime Function()? clock}) =>
      FirebaseClientsRepository(
        firestore,
        functions: functions,
        clock: clock,
        logger: logger,
        useCallableSearch: false,
      );

  ClientRecord client({String id = 'c1', String name = 'Test Client'}) =>
      ClientRecord(
        id: id,
        name: name,
        phone: '555-0000',
        email: 'test@example.com',
        address: '1 Main St',
        city: 'Montreal',
        province: 'QC',
        country: 'Canada',
        postalCode: 'H1H 1H1',
      );

  group('in-flight scan windows', () {
    test('concurrent local searches share one Firestore scan', () async {
      final r = repo();
      final response = Completer<QuerySnapshot<Map<String, dynamic>>>();
      when(() => query.get()).thenAnswer((_) => response.future);
      final search = r.searchClients('smith');
      final archived = r.searchClients('archived');
      final buildings = r.searchClients('building');
      response.complete(snapshot);
      await Future.wait<Object>([search, archived, buildings]);
      verify(() => query.get()).called(1);
    });

    test('a scan completing after sign-out cannot repopulate caches', () async {
      final r = repo();
      final response = Completer<QuerySnapshot<Map<String, dynamic>>>();
      final oldSnapshot = _MockQuerySnapshot();
      final oldDocs = [
        doc('old', {'name': 'Smith', 'archived': true}),
      ];
      when(() => oldSnapshot.docs).thenReturn(oldDocs);
      when(() => query.get()).thenAnswer((_) => response.future);
      final old = r.searchClients('smith');
      r.clearCaches();
      response.complete(oldSnapshot);
      await old;
      when(() => query.get()).thenAnswer((_) async => snapshot);
      expect(await r.searchClients('smith'), isEmpty);
      expect(await r.fetchArchivedClients(), isEmpty);
    });

    test('a local write invalidates scans already in flight', () async {
      final r = repo();
      final response = Completer<QuerySnapshot<Map<String, dynamic>>>();
      final oldSnapshot = _MockQuerySnapshot();
      final oldDocs = [
        doc('c1', {'name': 'Smith', 'archived': false}),
      ];
      when(() => oldSnapshot.docs).thenReturn(oldDocs);
      when(() => query.get()).thenAnswer((_) => response.future);
      final old = r.fetchArchivedClients();
      await r.setClientArchived('c1', archived: true);
      response.complete(oldSnapshot);
      await old;
      final currentDocs = [
        doc('c1', {'name': 'Smith', 'archived': true}),
      ];
      when(() => snapshot.docs).thenReturn(currentDocs);
      when(() => query.get()).thenAnswer((_) async => snapshot);
      expect((await r.fetchArchivedClients()).map((c) => c.id), ['c1']);
    });
  });

  group('addClient', () {
    test('writes normalized email with createdAt and updatedAt', () async {
      await repo().addClient(client());

      final captured =
          (verify(() => collection.add(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(captured['email'], 'test@example.com');
      expect(captured.containsKey('createdAt'), isTrue);
      expect(captured.containsKey('updatedAt'), isTrue);
    });

    test('normalizes EVERY contact email, not just the top-level one', () async {
      // The loop was unhit: only the top-level address was ever asserted, so a
      // regression that normalized the client and skipped its contacts would
      // ship green.
      await repo().addClient(
        client().copyWith(
          email: '  Owner@Example.COM ',
          contacts: const [
            ClientContact(name: 'Site', email: ' Site@Example.COM'),
            ClientContact(name: 'Billing', email: 'BILLING@example.com  '),
          ],
        ),
      );

      final captured =
          (verify(() => collection.add(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(captured['email'], 'owner@example.com');
      final contacts = (captured['contacts'] as List)
          .map((c) => (c as Map)['email'])
          .toList();
      expect(contacts, ['site@example.com', 'billing@example.com']);
    });

    test('a contact with no email normalizes to empty, not null', () async {
      // `normalizeEmail` is fed `??
      await repo().addClient(
        client().copyWith(contacts: const [ClientContact(name: 'Site')]),
      );

      final captured =
          (verify(() => collection.add(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(((captured['contacts'] as List).single as Map)['email'], '');
    });

    test('returns the client with the generated doc id', () async {
      // The input has an empty id (new client); the returned record carries the
      // Firestore-generated id so callers can link to it immediately.
      final saved = await repo().addClient(client(id: ''));

      expect(saved.id, 'new-id');
    });
  });

  group('updateClient', () {
    test('writes normalized email with updatedAt', () async {
      await repo().updateClient(client());

      final raw = verify(() => docRef.update(captureAny())).captured.single;
      final captured = (raw as Map).cast<String, dynamic>();
      expect(captured['email'], 'test@example.com');
      expect(captured.containsKey('updatedAt'), isTrue);
    });
  });

  group('fetchClientsPage', () {
    test('first page orders by name + doc id without a cursor', () async {
      await repo().fetchClientsPage(limit: 50);

      verify(() => query.orderBy('name')).called(1);
      verify(() => query.orderBy(FieldPath.documentId)).called(1);
      verify(() => query.limit(50)).called(1);
      verifyNever(() => query.startAfter(any()));
      // Field-value cursor pagination must never refetch a boundary doc.
      verifyNever(() => collection.doc(any()));
    });

    test('filters archived out on the server, before ordering', () async {
      await repo().fetchClientsPage(limit: 50);

      // Server-side, deliberately: filtering a server page in Dart would
      // shorten a page the server actually filled, and the list's
      // `pages.last.length < pageSize` end-of-list test would truncate.
      verify(() => collection.where('archived', isEqualTo: false)).called(1);
    });

    test(
      'next page uses a field-value cursor (no boundary-doc re-read)',
      () async {
        final r = repo();
        // Build doc mocks before stubbing `docs` — mocktail forbids calling
        // `when` (inside the doc() helper) while another stub is being defined.
        final docs = [
          doc('c1', {'name': 'Test Client'}),
        ];
        when(() => snapshot.docs).thenReturn(docs);
        final page1 = await r.fetchClientsPage(limit: 1);

        await r.fetchClientsPage(limit: 1, after: page1.last);

        final captured = verify(
          () => query.startAfter(captureAny()),
        ).captured.single;
        expect(captured, ['Test Client', 'c1']);
        verifyNever(() => collection.doc(any()));
      },
    );

    test('legacy business-only boundary doc: cursor uses the stored (empty) '
        'name, not the businessName display fallback', () async {
      final r = repo();
      final docs = [
        doc('c9', {'name': '', 'businessName': 'Zebra Corp'}),
      ];
      when(() => snapshot.docs).thenReturn(docs);
      final page1 = await r.fetchClientsPage(limit: 1);
      // The record's display name falls back to the business name…
      expect(page1.last.name, 'Zebra Corp');

      await r.fetchClientsPage(limit: 1, after: page1.last);

      // …but the cursor must match the stored orderBy value or Firestore
      // would skip every doc sorted between '' and 'Zebra Corp'.
      final captured = verify(
        () => query.startAfter(captureAny()),
      ).captured.single;
      expect(captured, ['', 'c9']);
    });

    test('mostJobs orders by jobCount descending', () async {
      await repo().fetchClientsPage(limit: 50, sort: ClientsSort.mostJobs);

      verify(() => query.orderBy('jobCount', descending: true)).called(1);
      verify(() => query.orderBy(FieldPath.documentId)).called(1);
    });

    test('recentlyAdded orders by createdAt descending', () async {
      await repo().fetchClientsPage(limit: 50, sort: ClientsSort.recentlyAdded);

      verify(() => query.orderBy('createdAt', descending: true)).called(1);
    });

    test('archived is filtered out under every sort', () async {
      await repo().fetchClientsPage(limit: 50, sort: ClientsSort.mostJobs);

      verify(() => collection.where('archived', isEqualTo: false)).called(1);
    });

    test('the cursor tuple follows the sort, not the name', () async {
      final r = repo();
      final docs = [
        doc('c1', {'name': 'Test Client', 'jobCount': 7}),
      ];
      when(() => snapshot.docs).thenReturn(docs);
      final page1 = await r.fetchClientsPage(
        limit: 1,
        sort: ClientsSort.mostJobs,
      );

      await r.fetchClientsPage(
        limit: 1,
        after: page1.last,
        sort: ClientsSort.mostJobs,
      );

      final captured = verify(
        () => query.startAfter(captureAny()),
      ).captured.single;
      expect(captured, [7, 'c1']);
    });

    test('a boundary captured under one sort never resumes another', () async {
      final r = repo();
      final docs = [
        doc('c1', {'name': 'Test Client', 'jobCount': 7}),
      ];
      when(() => snapshot.docs).thenReturn(docs);
      // Page 1 under NAME caches 'Test Client' against c1...
      final page1 = await r.fetchClientsPage(limit: 1);

      // ...and resuming under jobCount must not reach for it, or Firestore
      // compares a string against a number and returns the wrong slice.
      await r.fetchClientsPage(
        limit: 1,
        after: page1.last,
        sort: ClientsSort.mostJobs,
      );

      final captured = verify(
        () => query.startAfter(captureAny()),
      ).captured.single;
      expect(captured, [7, 'c1']);
    });
  });

  group('the client scan window warns at its cap', () {
    // This is the quietest truncation in the app.
    void withClients(int count) => when(() => snapshot.docs).thenReturn([
      for (var i = 0; i < count; i++)
        _FakeDoc('c$i', {'name': 'Client ${i.toString().padLeft(4, '0')}'}),
    ]);

    test('a full first page is followed by the next page', () async {
      final firstPage = [
        for (var i = 0; i < 500; i++)
          _FakeDoc('c$i', {'name': 'Client ${i.toString().padLeft(4, '0')}'}),
      ];
      // Named so it, and only it, matches the query - a doc that landed on the
      // second page has to be findable, and ranking would bury a 'Client 0500'
      // below the alphabetically-earlier first page.
      final secondPage = [
        _FakeDoc('c500', {'name': 'Zephyr Holdings'}),
      ];
      final secondSnapshot = _MockQuerySnapshot();
      when(() => snapshot.docs).thenReturn(firstPage);
      when(() => secondSnapshot.docs).thenReturn(secondPage);
      var call = 0;
      when(() => query.get()).thenAnswer((_) async {
        call++;
        return call == 1 ? snapshot : secondSnapshot;
      });

      final results = await repo().searchClients('zephyr');

      expect(results.map((c) => c.id), contains('c500'));
      verify(() => query.startAfter(['Client 0499', 'c499'])).called(1);
    });

    test('a short window stays on one page', () async {
      withClients(499);

      await repo().searchClients('client');

      verifyNever(() => query.startAfter(any()));
    });

    test('the window stops at its ceiling and warns', () async {
      withClients(500);

      await repo().searchClients('client');

      // 5000 / 500 per page, PLUS one 1-document probe past the cap — the only
      // way to tell a roster of exactly 5000 (nothing hidden) from a larger
      // one, and paid only in the cap case.
      verify(() => query.get()).called(11);
      expect(logger.warnings, hasLength(1));
      expect(logger.warnings.single, startsWith('CLI-SEARCH'));
      expect(logger.warnings.single, contains('5000'));
    });
  });

  group('searchClients', () {
    test(
      'returns empty list without querying Firestore for a blank or '
      'punctuation-only query (search starts at the first searchable char)',
      () async {
        expect(await repo().searchClients('   '), isEmpty);
        expect(await repo().searchClients('@'), isEmpty);

        verifyNever(() => query.get());
      },
    );

    test('searches Firestore from the first character', () async {
      final results = await repo().searchClients('a');

      expect(results, isEmpty);
      verify(() => query.get()).called(1);
    });

    test('returns cached result on second call with same query', () async {
      final r = repo();
      await r.searchClients('John Smith');
      await r.searchClients('John Smith');

      // Firestore read should only fire once — second call uses cache.
      verify(() => query.get()).called(1);
    });

    test('distinct queries share one scan-window read while fresh', () async {
      final docs = [
        doc('c1', {'name': 'John Smith'}),
        doc('c2', {'name': 'Jane Doe'}),
      ];
      when(() => snapshot.docs).thenReturn(docs);

      final r = repo();
      expect((await r.searchClients('John')).map((c) => c.id), ['c1']);
      expect((await r.searchClients('Jane')).map((c) => c.id), ['c2']);

      // One window read serves both queries.
      verify(() => query.get()).called(1);
    });

    test('scan window expires after the TTL and is re-read', () async {
      var now = DateTime(2026, 7, 2, 12);
      final r = repo(clock: () => now);

      await r.searchClients('John');
      now = now.add(const Duration(minutes: 3));
      await r.searchClients('John');

      verify(() => query.get()).called(2);
    });

    test('a local write keeps the window alive past the plain TTL', () async {
      // `patched()` used to carry the ORIGINAL fetchedAt through, so the window
      // expired two minutes after the tab-open scan however much activity there
      // had been — and the first write after that idle re-paged every client
      // doc, plus a `fromMap` and a `buildingKeyFor` each, on the UI isolate.
      final docs = [
        doc('c1', {'name': 'John Smith'}),
      ];
      when(() => snapshot.docs).thenReturn(docs);

      var now = DateTime(2026, 7, 2, 12);
      final r = repo(clock: () => now);

      await r.searchClients('John');
      now = now.add(const Duration(minutes: 1, seconds: 30));
      await r.updateClient(client(name: 'John Smith'));
      // Past the 2-minute TTL measured from the ORIGINAL read, but only 30s
      // past the write.
      now = now.add(const Duration(minutes: 1, seconds: 30));
      await r.searchClients('John');

      verify(() => query.get()).called(1);
    });

    test('but never past the absolute ceiling', () async {
      // The TTL is the only protection against a REMOTE write, so a steadily
      // edited window must still age out.
      final docs = [
        doc('c1', {'name': 'John Smith'}),
      ];
      when(() => snapshot.docs).thenReturn(docs);

      var now = DateTime(2026, 7, 2, 12);
      final r = repo(clock: () => now);

      await r.searchClients('John');
      // Eleven one-minute writes: each is inside the TTL, and together they
      // carry the window past the 10-minute ceiling.
      for (var i = 0; i < 11; i++) {
        now = now.add(const Duration(minutes: 1));
        await r.updateClient(client(name: 'John Smith'));
      }
      now = now.add(const Duration(seconds: 30));
      await r.searchClients('John');

      verify(() => query.get()).called(2);
    });

    test(
      'updating a client is reflected in search without re-reading the window',
      () async {
        final docs = [
          doc('c1', {'name': 'John Smith'}),
        ];
        when(() => snapshot.docs).thenReturn(docs);

        final r = repo();
        expect((await r.searchClients('John')).map((c) => c.id), ['c1']);

        await r.updateClient(client(name: 'Renamed Person'));

        expect(await r.searchClients('John'), isEmpty);
        expect((await r.searchClients('Renamed')).map((c) => c.id), ['c1']);
        verify(() => query.get()).called(1);
      },
    );

    test(
      'adding a client makes it searchable without re-reading the window',
      () async {
        final docs = [
          doc('c1', {'name': 'John Smith'}),
        ];
        when(() => snapshot.docs).thenReturn(docs);
        when(() => docRef.id).thenReturn('c2');

        final r = repo();
        expect(await r.searchClients('Zebra'), isEmpty);

        await r.addClient(client(id: 'c2', name: 'Zebra Corp'));

        expect((await r.searchClients('Zebra')).map((c) => c.id), ['c2']);
        verify(() => query.get()).called(1);
      },
    );

    // I7: `_patchWindow` MERGES the write over the cached doc rather than
    // substituting it, because `toMap()` emits user-owned fields only.
    test(
      'a local write KEEPS the function-owned fields on the cached doc',
      () async {
        // Built before the stub: `doc()` stubs internally, and mocktail refuses
        // a `when` inside a stub response.
        final docs = [
          doc('c1', {
            'name': 'John Smith',
            // Function-owned: written by recountClientJobs and the server, and
            // deliberately absent from ClientRecord.toMap().
            'jobCount': 7,
            'waveCustomerId': 'wave-123',
          }),
        ];
        when(() => snapshot.docs).thenReturn(docs);

        final r = repo();
        expect((await r.searchClients('John')).single.jobCount, 7);

        await r.updateClient(client(name: 'John Smith Jr'));

        final patched = (await r.searchClients('John')).single;
        expect(patched.name, 'John Smith Jr');
        expect(
          patched.jobCount,
          7,
          reason: 'jobCount was dropped by the patch',
        );
        expect(patched.waveCustomerId, 'wave-123');
        verify(() => query.get()).called(1);
      },
    );

    test('ranks exact/prefix matches first, then alphabetical', () async {
      final docs = [
        doc('c1', {'name': 'Aaron Johnson', 'phone': '514-555-0101'}),
        doc('c2', {'name': 'John Smith', 'phone': '514-555-0102'}),
        doc('c3', {'name': 'Johnny Cash', 'phone': '514-555-0103'}),
      ];
      when(() => snapshot.docs).thenReturn(docs);

      final results = await repo().searchClients('John');

      // Prefix matches (John Smith, Johnny Cash) rank above the substring match
      // (Aaron Johnson); ties break alphabetically.
      expect(results.map((c) => c.id), ['c2', 'c3', 'c1']);
    });
  });

  group('indexed filters', () {
    test('building page constrains the server query before limiting', () async {
      await repo().fetchClientsPage(
        limit: 50,
        filter: const ClientsFilterBuilding('street|city'),
      );
      verify(() => collection.where('archived', isEqualTo: false)).called(1);
      verify(
        () => query.where('buildingKey', isEqualTo: 'street|city'),
      ).called(1);
      verify(() => query.limit(50)).called(1);
      verifyNever(
        () => collection.orderBy(any(), descending: any(named: 'descending')),
      );
    });

    test('type filter uses indexed equality', () async {
      await repo().fetchClientsByType(ClientType.commercial);
      verify(() => collection.where('archived', isEqualTo: false)).called(1);
      verify(() => query.where('type', isEqualTo: 'commercial')).called(1);
    });

    test('unset type and blank building need no reads', () async {
      final r = repo();
      expect(await r.fetchClientsByType(ClientType.unset), isEmpty);
      expect(await r.fetchClientsByBuilding(' '), isEmpty);
      verifyNever(() => query.get());
    });

    test('building menu reads summaries instead of client documents', () async {
      final catalog = _MockCollection();
      when(() => firestore.collection('clientBuildings')).thenReturn(catalog);
      when(
        () => catalog.where('clientCount', isGreaterThanOrEqualTo: 2),
      ).thenReturn(query);
      final docs = [
        doc('building', {
          'key': 'street|city',
          'street': 'Street',
          'city': 'City',
          'clientCount': 17,
        }),
      ];
      when(() => snapshot.docs).thenReturn(docs);
      final buildings = await repo().fetchBuildings();
      expect(buildings.single.clientCount, 17);
      verifyNever(
        () => collection.orderBy(any(), descending: any(named: 'descending')),
      );
      verify(() => query.orderBy('clientCount', descending: true)).called(1);
    });

    test(
      'archive outside the scan invalidates instead of inserting a partial row',
      () async {
        final r = repo();
        await r.searchClients('Smith');
        await r.setClientArchived('unloaded', archived: false);
        final docs = [
          doc('unloaded', {'name': 'Smith', 'jobCount': 4}),
        ];
        when(() => snapshot.docs).thenReturn(docs);
        final result = await r.searchClients('Smith');
        expect(result.single.name, 'Smith');
        expect(result.single.jobCount, 4);
        verify(() => query.get()).called(2);
      },
    );

    test('failed scans surface the error and remain retryable', () async {
      final r = repo();
      when(() => query.get()).thenThrow(
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      );
      await expectLater(
        r.searchClients('Smith'),
        throwsA(isA<FirebaseException>()),
      );
      when(() => query.get()).thenAnswer((_) async => snapshot);
      expect(await r.searchClients('Smith'), isEmpty);
      verify(() => query.get()).called(2);
    });

    test(
      'local search scopes before result limiting and caches each scope separately',
      () async {
        final docs = [
          doc('active', {
            'name': 'Smith',
            'archived': false,
            'type': 'commercial',
          }),
          doc('archived', {'name': 'Smith', 'archived': true}),
        ];
        when(() => snapshot.docs).thenReturn(docs);
        final r = repo();
        expect((await r.searchClients('Smith')).length, 2);
        expect(
          (await r.searchClients(
            'Smith',
            filter: const ClientsFilterArchived(),
          )).single.id,
          'archived',
        );
        expect(
          (await r.searchClients(
            'Smith',
            filter: const ClientsFilterType(ClientType.commercial),
          )).single.id,
          'active',
        );
        verify(() => query.get()).called(1);
      },
    );
  });

  group('archiving', () {
    test('setClientArchived writes the flag with updatedAt', () async {
      await repo().setClientArchived('c1', archived: true);

      verify(() => collection.doc('c1')).called(1);
      final captured =
          (verify(() => docRef.update(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(captured['archived'], isTrue);
      expect(captured.containsKey('updatedAt'), isTrue);
    });

    test(
      'setClientArchived merges into the window, keeping jobCount',
      () async {
        final docs = [
          doc('c1', {'name': 'Acme', 'archived': false, 'jobCount': 7}),
        ];
        when(() => snapshot.docs).thenReturn(docs);

        final r = repo();
        expect((await r.searchClients('Acme')).single.jobCount, 7);

        await r.setClientArchived('c1', archived: true);

        // Merged, never substituted: a plain replace drops the function-owned
        // jobCount and blanks the count on every search result until the TTL.
        final after = (await r.searchClients('Acme')).single;
        expect(after.archived, isTrue);
        expect(after.jobCount, 7);
        verify(() => query.get()).called(1);
      },
    );

    test('archived page constrains the query on the server', () async {
      await repo().fetchClientsPage(
        limit: 50,
        filter: const ClientsFilterArchived(),
      );
      verify(() => collection.where('archived', isEqualTo: true)).called(1);
      verify(() => query.limit(50)).called(1);
    });

    test('searchClients still returns archived clients', () async {
      final docs = [
        doc('c1', {'name': 'Acme', 'archived': true}),
      ];
      when(() => snapshot.docs).thenReturn(docs);

      // Archived clients stay searchable and bookable by design — only the
      // paginated list and the type filter hide them.
      expect((await repo().searchClients('Acme')).single.id, 'c1');
    });
  });

  group('deleteClient', () {
    test(
      'calls the callable and drops the doc from the cached window',
      () async {
        final docs = [
          doc('c1', {'name': 'Junk'}),
        ];
        when(() => snapshot.docs).thenReturn(docs);

        final r = repo();
        expect((await r.searchClients('Junk')).map((c) => c.id), ['c1']);

        await r.deleteClient('c1');

        verify(() => functions.httpsCallable('deleteClient')).called(1);
        final sent = verify(
          () => callable.call<void>(captureAny<Object?>()),
        ).captured.single;
        expect((sent as Map).cast<String, dynamic>()['clientId'], 'c1');
        // `allow delete` is withdrawn on /clients — the client never deletes
        // the doc directly.
        verifyNever(() => docRef.delete());
        // Evicted in memory, so search stops returning it with no second read.
        expect(await r.searchClients('Junk'), isEmpty);
        verify(() => query.get()).called(1);
      },
    );

    test('maps client-has-history to ClientsFailureHasHistory', () async {
      when(() => callable.call<void>(any<Object?>())).thenThrow(
        FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'client-has-history',
        ),
      );

      await expectLater(
        repo().deleteClient('c1'),
        throwsA(isA<ClientsFailureHasHistory>()),
      );
    });

    test('maps client-not-found to ClientsFailureNotFound', () async {
      when(() => callable.call<void>(any<Object?>())).thenThrow(
        FirebaseFunctionsException(
          code: 'not-found',
          message: 'client-not-found',
        ),
      );

      await expectLater(
        repo().deleteClient('c1'),
        throwsA(isA<ClientsFailureNotFound>()),
      );
    });

    test('rethrows an unrecognized callable failure untyped', () async {
      when(() => callable.call<void>(any<Object?>())).thenThrow(
        FirebaseFunctionsException(code: 'internal', message: 'boom'),
      );

      await expectLater(
        repo().deleteClient('c1'),
        throwsA(isA<FirebaseFunctionsException>()),
      );
    });
  });
}
