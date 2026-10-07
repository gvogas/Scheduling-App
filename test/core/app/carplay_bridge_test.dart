// Pins the app's FIRST Swift → Dart method-call handler.
//
// Everything here runs from a platform message, which has no Dart caller left
// to catch anything: a throw that escapes the handler is filed as an app-level
// FATAL from a car screen that merely failed to place a call. So the cases that
// matter are the ones with no other cover — a repository throw, an unknown
// method, and a torn-down bridge.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/app/carplay_bridge.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointments_repository.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_provider.dart';
import 'package:scheduling/features/siri/application/schedule_snapshot_service.dart';

class _FakeRepository extends Mock implements AppointmentsRepository {}

class _FakeSnapshotService extends Mock implements ScheduleSnapshotService {}

/// Records what the bridge routes into `AppLogger.warn`.
class _RecordingLogger extends AppLogger {
  final calls = <({String message, Object? error})>[];

  @override
  void warn(String message, [Object? error, StackTrace? stack]) {
    calls.add((message: message, error: error));
  }
}

const _codec = StandardMethodCodec();

const _snapshot = {'version': 4, 'role': 'admin', 'days': <Object>[]};

AppointmentRecord _job({String clientPhone = '(514) 555-1234'}) =>
    AppointmentRecord(
      id: 'a1',
      startTime: DateTime(2026, 9, 9, 9),
      endTime: DateTime(2026, 9, 9, 10),
      clientPhone: clientPhone,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRepository repository;
  late _FakeSnapshotService snapshotService;
  late _RecordingLogger logger;

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    repository = _FakeRepository();
    snapshotService = _FakeSnapshotService();
    logger = _RecordingLogger();
    when(
      () => repository.updateAppointmentStatus(
        id: any(named: 'id'),
        status: any(named: 'status'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => repository.getAppointmentById(any()),
    ).thenAnswer((_) async => _job());
    when(() => snapshotService.writeSnapshot(any())).thenAnswer((_) async {});
    when(() => snapshotService.clearSnapshot()).thenAnswer((_) async {});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(carPlayChannelName),
          null,
        );
  });

  /// A started bridge over a container whose snapshot emits [snapshot].
  CarPlayBridge start({
    bool isIos = true,
    bool isOffline = false,
    AsyncValue<Map<String, dynamic>?> snapshot = const AsyncValue.data(
      _snapshot,
    ),
  }) {
    final container = ProviderContainer(
      overrides: [
        loggerProvider.overrideWithValue(logger),
        isOfflineProvider.overrideWithValue(isOffline),
        appointmentsRepositoryProvider.overrideWithValue(repository),
        scheduleSnapshotServiceProvider.overrideWithValue(snapshotService),
        scheduleSnapshotProvider.overrideWith((ref) => snapshot),
        carPlayBridgeProvider.overrideWith(
          (ref) => CarPlayBridge(ref, isIosPlatform: () => isIos),
        ),
      ],
    );
    addTearDown(container.dispose);
    final bridge = container.read(carPlayBridgeProvider)..start();
    addTearDown(bridge.dispose);
    return bridge;
  }

  /// Delivers a Swift → Dart call and returns the raw reply envelope, which is
  /// null when the handler answered `notImplemented`.
  Future<ByteData?> callFromSwift(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    ByteData? reply;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          carPlayChannelName,
          _codec.encodeMethodCall(MethodCall(method, arguments)),
          (envelope) => reply = envelope,
        );
    return reply;
  }

  /// The decoded result of a Swift → Dart call.
  Future<Object?> resultOf(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async => _codec.decodeEnvelope((await callFromSwift(method, arguments))!);

  group('carPlayConnected', () {
    test('rewrites the settled snapshot and answers null', () async {
      start();

      expect(await resultOf('carPlayConnected'), isNull);
      verify(() => snapshotService.writeSnapshot(_snapshot)).called(1);
    });

    test('a settled null clears instead of writing', () async {
      start(snapshot: const AsyncValue.data(null));

      await resultOf('carPlayConnected');

      verify(() => snapshotService.clearSnapshot()).called(1);
      verifyNever(() => snapshotService.writeSnapshot(any()));
    });

    test('an unsettled snapshot neither writes nor clears', () async {
      // Same rule as the AppSyncListeners mirror: a failed read is not a
      // sign-out, and a stale snapshot beats a wrongly-empty one.
      start(snapshot: AsyncValue.error(StateError('denied'), StackTrace.empty));

      await resultOf('carPlayConnected');

      verifyNever(() => snapshotService.clearSnapshot());
      verifyNever(() => snapshotService.writeSnapshot(any()));
    });
  });

  group('setAppointmentStatus', () {
    test('writes through the existing repository method', () async {
      start();

      final result = await resultOf('setAppointmentStatus', {
        'id': 'a1',
        'status': 'in_progress',
      });

      expect(result, isTrue);
      verify(
        () =>
            repository.updateAppointmentStatus(id: 'a1', status: 'in_progress'),
      ).called(1);
    });

    test('a repository throw answers false and logs a CARPLAY warn', () async {
      when(
        () => repository.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      ).thenThrow(StateError('permission-denied'));
      start();

      final result = await resultOf('setAppointmentStatus', {
        'id': 'a1',
        'status': 'done',
      });

      // Handled, not escaped: the car shows "couldn't do that" and Crashlytics
      // still gets the operation under its tag.
      expect(result, isFalse);
      expect(
        logger.calls.single.message,
        'CARPLAY setAppointmentStatus failed',
      );
      expect(logger.calls.single.error, isA<StateError>());
    });

    test('offline it fails fast instead of awaiting a server ack', () async {
      // An awaited Firestore write only resolves on server ack, so without the
      // guard the channel reply never arrives and the driver — offline being
      // the normal condition in a moving vehicle — sees no answer at all.
      start(isOffline: true);

      final result = await resultOf('setAppointmentStatus', {
        'id': 'a1',
        'status': 'done',
      });

      expect(result, isFalse);
      verifyNever(
        () => repository.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      );
    });

    test('the offline refusal is logged under CARPLAY', () async {
      start(isOffline: true);

      await resultOf('setAppointmentStatus', {'id': 'a1', 'status': 'done'});

      expect(
        logger.calls.single.message,
        'CARPLAY setAppointmentStatus blocked while offline',
      );
    });

    test('a missing id writes nothing', () async {
      start();

      expect(
        await resultOf('setAppointmentStatus', {'status': 'done'}),
        isFalse,
      );
      verifyNever(
        () => repository.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      );
    });
  });

  group('dialableNumberFor', () {
    test('answers the FINISHED tel: URI, stripped by dialableUri', () async {
      start();

      // The stored number is formatted; handing Swift the raw text would make
      // it hand-mirror the stripping rule.
      expect(
        await resultOf('dialableNumberFor', {'id': 'a1'}),
        'tel:5145551234',
      );
    });

    test('a job with no number answers null', () async {
      when(
        () => repository.getAppointmentById(any()),
      ).thenAnswer((_) async => _job(clientPhone: ''));
      start();

      expect(await resultOf('dialableNumberFor', {'id': 'a1'}), isNull);
    });

    test('an unknown appointment answers null', () async {
      when(
        () => repository.getAppointmentById(any()),
      ).thenAnswer((_) async => null);
      start();

      expect(await resultOf('dialableNumberFor', {'id': 'gone'}), isNull);
    });

    test('a read failure answers null and logs a CARPLAY warn', () async {
      when(
        () => repository.getAppointmentById(any()),
      ).thenThrow(StateError('offline'));
      start();

      expect(await resultOf('dialableNumberFor', {'id': 'a1'}), isNull);
      expect(logger.calls.single.message, 'CARPLAY dialableNumberFor failed');
    });
  });

  group('the handler surface', () {
    test(
      'an unknown method answers notImplemented rather than throwing',
      () async {
        start();

        expect(await callFromSwift('somethingElse'), isNull);
        expect(logger.calls, isEmpty);
      },
    );

    test('start installs no handler off iOS', () async {
      start(isIos: false);

      expect(await callFromSwift('setAppointmentStatus', {'id': 'a1'}), isNull);
      verifyNever(
        () => repository.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      );
    });

    test('dispose clears the handler', () async {
      start().dispose();

      expect(await callFromSwift('setAppointmentStatus', {'id': 'a1'}), isNull);
      verifyNever(
        () => repository.updateAppointmentStatus(
          id: any(named: 'id'),
          status: any(named: 'status'),
        ),
      );
    });
  });

  group('snapshotChanged', () {
    test('pings Swift so the car re-reads the App Group', () async {
      final seen = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(carPlayChannelName), (
            call,
          ) async {
            seen.add(call);
            return null;
          });

      await start().notifySnapshotChanged();

      expect(seen.single.method, 'snapshotChanged');
    });

    test('is a no-op off iOS', () async {
      final seen = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(carPlayChannelName), (
            call,
          ) async {
            seen.add(call);
            return null;
          });

      await start(isIos: false).notifySnapshotChanged();

      expect(seen, isEmpty);
    });
  });
}
