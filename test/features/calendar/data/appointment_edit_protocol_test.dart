// Firestore sealed types require boundary mocks without a live Firebase app.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/app/session_fence.dart';
import 'package:scheduling/features/calendar/data/firebase_appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/calendar_failure.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';

class _Firestore extends Mock implements FirebaseFirestore {}

class _Collection extends Mock
    implements CollectionReference<Map<String, dynamic>> {}

class _Functions extends Mock implements FirebaseFunctions {}

class _Callable extends Mock implements HttpsCallable {}

class _Result extends Mock
    implements HttpsCallableResult<Map<String, dynamic>> {}

void main() {
  late _Firestore firestore;
  late _Functions functions;
  late _Callable callable;
  late _Result response;
  late FirebaseAppointmentsRepository repo;
  final original = AppointmentRecord(
    id: 'job',
    title: 'Visit',
    startTime: DateTime(2026, 10, 19, 9),
    endTime: DateTime(2026, 10, 19, 10),
  );

  setUp(() {
    firestore = _Firestore();
    functions = _Functions();
    callable = _Callable();
    response = _Result();
    when(() => firestore.collection('appointments')).thenReturn(_Collection());
    when(
      () => functions.httpsCallable('saveAppointmentEdits'),
    ).thenReturn(callable);
    when(
      () => callable.call<Map<String, dynamic>>(any<Object?>()),
    ).thenAnswer((_) async => response);
    when(() => response.data).thenReturn({
      'appointments': [
        {
          'id': 'job',
          'data': {...original.toMap(), 'status': 'done', 'notes': 'mine'},
        },
      ],
    });
    repo = FirebaseAppointmentsRepository(firestore, functions: functions);
  });

  tearDown(() => repo.dispose());

  test(
    'sends the original form and consumes the server merged completion',
    () async {
      await repo.updateAppointment(
        original.copyWith(notes: 'mine'),
        base: original,
      );
      final payload =
          verify(
                () =>
                    callable.call<Map<String, dynamic>>(captureAny<Object?>()),
              ).captured.single
              as Map;
      final edit = (payload['edits'] as List).single as Map;
      expect((edit['base'] as Map)['notes'], '');
      expect((edit['data'] as Map)['notes'], 'mine');
      expect(
        (edit['base'] as Map)['startTime'],
        original.startTime.millisecondsSinceEpoch,
      );
      expect(repo.takeAcknowledgedWrite('job')!.status, 'done');
      expect(repo.takeAcknowledgedWrite('job'), isNull);
    },
  );

  test('production edits cannot fall back to an unconditional write', () async {
    await expectLater(repo.updateAppointment(original), throwsStateError);
    verifyNever(() => callable.call<Map<String, dynamic>>(any<Object?>()));
  });

  test(
    'a malformed response cannot be reported as an acknowledged edit',
    () async {
      when(() => response.data).thenReturn({});
      await expectLater(
        repo.updateAppointment(original, base: original),
        throwsFormatException,
      );
    },
  );

  test(
    'an old acknowledgement cannot repopulate replacement-session state',
    () async {
      String? uid = 'A';
      final session = SessionFence(readUid: () => uid);
      repo.dispose();
      repo = FirebaseAppointmentsRepository(
        firestore,
        functions: functions,
        session: session,
      );
      final started = Completer<void>();
      final release = Completer<HttpsCallableResult<Map<String, dynamic>>>();
      when(
        () => callable.call<Map<String, dynamic>>(any<Object?>()),
      ).thenAnswer((_) {
        started.complete();
        return release.future;
      });
      final owner = repo.captureWriteOwner()!;
      final saving = repo.updateAppointment(original, base: original);
      await started.future;
      uid = 'B';
      release.complete(response);
      await saving;
      expect(owner(), isFalse);
      expect(repo.takeAcknowledgedWrite('job'), isNull);
    },
  );

  Map<String, dynamic> sentPayload() =>
      (verify(
                () =>
                    callable.call<Map<String, dynamic>>(captureAny<Object?>()),
              ).captured.single
              as Map)
          .cast<String, dynamic>();

  test('checkConflicts rides on the save and is absent by default', () async {
    await repo.updateAppointment(
      original.copyWith(notes: 'mine'),
      base: original,
      checkConflicts: true,
    );
    expect(sentPayload()['checkConflicts'], isTrue);

    await repo.updateAppointment(original.copyWith(notes: 'x'), base: original);
    expect(sentPayload().containsKey('checkConflicts'), isFalse);
  });

  test('a create goes through the callable, not a Firestore batch', () async {
    when(() => response.data).thenReturn({
      'appointments': [
        {'id': 'job', 'data': original.toMap()},
      ],
    });
    await repo.addAppointment(original, checkConflicts: true);
    final payload = sentPayload();
    expect(payload['checkConflicts'], isTrue);
    final create = (payload['creates'] as List).single as Map;
    expect(create['id'], 'job');
    expect(
      (create['data'] as Map)['startTime'],
      original.startTime.millisecondsSinceEpoch,
    );
  });

  test(
    'the busy refusal becomes the typed failure the sheet renders',
    () async {
      when(() => callable.call<Map<String, dynamic>>(any<Object?>())).thenThrow(
        FirebaseFunctionsException(
          code: 'failed-precondition',
          message: 'appointment-employee-busy',
          details: {
            'busyEmployeeIds': const ['e2'],
            'startMillis': original.startTime.millisecondsSinceEpoch,
            'endMillis': original.endTime.millisecondsSinceEpoch,
          },
        ),
      );
      await expectLater(
        repo.updateAppointment(original, base: original, checkConflicts: true),
        throwsA(
          isA<CalendarFailureEmployeesBusy>()
              .having((f) => f.busyEmployeeIds, 'busyEmployeeIds', ['e2'])
              .having((f) => f.start, 'start', original.startTime)
              .having((f) => f.end, 'end', original.endTime),
        ),
      );
      expect(repo.takeAcknowledgedWrite('job'), isNull);
    },
  );

  test('any other callable error passes through untouched', () async {
    when(() => callable.call<Map<String, dynamic>>(any<Object?>())).thenThrow(
      FirebaseFunctionsException(
        code: 'aborted',
        message: 'appointment-edit-conflict',
      ),
    );
    await expectLater(
      repo.updateAppointment(original, base: original, checkConflicts: true),
      throwsA(isA<FirebaseFunctionsException>()),
    );
  });
}
