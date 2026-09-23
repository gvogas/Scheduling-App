// Mocktail fakes must subclass cloud_firestore's sealed query/snapshot types.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/employees/data/firebase_employees_repository.dart';
import 'package:scheduling/features/employees/domain/employees_failure.dart';
import 'package:scheduling/features/employees/domain/models/emergency_contact.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/employees/domain/models/job_title.dart';
import 'package:scheduling/features/employees/domain/policies/self_service_fields.dart';

class _MockFirestore extends Mock implements FirebaseFirestore {}

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult extends Mock
    implements HttpsCallableResult<dynamic> {}

class _MockCollection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _MockQuery extends Mock implements Query<Map<String, dynamic>> {}

class _MockQuerySnapshot extends Mock
    implements QuerySnapshot<Map<String, dynamic>> {}

class _MockQueryDocSnapshot extends Mock
    implements QueryDocumentSnapshot<Map<String, dynamic>> {}

class _MockSnapshotMetadata extends Mock implements SnapshotMetadata {}

class _MockDocRef extends Mock
    implements DocumentReference<Map<String, dynamic>> {}

class _MockDocSnapshot extends Mock
    implements DocumentSnapshot<Map<String, dynamic>> {}

class _MockTransaction extends Mock implements Transaction {}

class _FakeFieldValue extends Fake implements FieldValue {}

class _FakeHttpsCallableOptions extends Fake implements HttpsCallableOptions {}

