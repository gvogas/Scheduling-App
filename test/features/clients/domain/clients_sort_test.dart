import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';

void main() {
  group('ClientsSort', () {
    test('name is the default and orders ascending on the composed name', () {
      expect(ClientsSort.name.field, 'name');
      expect(ClientsSort.name.descending, isFalse);
    });

    test('mostJobs orders jobCount descending', () {
      expect(ClientsSort.mostJobs.field, 'jobCount');
      expect(ClientsSort.mostJobs.descending, isTrue);
    });

    test('recentlyAdded orders createdAt descending', () {
      expect(ClientsSort.recentlyAdded.field, 'createdAt');
      expect(ClientsSort.recentlyAdded.descending, isTrue);
    });

    test('every member has a distinct Firestore field', () {
      final fields = ClientsSort.values.map((s) => s.field).toSet();
      expect(fields.length, ClientsSort.values.length);
    });

    // Pins F1: the two non-name sorts query a nullable field, so a client
    // missing it is dropped by Firestore. requiresBackfill is what a reader
    // greps for when a client goes missing from one sort only.
    test('the nullable-field sorts are flagged as needing the backfill', () {
      expect(ClientsSort.name.requiresBackfill, isFalse);
      expect(ClientsSort.mostJobs.requiresBackfill, isTrue);
      expect(ClientsSort.recentlyAdded.requiresBackfill, isTrue);
    });
  });

  group('sortClients', () {
    ClientRecord client(
      String id,
      String name, {
      int? jobCount,
      DateTime? createdAt,
    }) => ClientRecord(
      id: id,
      name: name,
      firstName: name.split(' ').first,
      lastName: name.split(' ').last,
      jobCount: jobCount,
      createdAt: createdAt,
    );

    List<String> ids(List<ClientRecord> records) => [
      for (final r in records) r.id,
    ];

    test('name orders on the display name, case-insensitively', () {
      final sorted = sortClients([
        client('c1', 'zoe brun'),
        client('c2', 'Alice Nadeau'),
        client('c3', 'bob Roy'),
      ], ClientsSort.name);
      expect(ids(sorted), ['c2', 'c3', 'c1']);
    });

    test('mostJobs orders descending', () {
      final sorted = sortClients([
        client('c1', 'Ana A', jobCount: 2),
        client('c2', 'Bea B', jobCount: 9),
        client('c3', 'Cal C', jobCount: 5),
      ], ClientsSort.mostJobs);
      expect(ids(sorted), ['c2', 'c3', 'c1']);
    });

    // Firestore's orderBy DROPS a doc missing the field; this keeps it, last.
    test('a client with NO jobCount sorts last rather than vanishing', () {
      final sorted = sortClients([
        client('c1', 'Ana A'),
        client('c2', 'Bea B', jobCount: 3),
      ], ClientsSort.mostJobs);
      expect(ids(sorted), ['c2', 'c1']);
      expect(sorted, hasLength(2), reason: 'nulls-last, never dropped');
    });

    test('recentlyAdded orders newest first, nulls last', () {
      final sorted = sortClients([
        client('c1', 'Ana A', createdAt: DateTime(2026, 3, 4)),
        client('c2', 'Bea B'),
        client('c3', 'Cal C', createdAt: DateTime(2026, 9, 4)),
      ], ClientsSort.recentlyAdded);
      expect(ids(sorted), ['c3', 'c1', 'c2']);
    });

    // Without a tie-break the order of equal counts is whatever the input was,
    // so the list reshuffles on any rebuild that reallocates it.
    test('equal counts tie-break on the name, so the order is total', () {
      final sorted = sortClients([
        client('c1', 'Cal C', jobCount: 4),
        client('c2', 'Ana A', jobCount: 4),
        client('c3', 'Bea B', jobCount: 4),
      ], ClientsSort.mostJobs);
      expect(ids(sorted), ['c2', 'c3', 'c1']);
    });

    test('every member is handled', () {
      for (final sort in ClientsSort.values) {
        expect(sortClients([client('c1', 'Ana A')], sort), hasLength(1));
      }
    });
  });
}
