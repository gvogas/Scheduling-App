// Mocktail fakes must subclass cloud_functions' sealed result type.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockDoc extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

class _MockFunctions extends Mock implements FirebaseFunctions {}

class _MockCallable extends Mock implements HttpsCallable {}

class _MockVoidResult extends Mock implements HttpsCallableResult<void> {}

class _MockSearchResult extends Mock
    implements HttpsCallableResult<Map<String, dynamic>> {}

/// The CLIENT half of the mark-complete Undo. The server callable has its own
/// suite (`functions/__tests__/appointment_actions_callable.test.js`); what is
/// pinned here is the guard that never leaves the device and the cache patch
/// that keeps History honest afterwards.
void main() {
  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  late _MockFirestore firestore;
  late _MockCollection appointments;
  late _MockDoc doc;
  late _MockFunctions functions;
  late _MockCallable restore;
  late _MockCallable search;

  setUp(() {
    firestore = _MockFirestore();
    appointments = _MockCollection();
    doc = _MockDoc();
    functions = _MockFunctions();
    restore = _MockCallable();
    search = _MockCallable();

    when(() => firestore.collection('appointments')).thenReturn(appointments);
    when(() => appointments.doc(any())).thenReturn(doc);
    when(() => doc.update(any())).thenAnswer((_) async {});

    when(
      () => functions.httpsCallable('restoreAppointmentStatus'),
    ).thenReturn(restore);
    when(() => functions.httpsCallable('searchHistory')).thenReturn(search);
    when(
      () => restore.call<void>(any<Map<String, dynamic>>()),
    ).thenAnswer((_) async => _MockVoidResult());

    final searchResult = _MockSearchResult();
    when(() => searchResult.data).thenReturn({
      'appointments': [
        {
          'id': 'a1',
          'data': {'clientName': 'Sophie Tremblay', 'status': 'done'},
        },
      ],
    });
    when(
      () => search.call<Map<String, dynamic>>(any<Map<String, Object>>()),
    ).thenAnswer((_) async => searchResult);
  });

  FirebaseAppointmentsRepository repo() =>
      FirebaseAppointmentsRepository(firestore, functions: functions);

  group('restoreAppointmentStatus refuses a target that is not reopenable', () {
    // The callable re-checks all of this server-side; refusing here is what
    // keeps a bad Undo off the wire at all, and the previous status is
    // captured at the call site from a stored value that may be legacy.

    test('a terminal status is refused before the callable is reached', () {
      expect(
        () => repo().restoreAppointmentStatus(id: 'a1', previousStatus: 'done'),
        throwsArgumentError,
      );
      verifyNever(() => restore.call<void>(any<Map<String, dynamic>>()));
    });

    test('cancelled is terminal too', () {
      expect(
        () => repo().restoreAppointmentStatus(
          id: 'a1',
          previousStatus: 'cancelled',
        ),
        throwsArgumentError,
      );
      verifyNever(() => restore.call<void>(any<Map<String, dynamic>>()));
    });

    test('an off-allowlist status is refused', () {
      // A legacy `confirmed` doc would otherwise ask the server to write a
      // value the rules reject as an opaque permission-denied.
      expect(
        () => repo().restoreAppointmentStatus(
          id: 'a1',
          previousStatus: 'confirmed',
        ),
        throwsArgumentError,
      );
      verifyNever(() => restore.call<void>(any<Map<String, dynamic>>()));
    });

    test('pending and in_progress are the two that go through', () async {
      final r = repo();
      await r.restoreAppointmentStatus(id: 'a1', previousStatus: 'pending');
      await r.restoreAppointmentStatus(id: 'a1', previousStatus: 'in_progress');

      final sent = verify(
        () => restore.call<void>(captureAny<Map<String, dynamic>>()),
      ).captured.cast<Map<Object?, Object?>>();
      expect(sent.map((p) => p['previousStatus']), ['pending', 'in_progress']);
      expect(sent.first['appointmentId'], 'a1');
    });
  });

  group('a status write PATCHES cached searchHistory answers', () {
    // Re-running the callable costs up to 200 reads and a rate-limit
    // transaction, for a write that touched one document.
    int searchCalls() => verify(
      () => search.call<Map<String, dynamic>>(any<Map<String, Object>>()),
    ).callCount;

    test(
      'an undo drops the reopened row without re-running the search',
      () async {
        final r = repo();
        await r.searchHistory('sophie');
        searchCalls();

        await r.restoreAppointmentStatus(id: 'a1', previousStatus: 'pending');
        final after = await r.searchHistory('sophie');

        expect(after, isEmpty);
        verifyNever(
          () => search.call<Map<String, dynamic>>(any<Map<String, Object>>()),
        );
      },
    );

    test('a terminal-to-terminal change is merged into the row', () async {
      final r = repo();
      await r.searchHistory('sophie');
      searchCalls();

      await r.updateAppointmentStatus(id: 'a1', status: 'cancelled');
      final after = await r.searchHistory('sophie');

      expect(after.single.status, 'cancelled');
      expect(after.single.clientName, 'Sophie Tremblay');
      verifyNever(
        () => search.call<Map<String, dynamic>>(any<Map<String, Object>>()),
      );
    });

    test('completing a job the answer lacks re-runs the search', () async {
      // Only the query knows whether it matches the newly closed job.
      final r = repo();
      await r.searchHistory('sophie');
      searchCalls();

      await r.updateAppointmentStatus(id: 'b2', status: 'done');
      await r.searchHistory('sophie');

      expect(searchCalls(), 1);
    });

    test('renaming the client of a listed job re-runs the search', () async {
      final r = repo();
      await r.searchHistory('sophie');
      searchCalls();

      await r.updateAppointment(
        AppointmentRecord(
          id: 'a1',
          clientName: 'Marc Tremblay',
          status: 'done',
          startTime: DateTime(2026, 6, 24, 9),
          endTime: DateTime(2026, 6, 24, 10),
        ),
      );
      await r.searchHistory('sophie');

      expect(searchCalls(), 1);
    });
  });
}
