import 'package:flutter_test/flutter_test.dart';
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
}
