// Callable results require sealed boundary mocks without Firebase initialization.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _Firestore extends Mock implements FirebaseFirestore {}

class _Collection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _Functions extends Mock implements FirebaseFunctions {}

class _Callable extends Mock implements HttpsCallable {}

class _Result extends Mock
    implements HttpsCallableResult<Map<String, dynamic>> {}

void main() {
  late _Functions functions;
  late _Callable callable;
  late _Firestore firestore;
  late FirebaseAppointmentsRepository repo;
  final requests = <Map<String, dynamic>>[];
  final bookings = [
    for (var i = 0; i < 37; i++)
      AppointmentRecord(
        id: 'job-$i',
        startTime: DateTime(2026, 10, 18 + i, 9),
        endTime: DateTime(2026, 10, 18 + i, 10),
      ),
  ];

  setUp(() {
    requests.clear();
    firestore = _Firestore();
    functions = _Functions();
    callable = _Callable();
    when(() => firestore.collection('appointments')).thenReturn(_Collection());
    when(
      () => functions.httpsCallable('findAppointmentConflicts'),
    ).thenReturn(callable);
    when(() => callable.call<Map<String, dynamic>>(any<Object?>())).thenAnswer((
      invocation,
    ) async {
      final data = (invocation.positionalArguments.single as Map)
          .cast<String, dynamic>();
      requests.add(data);
      final result = _Result();
      when(() => result.data).thenReturn({
        'windows': <Map<String, Object>>[
          for (final _ in data['windows'] as List)
            {'busyEmployeeIds': <String>[]},
        ],
      });
      return result;
    });
    repo = FirebaseAppointmentsRepository(firestore, functions: functions);
  });
  tearDown(() => repo.dispose());

  test(
    '37 windows use three calls, preserve positions and send exclusions',
    () async {
      final result = await repo.findBusyEmployeeIdsForBookings(
        employeeIds: ['e1'],
        bookings: bookings,
        excludeOwnBookingIds: true,
        excludeAppointmentIds: {'old'},
      )!;
      expect(result, hasLength(37));
      expect(result, everyElement(isEmpty));
      expect(requests.map((request) => (request['windows'] as List).length), [
        16,
        16,
        5,
      ]);
      expect(
        ((requests.first['windows'] as List).first
            as Map)['excludeAppointmentId'],
        'job-0',
      );
      expect(requests.last['excludeAppointmentIds'], ['old']);
    },
  );

  test('each call sends only the excluded records its windows can meet', () async {
    await repo.findBusyEmployeeIdsForBookings(
      employeeIds: ['e1'],
      bookings: bookings,
      excludeAppointments: [
        AppointmentRecord(
          id: 'near-last-chunk',
          startTime: DateTime(2026, 11, 21, 9),
          endTime: DateTime(2026, 11, 21, 10),
        ),
        AppointmentRecord(
          id: 'far-future',
          startTime: DateTime(2027, 6, 1, 9),
          endTime: DateTime(2027, 6, 1, 10),
        ),
      ],
    );

    expect(requests.map((request) => request['excludeAppointmentIds']), [
      null,
      null,
      ['near-last-chunk'],
    ]);
  });

  test('missing window acknowledgments never become false clearance', () async {
    final response = _Result();
    when(() => response.data).thenReturn({'windows': <Object>[]});
    when(
      () => callable.call<Map<String, dynamic>>(any<Object?>()),
    ).thenAnswer((_) async => response);
    await expectLater(
      repo.findBusyEmployeeIdsForBookings(
        employeeIds: ['e1'],
        bookings: bookings.take(2).toList(),
      ),
      throwsFormatException,
    );
  });

  test(
    'old session results cannot dispatch the next batch under new credentials',
    () async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      repo.dispose();
      repo = FirebaseAppointmentsRepository(
        firestore,
        functions: functions,
        session: session,
      );
      final entered = Completer<void>();
      final gate = Completer<HttpsCallableResult<Map<String, dynamic>>>();
      when(
        () => callable.call<Map<String, dynamic>>(any<Object?>()),
      ).thenAnswer((_) {
        entered.complete();
        return gate.future;
      });
      final pending = repo.findBusyEmployeeIdsForBookings(
        employeeIds: ['e1'],
        bookings: bookings,
      )!;
      await entered.future;
      uid = 'B';
      gate.complete(_Result());
      await expectLater(pending, throwsStateError);
      verify(
        () => callable.call<Map<String, dynamic>>(any<Object?>()),
      ).called(1);
    },
  );
}