void main() {
  late _MockFirestore firestore;
  late _MockFirebaseFunctions functions;
  late _MockCollection collection;
  late _MockQuery query;
  late _MockQuerySnapshot snapshot;
  late _MockDocRef docRef;
  late _MockDocSnapshot docSnapshot;
  late _MockTransaction transaction;

  setUpAll(() {
    registerFallbackValue(_FakeFieldValue());
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(_MockDocRef());
    registerFallbackValue((Transaction txn) async {});
    registerFallbackValue(Duration.zero);
    registerFallbackValue(_FakeHttpsCallableOptions());
    registerFallbackValue(SetOptions(merge: true));
  });

  setUp(() {
    firestore = _MockFirestore();
    functions = _MockFirebaseFunctions();
    collection = _MockCollection();
    query = _MockQuery();
    snapshot = _MockQuerySnapshot();
    docRef = _MockDocRef();
    docSnapshot = _MockDocSnapshot();
    transaction = _MockTransaction();

    when(() => firestore.collection('users')).thenReturn(collection);

    // Default: where chain returns the same query mock
    when(
      () => collection.where(any(), isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(
      () => collection.where(any(), whereIn: any(named: 'whereIn')),
    ).thenReturn(query);
    when(
      () => query.where(any(), whereIn: any(named: 'whereIn')),
    ).thenReturn(query);
    when(
      () => query.where(any(), isEqualTo: any(named: 'isEqualTo')),
    ).thenReturn(query);
    when(() => query.limit(any())).thenReturn(query);
    when(() => collection.limit(any())).thenReturn(query);
    when(() => query.get()).thenAnswer((_) async => snapshot);
    when(() => snapshot.docs).thenReturn(const []);

    when(() => collection.doc(any())).thenReturn(docRef);
    when(() => docRef.update(any())).thenAnswer((_) async {});
    when(() => docRef.get()).thenAnswer((_) async => docSnapshot);
    when(() => docRef.firestore).thenReturn(firestore);
    when(() => collection.add(any())).thenAnswer((_) async => docRef);

    // updateEmployee commits inside a transaction: run the handler with the
    // transaction mock, which re-reads the target doc.
    when(
      () => firestore.runTransaction<void>(
        any(),
        timeout: any(named: 'timeout'),
        maxAttempts: any(named: 'maxAttempts'),
      ),
    ).thenAnswer((invocation) {
      final handler =
          invocation.positionalArguments.first
              as Future<void> Function(Transaction);
      return handler(transaction);
    });
    when(() => transaction.get(docRef)).thenAnswer((_) async => docSnapshot);
    when(() => transaction.update(docRef, any())).thenReturn(transaction);
    when(docSnapshot.data).thenReturn(const {'email': 'old@example.com'});
  });

  FirebaseEmployeesRepository repo() =>
      FirebaseEmployeesRepository(firestore, functions: functions);

  /// The single captured update payload, cast the way mocktail requires —
  /// captureAny() returns Map<Object, Object?>, so a direct
  /// `as Map<String, dynamic>` throws at runtime.
  Map<String, dynamic> capturedUpdate() {
    final captured = verify(
      () => transaction.update(docRef, captureAny()),
    ).captured.single;
    return (captured as Map).cast<String, dynamic>();
  }

  group('createEmployeeAccount', () {
    test('returns the credentials and lowercases the email', () async {
      final callable = _MockHttpsCallable();
      final result = _MockHttpsCallableResult();
      when(
        () => functions.httpsCallable(
          any(that: equals('createEmployeeAccount')),
          options: any(named: 'options'),
        ),
      ).thenReturn(callable);
      when(() => result.data).thenReturn({
        'email': 'a@b.com',
        'password': 'Welcome123!',
        'docId': 'doc-1',
      });
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final repo = FirebaseEmployeesRepository(firestore, functions: functions);
      final credentials = await repo.createEmployeeAccount(
        name: 'A',
        firstName: 'A',
        lastName: '',
        email: 'A@B.com',
        phone: '',
        colorValue: '1',
        jobTitle: 'technician',
      );

      expect(credentials.email, 'a@b.com');
      expect(credentials.password, 'Welcome123!');
      final captured =
          (verify(
                    () => callable.call<dynamic>(captureAny<Object?>()),
                  ).captured.single
                  as Map)
              .cast<String, dynamic>();
      expect(captured['email'], 'a@b.com');
      expect(captured['jobTitle'], 'technician');
      expect(captured['firstName'], 'A');
    });

    test('rejects a half-blank credential payload', () async {
      // A blank half is unusable to the admin and would render an empty
      // credential dialog — fail loudly rather than show nothing.
      final callable = _MockHttpsCallable();
      final result = _MockHttpsCallableResult();
      when(
        () => functions.httpsCallable(
          any(that: equals('createEmployeeAccount')),
          options: any(named: 'options'),
        ),
      ).thenReturn(callable);
      when(() => result.data).thenReturn({'email': 'a@b.com', 'password': ''});
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final repo = FirebaseEmployeesRepository(firestore, functions: functions);
      await expectLater(
        repo.createEmployeeAccount(
          name: 'A',
          firstName: '',
          lastName: '',
          email: 'a@b.com',
          phone: '',
          colorValue: '1',
          jobTitle: '',
        ),
        throwsA(isA<EmployeesFailureUnknown>()),
      );
    });

    test('maps email-exists to EmployeesFailureEmailAlreadyExists', () async {
      final callable = _MockHttpsCallable();
      when(
        () => functions.httpsCallable(
          any(that: equals('createEmployeeAccount')),
          options: any(named: 'options'),
        ),
      ).thenReturn(callable);
      when(() => callable.call<dynamic>(any<Object?>())).thenThrow(
        FirebaseFunctionsException(
          message: 'email-exists',
          code: 'already-exists',
        ),
      );
      final repo = FirebaseEmployeesRepository(firestore, functions: functions);
      expect(
        () => repo.createEmployeeAccount(
          name: 'A',
          firstName: '',
          lastName: '',
          email: 'a@b.com',
          phone: '',
          colorValue: '1',
          jobTitle: '',
        ),
        throwsA(isA<EmployeesFailureEmailAlreadyExists>()),
      );
    });
  });

  /// Stubs [name] to a callable returning [data] and hands back the mock so
  /// the payload can be captured.
  _MockHttpsCallable stubCallable(String name, {Object? data}) {
    final callable = _MockHttpsCallable();
    final result = _MockHttpsCallableResult();
    when(
      () => functions.httpsCallable(
        any(that: equals(name)),
        options: any(named: 'options'),
      ),
    ).thenReturn(callable);
    when(() => result.data).thenReturn(data);
    when(
      () => callable.call<dynamic>(any<Object?>()),
    ).thenAnswer((_) async => result);
    return callable;
  }

  _MockHttpsCallable stubFailingCallable(
    String name,
    FirebaseFunctionsException error,
  ) {
    final callable = _MockHttpsCallable();
    when(
      () => functions.httpsCallable(
        any(that: equals(name)),
        options: any(named: 'options'),
      ),
    ).thenReturn(callable);
    when(() => callable.call<dynamic>(any<Object?>())).thenThrow(error);
    return callable;
  }

  /// captureAny() returns Map<Object, Object?>, so the direct generic cast
  /// throws at runtime — go through Map first.
  Map<String, dynamic> capturedPayload(_MockHttpsCallable callable) {
    final captured = verify(
      () => callable.call<dynamic>(captureAny<Object?>()),
    ).captured.single;
    return (captured as Map).cast<String, dynamic>();
  }

  test(
    'createEmployeeAccount never sends isAdmin — the server decides the role',
    () async {
      final callable = stubCallable(
        'createEmployeeAccount',
        data: {'email': 'a@b.test', 'password': 'Pw23456789x'},
      );

      await repo().createEmployeeAccount(
        name: 'A B',
        firstName: 'A',
        lastName: 'B',
        email: 'a@b.test',
        phone: '',
        colorValue: '1',
        jobTitle: '',
      );

      final payload = capturedPayload(callable);
      expect(payload.containsKey('isAdmin'), isFalse);
    },
  );

  group('completeEmployeeSetup', () {
    test('sends the password and all profile keys', () async {
      // The server reads the strings leniently (empty == absent) and the flags
      // as `=== true`, so a conditional payload shape would be a second thing
      // to test for no benefit.
      final callable = stubCallable('completeEmployeeSetup');

      await repo().completeEmployeeSetup(newPassword: 'ChosenSecret123!');

      final captured = capturedPayload(callable);
      expect(captured.keys, hasLength(6));
      expect(captured['firstName'], '');
      expect(captured['termsAccepted'], isFalse);
      expect(captured['locationConsent'], isFalse);
    });

    test('carries the setup profile and both consent flags', () async {
      final callable = stubCallable('completeEmployeeSetup');

      await repo().completeEmployeeSetup(
        newPassword: 'ChosenSecret123!',
        firstName: 'Zoé',
        lastName: 'Roy',
        phone: '(514) 555-1234',
        termsAccepted: true,
        locationConsent: true,
      );

      final captured = capturedPayload(callable);
      expect(captured['firstName'], 'Zoé');
      expect(captured['lastName'], 'Roy');
      expect(captured['phone'], '(514) 555-1234');
      expect(captured['termsAccepted'], isTrue);
      expect(captured['locationConsent'], isTrue);
    });

    test('trims setup profile strings before calling the server', () async {
      final callable = stubCallable('completeEmployeeSetup');

      await repo().completeEmployeeSetup(
        newPassword: 'ChosenSecret123!',
        firstName: '  Zoe ',
        lastName: ' Roy ',
        phone: ' (514) 555-1234 ',
      );

      final captured = capturedPayload(callable);
      expect(captured['firstName'], 'Zoe');
      expect(captured['lastName'], 'Roy');
      expect(captured['phone'], '(514) 555-1234');
    });
  });

  group('deleteEmployeeAccount', () {
    test('sends the doc id', () async {
      final callable = stubCallable(
        'deleteEmployeeAccount',
        data: {'ok': true},
      );

      await repo().deleteEmployeeAccount('doc-1');

      expect(capturedPayload(callable), {'docId': 'doc-1'});
    });

    test('maps account-not-pending to its own failure', () async {
      stubFailingCallable(
        'deleteEmployeeAccount',
        FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'account-not-pending',
        ),
      );

      await expectLater(
        repo().deleteEmployeeAccount('doc-1'),
        throwsA(isA<EmployeesFailureAccountNoLongerPending>()),
      );
    });

    test('maps account-not-found to the same failure', () async {
      // The admin needs the same thing said either way, and the live stream
      // has already dropped or flipped the row.
      stubFailingCallable(
        'deleteEmployeeAccount',
        FirebaseFunctionsException(
          code: 'not-found',
          message: 'account-not-found',
        ),
      );

      await expectLater(
        repo().deleteEmployeeAccount('doc-1'),
        throwsA(isA<EmployeesFailureAccountNoLongerPending>()),
      );
    });

    test('lets an unrelated failure escape unmapped', () async {
      stubFailingCallable(
        'deleteEmployeeAccount',
        FirebaseFunctionsException(code: 'internal', message: 'boom'),
      );

      await expectLater(
        repo().deleteEmployeeAccount('doc-1'),
        throwsA(isA<FirebaseFunctionsException>()),
      );
    });
  });

  group('updateEmployee', () {
    test(
      'throws EmployeesFailureEmailAlreadyExists when another employee has same email',
      () async {
        final otherDoc = _MockQueryDocSnapshot();
        when(() => otherDoc.id).thenReturn('other-id');
        when(() => snapshot.docs).thenReturn([otherDoc]);

        expect(
          () => repo().updateEmployee(
            docId: 'my-id',
            employee: const EmployeeRecord(
              id: 'my-id',
              name: 'Alice',
              email: 'alice@example.com',
              phone: '555-1234',
            ),
          ),
          throwsA(isA<EmployeesFailureEmailAlreadyExists>()),
        );
      },
    );

    test('writes updatedAt on successful update', () async {
      when(() => snapshot.docs).thenReturn(const []);

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Alice',
          email: 'alice@example.com',
          phone: '555-1234',
        ),
      );

      final captured = capturedUpdate();
      expect(captured.containsKey('updatedAt'), isTrue);
      expect(captured['email'], 'alice@example.com');
    });

    test('writes the P4 fields and never uid or status', () async {
      when(() => snapshot.docs).thenReturn(const []);

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Theo Roy',
          firstName: 'Theo',
          lastName: 'Roy',
          email: 'theo@x.com',
          phone: '555-0100',
          role: 'admin',
          status: 'active',
          uid: 'auth-uid-must-not-be-written',
          jobTitle: JobTitle.leadTech,
          maxJobsPerDay: 4,
          onCall: true,
          isTestAccount: true,
        ),
      );

      final data = capturedUpdate();
      expect(data['jobTitle'], 'lead_tech');
      expect(data['firstName'], 'Theo');
      expect(data['maxJobsPerDay'], 4);
      expect(data['onCall'], isTrue);
      expect(data['isTestAccount'], isTrue);
      expect(data['role'], 'admin');
      expect(data.containsKey('uid'), isFalse);
      expect(data.containsKey('status'), isFalse);
    });

    /// Makes the doc read report [uid], and makes the commit transaction see
    /// [emailAfterCallable] — what the server leaves behind once it has moved
    /// the email in both stores.
    void stubStoredDoc({required String uid, String? emailAfterCallable}) {
      when(
        docSnapshot.data,
      ).thenReturn({'email': 'old@example.com', 'uid': uid});
      if (emailAfterCallable == null) return;
      final txnSnapshot = _MockDocSnapshot();
      when(txnSnapshot.data).thenReturn({'email': emailAfterCallable});
      when(() => transaction.get(docRef)).thenAnswer((_) async => txnSnapshot);
    }

    test(
      'routes an email change through the callable when a uid exists',
      () async {
        stubStoredDoc(uid: 'auth-uid', emailAfterCallable: 'new@example.com');
        final callable = stubCallable(
          'changeEmployeeEmail',
          data: {'ok': true},
        );

        await repo().updateEmployee(
          docId: 'my-id',
          employee: const EmployeeRecord(
            id: 'my-id',
            name: 'Alice',
            email: 'New@Example.com ',
            uid: 'auth-uid',
          ),
        );

        // Auth is the store that owns sign-in, so it must never be the one left
        // behind — the callable moves both.
        expect(capturedPayload(callable), {
          'docId': 'my-id',
          'email': 'new@example.com',
        });
      },
    );

    test('runs the callable BEFORE the Firestore write', () async {
      // The ORDER is the whole fix, and the payload assertion above holds
      // whichever way round the two run. Auth is the store that owns sign-in
      // and the only one that can genuinely refuse a duplicate, so it must
      // never be the one left behind: a Firestore-first change leaves the
      // person signing in at the old address while every admin surface shows
      // the new one, and desyncs the two stores `createEmployeeAccount` joins
      // on. Same shape as `auth_service_test.dart`'s password-then-activate.
      stubStoredDoc(uid: 'auth-uid', emailAfterCallable: 'new@example.com');
      final callable = stubCallable('changeEmployeeEmail', data: {'ok': true});

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Alice',
          email: 'new@example.com',
          uid: 'auth-uid',
        ),
      );

      verifyInOrder([
        () => callable.call<dynamic>(any<Object?>()),
        () => transaction.update(docRef, any()),
      ]);
    });

    test('a refused callable leaves the users doc untouched', () async {
      // The half that matters: the Firestore write only ever "re-states what
      // the server committed", so a callable that threw must leave nothing
      // behind — otherwise the admin surface shows an address Auth refused.
      stubStoredDoc(uid: 'auth-uid');
      stubFailingCallable(
        'changeEmployeeEmail',
        FirebaseFunctionsException(
          message: 'email-exists',
          code: 'already-exists',
        ),
      );

      await expectLater(
        repo().updateEmployee(
          docId: 'my-id',
          employee: const EmployeeRecord(
            id: 'my-id',
            name: 'Alice',
            email: 'taken@example.com',
            uid: 'auth-uid',
          ),
        ),
        throwsA(isA<EmployeesFailureEmailAlreadyExists>()),
      );

      verifyNever(() => transaction.update(docRef, any()));
    });

    test('leaves the callable alone when the email is unchanged', () async {
      stubStoredDoc(uid: 'auth-uid');

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Alice',
          email: 'old@example.com',
          uid: 'auth-uid',
        ),
      );

      verifyNever(
        () => functions.httpsCallable(any(), options: any(named: 'options')),
      );
    });

    test(
      'treats a normalized match as unchanged even if the stored email has legacy casing',
      () async {
        stubStoredDoc(uid: 'auth-uid');
        when(
          docSnapshot.data,
        ).thenReturn({'email': ' Old@Example.com ', 'uid': 'auth-uid'});

        await repo().updateEmployee(
          docId: 'my-id',
          employee: const EmployeeRecord(
            id: 'my-id',
            name: 'Alice',
            email: 'old@example.com',
            uid: 'auth-uid',
          ),
        );

        verifyNever(
          () => functions.httpsCallable(any(), options: any(named: 'options')),
        );
      },
    );

    test('writes the email directly when the doc carries no uid', () async {
      stubStoredDoc(uid: '');

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Alice',
          email: 'new@example.com',
        ),
      );

      // Nothing to join: no Auth account exists behind this doc yet.
      verifyNever(
        () => functions.httpsCallable(any(), options: any(named: 'options')),
      );
      expect(capturedUpdate()['email'], 'new@example.com');
    });

    test('surfaces the callable email-exists refusal as a typed failure', () {
      stubStoredDoc(uid: 'auth-uid');
      stubFailingCallable(
        'changeEmployeeEmail',
        FirebaseFunctionsException(
          message: 'email-exists',
          code: 'already-exists',
        ),
      );

      expect(
        () => repo().updateEmployee(
          docId: 'my-id',
          employee: const EmployeeRecord(
            id: 'my-id',
            name: 'Alice',
            email: 'taken@example.com',
            uid: 'auth-uid',
          ),
        ),
        throwsA(isA<EmployeesFailureEmailAlreadyExists>()),
      );
    });

    test(
      'surfaces the callable email-changed refusal as a retryable failure and leaves the doc untouched',
      () async {
        stubStoredDoc(uid: 'auth-uid');
        stubFailingCallable(
          'changeEmployeeEmail',
          FirebaseFunctionsException(
            message: 'email-changed',
            code: 'failed-precondition',
          ),
        );

        await expectLater(
          repo().updateEmployee(
            docId: 'my-id',
            employee: const EmployeeRecord(
              id: 'my-id',
              name: 'Alice',
              email: 'new@example.com',
              uid: 'auth-uid',
            ),
          ),
          throwsA(isA<EmployeesFailureUnknown>()),
        );

        verifyNever(() => transaction.update(docRef, any()));
      },
    );

    test('saveEmergencyContact writes users/{id}/private/emergency', () async {
      final privateCollection = _MockCollection();
      final emergencyDoc = _MockDocRef();
      when(() => docRef.collection('private')).thenReturn(privateCollection);
      when(() => privateCollection.doc('emergency')).thenReturn(emergencyDoc);
      when(() => emergencyDoc.set(any(), any())).thenAnswer((_) async {});

      await repo().saveEmergencyContact(
        'my-id',
        const EmergencyContact(contact: '  Marie Roy ', phone: ' 555-0199 '),
      );

      // The path is the whole point: on the parent users doc this pair is
      // readable by every active peer.
      verify(() => collection.doc('my-id')).called(1);
      verify(() => privateCollection.doc('emergency')).called(1);

      final captured = verify(
        () => emergencyDoc.set(captureAny(), any()),
      ).captured.single;
      final data = (captured as Map).cast<String, dynamic>();
      expect(data['contact'], 'Marie Roy');
      expect(data['phone'], '555-0199');
      expect(data.containsKey('updatedAt'), isTrue);
      // Only the three keys the rules allow — anything else is rejected.
      expect(data.keys.toSet(), {'contact', 'phone', 'updatedAt'});
    });

    test('scrubs the legacy emergency pair off the parent users doc', () async {
      when(() => snapshot.docs).thenReturn(const []);

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(id: 'my-id', name: 'Theo Roy'),
      );

      final data = capturedUpdate();
      // They moved to users/{id}/private/emergency. A value left here by a
      // pre-move build is still readable by every active peer, so each save
      // deletes the keys rather than merely not writing them.
      expect(data.containsKey('emergencyContact'), isTrue);
      expect(data.containsKey('emergencyPhone'), isTrue);
      expect(data['emergencyContact'], isA<FieldValue>());
      expect(data['emergencyPhone'], isA<FieldValue>());
    });

    test('recomposes name from first and last', () async {
      when(() => snapshot.docs).thenReturn(const []);

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Stale Name',
          firstName: 'Theo',
          lastName: 'Roy',
          email: 'theo@x.com',
        ),
      );

      expect(capturedUpdate()['name'], 'Theo Roy');
    });

    test('keeps the stored name when both halves are blank', () async {
      when(() => snapshot.docs).thenReturn(const []);

      await repo().updateEmployee(
        docId: 'my-id',
        employee: const EmployeeRecord(
          id: 'my-id',
          name: 'Legacy Single Name',
          email: 'theo@x.com',
        ),
      );

      // Never empty: the repository preserves the stored fallback name when
      // split-name fields are blank.
      expect(capturedUpdate()['name'], 'Legacy Single Name');
    });

    test('aborts when the target email changed under the uniqueness check', () {
      when(() => snapshot.docs).thenReturn(const []);
      // Pre-check read sees the old email…
      when(docSnapshot.data).thenReturn(const {'email': 'old@example.com'});
      // …but the transactional re-read sees a concurrent edit.
      final freshSnapshot = _MockDocSnapshot();
      when(freshSnapshot.data).thenReturn(const {'email': 'new@example.com'});
      when(
        () => transaction.get(docRef),
      ).thenAnswer((_) async => freshSnapshot);

      expect(
        () => repo().updateEmployee(
          docId: 'my-id',
          employee: const EmployeeRecord(
            id: 'my-id',
            name: 'Alice',
            email: 'alice@example.com',
            phone: '555-1234',
          ),
        ),
        throwsA(isA<EmployeesFailureUnknown>()),
      );
      verifyNever(() => transaction.update(docRef, any()));
    });
  });

  group('auth-propagation retry (C2)', () {
    FirebaseException permissionDenied() =>
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');

    test('watchEmployees constrains role + active status', () async {
      when(query.snapshots).thenAnswer((_) => Stream.value(snapshot));
      repo().watchEmployees().listen((_) {});
      // retryStream builds the query on subscribe, one microtask later.
      await Future<void>.delayed(Duration.zero);

      // These constraints are not an optimization. For a LIST query Firestore
      // evaluates the rules against the query's constraints, not the docs, so
      // dropping the status filter doesn't return extra rows — it rejects the
      // whole query with permission-denied, which surfaces as an empty
      // employee picker and silently changes who can be assigned a visit.
      verify(
        () => collection.where('role', whereIn: ['employee', 'admin']),
      ).called(1);
      verify(() => query.where('status', isEqualTo: 'active')).called(1);
      // Bounded: this is a live listener held open for the whole session.
      verify(() => query.limit(1000)).called(1);
    });

    test('watchAssignableUsers constrains active status', () async {
      when(query.snapshots).thenAnswer((_) => Stream.value(snapshot));
      repo().watchAssignableUsers().listen((_) {});
      // retryStream builds the query on subscribe, one microtask later.
      await Future<void>.delayed(Duration.zero);

      verify(() => collection.where('status', isEqualTo: 'active')).called(1);
      verify(() => query.limit(1000)).called(1);
    });

    test(
      'watchEmployees sorts active users client-side by display name',
      () async {
        final zed = _MockQueryDocSnapshot();
        final amy = _MockQueryDocSnapshot();
        when(() => zed.id).thenReturn('z');
        when(() => amy.id).thenReturn('a');
        when(zed.data).thenReturn(const {
          'name': 'Zed Roy',
          'status': 'active',
          'role': 'employee',
        });
        when(amy.data).thenReturn(const {
          'firstName': 'Amy',
          'lastName': 'Adams',
          'status': 'active',
          'role': 'employee',
        });
        when(() => snapshot.docs).thenReturn([zed, amy]);
        when(query.snapshots).thenAnswer((_) => Stream.value(snapshot));

        final records = await repo().watchEmployees().first;

        expect(records.map((e) => e.id).toList(), ['a', 'z']);
      },
    );

    test(
      'watchAssignableUsers sorts active users client-side without requiring orderBy(name)',
      () async {
        final zed = _MockQueryDocSnapshot();
        final amy = _MockQueryDocSnapshot();
        when(() => zed.id).thenReturn('z');
        when(() => amy.id).thenReturn('a');
        when(
          zed.data,
        ).thenReturn(const {'name': 'Zed Roy', 'status': 'active'});
        when(amy.data).thenReturn(const {
          'firstName': 'Amy',
          'lastName': 'Adams',
          'status': 'active',
        });
        when(() => snapshot.docs).thenReturn([zed, amy]);
        when(query.snapshots).thenAnswer((_) => Stream.value(snapshot));

        final records = await repo().watchAssignableUsers().first;

        expect(records.map((e) => e.id).toList(), ['a', 'z']);
      },
    );

    test(
      'watchAllUsers sorts users client-side without requiring orderBy(name)',
      () async {
        final zed = _MockQueryDocSnapshot();
        final amy = _MockQueryDocSnapshot();
        when(() => zed.id).thenReturn('z');
        when(() => amy.id).thenReturn('a');
        when(
          zed.data,
        ).thenReturn(const {'name': 'Zed Roy', 'status': 'disabled'});
        when(amy.data).thenReturn(const {
          'firstName': 'Amy',
          'lastName': 'Adams',
          'status': 'invited',
        });
        when(query.snapshots).thenAnswer((_) => Stream.value(snapshot));
        when(
          () => collection.snapshots(),
        ).thenAnswer((_) => Stream.value(snapshot));
        when(() => snapshot.docs).thenReturn([zed, amy]);

        final records = await repo().watchAllUsers().first;

        expect(records.map((e) => e.id).toList(), ['a', 'z']);
        // No orderBy - it would exclude docs with no `name`, dropping an unnamed
        // user off the admin roster. The sort happens in Dart instead, which is
        // also where the cap warn lives.
        verifyNever(() => collection.orderBy(any()));
        verify(() => collection.limit(1000)).called(1);
      },
    );

    test('watchEmployees resubscribes past a permission-denied error', () {
      fakeAsync((async) {
        var subscriptions = 0;
        when(query.snapshots).thenAnswer((_) {
          subscriptions++;
          if (subscriptions == 1) {
            return Stream.error(permissionDenied());
          }
          return Stream.value(snapshot);
        });

        final emissions = <List<EmployeeRecord>>[];
        Object? error;
        repo().watchEmployees().listen(
          emissions.add,
          onError: (Object e) => error = e,
        );

        async.elapse(const Duration(seconds: 1));
        expect(subscriptions, 2);
        expect(error, isNull);
        expect(emissions, [isEmpty]);
      });
    });

    test('watchUserDoc resubscribes and then emits the user doc', () {
      fakeAsync((async) {
        final userDoc = _MockQueryDocSnapshot();
        when(userDoc.data).thenReturn(const {'role': 'admin'});
        // watchUserDoc memoizes this id so activeUserIdentityProvider doesn't
        // re-query for it.
        when(() => userDoc.id).thenReturn('doc-1');
        when(() => snapshot.docs).thenReturn([userDoc]);

        var subscriptions = 0;
        when(query.snapshots).thenAnswer((_) {
          subscriptions++;
          if (subscriptions == 1) {
            return Stream.error(permissionDenied());
          }
          return Stream.value(snapshot);
        });

        final emissions = <Map<String, dynamic>>[];
        Object? error;
        final repository = repo();
        repository
            .watchUserDoc('uid-1')
            .listen(emissions.add, onError: (Object e) => error = e);

        async.elapse(const Duration(seconds: 1));
        expect(subscriptions, 2);
        expect(error, isNull);
        expect(emissions, [
          {'role': 'admin'},
        ]);
        // The id the snapshot carried is now available without a second read.
        expect(repository.cachedUserDocId('uid-1'), 'doc-1');
      });
    });

    test('cachedUserDocId is scoped to the uid it resolved', () {
      fakeAsync((async) {
        final userDoc = _MockQueryDocSnapshot();
        when(userDoc.data).thenReturn(const {'role': 'admin'});
        when(() => userDoc.id).thenReturn('doc-1');
        when(() => snapshot.docs).thenReturn([userDoc]);
        when(query.snapshots).thenAnswer((_) => Stream.value(snapshot));

        final repository = repo();
        repository.watchUserDoc('uid-1').listen((_) {});
        async.elapse(const Duration(seconds: 1));

        // Handing back another account's doc id would resolve the wrong
        // person's schedule into both off-screen mirrors.
        expect(repository.cachedUserDocId('uid-2'), isNull);
      });
    });

    test(
      'cachedUserDocId is cleared when the authoritative stream goes empty',
      () {
        fakeAsync((async) {
          final userDoc = _MockQueryDocSnapshot();
          final liveSnapshot = _MockQuerySnapshot();
          final deletedSnapshot = _MockQuerySnapshot();
          final deletedMetadata = _MockSnapshotMetadata();
          when(userDoc.data).thenReturn(const {'role': 'admin'});
          when(() => userDoc.id).thenReturn('doc-1');
          when(() => liveSnapshot.docs).thenReturn([userDoc]);
          when(() => deletedSnapshot.docs).thenReturn(const []);
          when(() => deletedSnapshot.metadata).thenReturn(deletedMetadata);
          when(() => deletedMetadata.isFromCache).thenReturn(false);
          when(query.snapshots).thenAnswer(
            (_) => Stream.fromIterable([liveSnapshot, deletedSnapshot]),
          );

          final emissions = <Map<String, dynamic>>[];
          final repository = repo();
          repository.watchUserDoc('uid-1').listen(emissions.add);
          async.flushMicrotasks();

          expect(emissions, [
            {'role': 'admin'},
            <String, dynamic>{},
          ]);
          expect(repository.cachedUserDocId('uid-1'), isNull);
        });
      },
    );

    test('watchUserDoc does not retry a non-permission error', () {
      fakeAsync((async) {
        var subscriptions = 0;
        when(query.snapshots).thenAnswer((_) {
          subscriptions++;
          return Stream.error(
            FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
          );
        });

        Object? error;
        repo()
            .watchUserDoc('uid-1')
            .listen((_) {}, onError: (Object e) => error = e);

        async.elapse(const Duration(seconds: 5));
        expect(subscriptions, 1);
        expect(error, isA<FirebaseException>());
      });
    });
  });

  group('status transitions', () {
    test('deactivateEmployee writes disabled status and updatedAt', () async {
      await repo().deactivateEmployee('e1');

      final captured =
          (verify(() => docRef.update(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(captured['status'], 'disabled');
      expect(captured.containsKey('updatedAt'), isTrue);
    });

    test('reactivateEmployee writes active status and updatedAt', () async {
      await repo().reactivateEmployee('e1');

      final captured =
          (verify(() => docRef.update(captureAny())).captured.single as Map)
              .cast<String, dynamic>();
      expect(captured['status'], 'active');
      expect(captured.containsKey('updatedAt'), isTrue);
    });
  });

  group('updateSelfDetails', () {
    Future<Map<String, dynamic>> save({
      String phone = '(514) 555-1234',
      List<bool> workingDays = const [true, true, true, true, true, true, true],
      int workStartMinutes = 420,
      int workEndMinutes = 960,
      bool onCall = true,
      bool travelAlertsEnabled = true,
      bool locationSharingEnabled = false,
    }) async {
      await repo().updateSelfDetails(
        EmployeeRecord(
          id: 'u1',
          name: 'Self',
          email: 'self@example.com',
          phone: phone,
          workingDays: workingDays,
          workStartMinutes: workStartMinutes,
          workEndMinutes: workEndMinutes,
          onCall: onCall,
          travelAlertsEnabled: travelAlertsEnabled,
          locationSharingEnabled: locationSharingEnabled,
        ),
      );
      return (verify(() => docRef.update(captureAny())).captured.single as Map)
          .cast<String, dynamic>();
    }

    test('writes the self-service values', () async {
      final captured = await save();

      expect(captured['phone'], '(514) 555-1234');
      expect(captured['onCall'], isTrue);
      expect(captured['workStartMinutes'], 420);
      expect(captured['workEndMinutes'], 960);
      expect(captured['travelAlertsEnabled'], isTrue);
      expect(captured['locationSharingEnabled'], isFalse);
    });

    test('writes the travel-alert preference explicitly', () async {
      final captured = await save(travelAlertsEnabled: false);

      expect(captured['travelAlertsEnabled'], isFalse);
    });

    test('writes the location-sharing preference explicitly', () async {
      final captured = await save(locationSharingEnabled: true);

      expect(captured['locationSharingEnabled'], isTrue);
    });

    test('the patch carries no key outside the rules allowlist', () async {
      // The rules use `hasOnly`, so one stray key rejects the WHOLE write and
      // reaches the user as an opaque permission-denied. This is the assertion
      // that matters most in this group.
      final captured = await save();

      expect(captured.keys, everyElement(isIn(kSelfServiceUserFields)));
    });

    test('never sends the emergency scrub updateEmployee sends', () async {
      // updateEmployee deletes the legacy emergency pair on every save. Doing
      // that here would add two keys the allowlist does not name.
      final captured = await save();

      expect(captured.containsKey('emergencyContact'), isFalse);
      expect(captured.containsKey('emergencyPhone'), isFalse);
    });

    test('never sends an admin-owned field', () async {
      final captured = await save();

      for (final admin in const ['role', 'status', 'email', 'maxJobsPerDay']) {
        expect(captured.containsKey(admin), isFalse, reason: admin);
      }
    });

    test('normalizes working days to seven flags', () async {
      final captured = await save(workingDays: const [true, true]);

      expect((captured['workingDays']! as List).length, 7);
    });

    test('trims the phone', () async {
      final captured = await save(phone: '  (514) 555-1234  ');

      expect(captured['phone'], '(514) 555-1234');
    });

    test('stamps updatedAt', () async {
      final captured = await save();

      expect(captured.containsKey('updatedAt'), isTrue);
    });

    test('is a plain update, never a transaction', () async {
      // No concurrent writer to guard against — a person edits their own doc
      // from one device — and the iOS transaction plugin bug makes a needless
      // client transaction a real risk, not just overhead.
      await save();

      verifyNever(
        () => firestore.runTransaction<void>(
          any(),
          timeout: any(named: 'timeout'),
          maxAttempts: any(named: 'maxAttempts'),
        ),
      );
    });
  });
}
