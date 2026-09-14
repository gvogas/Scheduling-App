import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/wave/data/wave_service.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/domain/wave_error_mapper.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';
import 'package:scheduling/l10n/l10n.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class _MockFunctions extends Mock implements FirebaseFunctions {}

class _MockCallable extends Mock implements HttpsCallable {}

class _MockResult extends Mock implements HttpsCallableResult<dynamic> {}

class _FakeHttpsCallableOptions extends Fake implements HttpsCallableOptions {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

FirebaseFunctionsException _fnEx(String code, String message) =>
    FirebaseFunctionsException(code: code, message: message);

// Pump a minimal app that provides l10n so widgets can resolve context.l10n.
Future<BuildContext> _pumpL10nContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

// ---------------------------------------------------------------------------
// WaveErrorMapper
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeHttpsCallableOptions());
  });

  group('WaveErrorMapper.map', () {
    test('passes through an existing WaveFailure unchanged', () {
      const failure = WaveAuthInvalid();
      expect(WaveErrorMapper.map(failure), same(failure));
    });

    test('wave/token-invalid → WaveAuthInvalid', () {
      expect(
        WaveErrorMapper.map(_fnEx('failed-precondition', 'wave/token-invalid')),
        isA<WaveAuthInvalid>(),
      );
    });

    test('wave/rate-limited message → WaveRateLimited', () {
      expect(
        WaveErrorMapper.map(_fnEx('failed-precondition', 'wave/rate-limited')),
        isA<WaveRateLimited>(),
      );
    });

    test('code resource-exhausted → WaveRateLimited', () {
      expect(
        WaveErrorMapper.map(_fnEx('resource-exhausted', 'some-message')),
        isA<WaveRateLimited>(),
      );
    });

    test('wave/network message → WaveNetwork', () {
      expect(
        WaveErrorMapper.map(_fnEx('unavailable', 'wave/network')),
        isA<WaveNetwork>(),
      );
    });

    test('code unavailable → WaveNetwork', () {
      expect(
        WaveErrorMapper.map(_fnEx('unavailable', 'other')),
        isA<WaveNetwork>(),
      );
    });

    test('wave/validation message → WaveValidation', () {
      expect(
        WaveErrorMapper.map(_fnEx('invalid-argument', 'wave/validation')),
        isA<WaveValidation>(),
      );
    });

    test('code invalid-argument → WaveValidation', () {
      expect(
        WaveErrorMapper.map(_fnEx('invalid-argument', 'something')),
        isA<WaveValidation>(),
      );
    });

    test('wave/not-bootstrapped → WaveValidation with notConnected reason', () {
      final result = WaveErrorMapper.map(
        _fnEx('failed-precondition', 'wave/not-bootstrapped'),
      );
      expect(result, isA<WaveValidation>());
      expect((result as WaveValidation).reason, 'notConnected');
    });

    test(
      'wave/business-ambiguous → WaveValidation with businessAmbiguous reason',
      () {
        final result = WaveErrorMapper.map(
          _fnEx('failed-precondition', 'wave/business-ambiguous'),
        );
        expect(result, isA<WaveValidation>());
        expect((result as WaveValidation).reason, 'businessAmbiguous');
      },
    );

    test(
      'wave/business-not-found → WaveValidation with no reason',
      () {
        final result = WaveErrorMapper.map(
          _fnEx('not-found', 'wave/business-not-found'),
        );
        expect(result, isA<WaveValidation>());
        expect((result as WaveValidation).reason, isNull);
      },
    );

    test('wave/not-admin → WaveUnknown', () {
      expect(
        WaveErrorMapper.map(_fnEx('permission-denied', 'wave/not-admin')),
        isA<WaveUnknown>(),
      );
    });

    test('wave/unknown message → WaveUnknown', () {
      expect(
        WaveErrorMapper.map(_fnEx('internal', 'wave/unknown')),
        isA<WaveUnknown>(),
      );
    });

    test('code internal → WaveUnknown', () {
      expect(
        WaveErrorMapper.map(_fnEx('internal', 'something')),
        isA<WaveUnknown>(),
      );
    });

    test('unknown error type → WaveUnknown', () {
      expect(
        WaveErrorMapper.map(Exception('unrelated')),
        isA<WaveUnknown>(),
      );
    });
  });

  // -------------------------------------------------------------------------
  // WaveConnection.fromMap
  // -------------------------------------------------------------------------

  group('WaveConnection.fromMap', () {
    test('parses businessId and businessName', () {
      final conn = WaveConnection.fromMap(const {
        'businessId': 'biz-1',
        'businessName': 'Acme Corp',
      });
      expect(conn.businessId, 'biz-1');
      expect(conn.businessName, 'Acme Corp');
    });

    test('defaults missing fields to empty string', () {
      final conn = WaveConnection.fromMap(const {});
      expect(conn.businessId, '');
      expect(conn.businessName, '');
    });

    test('reads the outbox counts', () {
      final conn = WaveConnection.fromMap(const {
        'businessId': 'biz-1',
        'pendingCount': 3,
        'failedCount': 1,
      });
      expect(conn.pendingCount, 3);
      expect(conn.failedCount, 1);
      expect(conn.hasPending, isTrue);
      expect(conn.hasFailed, isTrue);
    });

    test('an ABSENT count is null, not zero', () {
      // The counts are additive fields: a backend that predates them sends
      // nothing, and the server itself sends null when the aggregate read
      // failed. Both must stay distinguishable from an empty queue, which is
      // the one reading an admin acts on by NOT pressing Sync.
      final conn = WaveConnection.fromMap(const {'businessId': 'biz-1'});
      expect(conn.pendingCount, isNull);
      expect(conn.failedCount, isNull);
      expect(conn.hasPending, isFalse);
      expect(conn.hasFailed, isFalse);
    });

    test('an explicit zero is a real, empty queue', () {
      final conn = WaveConnection.fromMap(const {
        'businessId': 'biz-1',
        'pendingCount': 0,
        'failedCount': 0,
      });
      expect(conn.pendingCount, 0);
      expect(conn.hasPending, isFalse);
    });
  });

  group('WaveRetryResult.fromMap', () {
    test('parses a requeue that also pushed', () {
      final r = WaveRetryResult.fromMap(const {
        'requeued': 2,
        'scanned': 3,
        'pushed': 2,
      });
      expect(r.requeued, 2);
      expect(r.scanned, 3);
      expect(r.pushed, 2);
    });

    test('a missing `pushed` is null, not zero', () {
      // The requeue committed; only the optional push behind it failed. Zero
      // would read as "nothing reached Wave", which is a different and worse
      // claim than "we do not know yet".
      final r = WaveRetryResult.fromMap(const {'requeued': 4, 'scanned': 4});
      expect(r.requeued, 4);
      expect(r.pushed, isNull);
    });

    test('parses jobs that dead-lettered again on the push', () {
      final r = WaveRetryResult.fromMap(const {
        'requeued': 3,
        'scanned': 3,
        'pushed': 2,
        'failed': 1,
      });
      expect(r.failed, 1);
      expect(r.hasFailed, isTrue);
    });

    test('a missing `failed` is unknown, never "nothing failed"', () {
      // An older backend does not send it, and a drain that threw cannot know.
      // Reading either as zero would let the app claim a clean retry over an
      // outbox row that never moved.
      final r = WaveRetryResult.fromMap(const {'requeued': 4, 'scanned': 4});
      expect(r.failed, isNull);
      expect(r.hasFailed, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // WaveSyncSummary.fromMap
  // -------------------------------------------------------------------------

  group('WaveSyncSummary.fromMap', () {
    test('parses all numeric fields', () {
      final summary = WaveSyncSummary.fromMap(const {
        'totalCount': 100,
        'imported': 80,
        'updated': 15,
        'skippedArchived': 5,
        'pages': 3,
      });
      expect(summary.totalCount, 100);
      expect(summary.imported, 80);
      expect(summary.updated, 15);
      expect(summary.skippedArchived, 5);
      expect(summary.pages, 3);
    });

    test('defaults missing fields to zero', () {
      final summary = WaveSyncSummary.fromMap(const {});
      expect(summary.totalCount, 0);
      expect(summary.imported, 0);
      expect(summary.updated, 0);
      expect(summary.skippedArchived, 0);
      expect(summary.pages, 0);
    });
  });

  // -------------------------------------------------------------------------
  // WaveService
  // -------------------------------------------------------------------------

  group('WaveService', () {
    late _MockFunctions functions;
    late _MockCallable bootstrapCallable;
    late _MockCallable importCallable;
    late _MockCallable getConnectionCallable;
    late WaveService service;

    setUp(() {
      functions = _MockFunctions();
      bootstrapCallable = _MockCallable();
      importCallable = _MockCallable();
      getConnectionCallable = _MockCallable();
      when(
        () => functions.httpsCallable(
          any(that: equals('waveBootstrap')),
          options: any(named: 'options'),
        ),
      ).thenReturn(bootstrapCallable);
      when(
        () => functions.httpsCallable(
          any(that: equals('waveImportCustomers')),
          options: any(named: 'options'),
        ),
      ).thenReturn(importCallable);
      when(
        () => functions.httpsCallable(
          any(that: equals('waveGetConnection')),
          options: any(named: 'options'),
        ),
      ).thenReturn(getConnectionCallable);
      service = WaveService(functions: functions);
    });

    group('getConnection', () {
      test('returns WaveConnection when server reports connected', () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'connected': true,
          'businessId': 'biz-7',
          'businessName': 'Connected Co',
        });
        when(
          () => getConnectionCallable.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final conn = await service.getConnection();
        expect(conn, isNotNull);
        expect(conn!.businessId, 'biz-7');
        expect(conn.businessName, 'Connected Co');
      });

      test('returns null when server reports not connected', () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'connected': false,
          'businessId': '',
          'businessName': '',
        });
        when(
          () => getConnectionCallable.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        expect(await service.getConnection(), isNull);
      });

      test(
        'FirebaseFunctionsException → mapped WaveFailure is thrown',
        () async {
          when(
            () => getConnectionCallable.call<dynamic>(any<Object?>()),
          ).thenThrow(_fnEx('unavailable', 'wave/network'));

          await expectLater(
            () => service.getConnection(),
            throwsA(isA<WaveNetwork>()),
          );
        },
      );
    });

    group('bootstrap', () {
      test('parses WaveConnection from callable result', () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'businessId': 'biz-42',
          'businessName': 'Test Co',
        });
        when(
          () => bootstrapCallable.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final conn = await service.bootstrap();
        expect(conn.businessId, 'biz-42');
        expect(conn.businessName, 'Test Co');
      });

      test('sends an empty payload (business chosen server-side)', () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'businessId': 'biz-42',
          'businessName': 'Test Co',
        });
        when(
          () => bootstrapCallable.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        await service.bootstrap();

        final captured =
            verify(
                  () => bootstrapCallable.call<dynamic>(captureAny<Object?>()),
                ).captured.single
                as Map;
        expect(captured, isEmpty);
      });

      test(
        'FirebaseFunctionsException → mapped WaveFailure is thrown',
        () async {
          when(() => bootstrapCallable.call<dynamic>(any<Object?>())).thenThrow(
            _fnEx('resource-exhausted', 'wave/rate-limited'),
          );

          await expectLater(
            () => service.bootstrap(),
            throwsA(isA<WaveRateLimited>()),
          );
        },
      );

      test(
        'FirebaseFunctionsException(wave/token-invalid) → WaveAuthInvalid',
        () async {
          when(() => bootstrapCallable.call<dynamic>(any<Object?>())).thenThrow(
            _fnEx('failed-precondition', 'wave/token-invalid'),
          );

          await expectLater(
            () => service.bootstrap(),
            throwsA(isA<WaveAuthInvalid>()),
          );
        },
      );
    });

    group('syncCustomers', () {
      test('parses WaveSyncSummary from callable result', () async {
        final result = _MockResult();
        when(() => result.data).thenReturn(<String, dynamic>{
          'totalCount': 50,
          'imported': 30,
          'updated': 10,
          'skippedArchived': 10,
          'pages': 2,
        });
        when(
          () => importCallable.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final summary = await service.syncCustomers();
        expect(summary.totalCount, 50);
        expect(summary.imported, 30);
        expect(summary.updated, 10);
        expect(summary.skippedArchived, 10);
        expect(summary.pages, 2);
      });

      test(
        'FirebaseFunctionsException → mapped WaveFailure is thrown',
        () async {
          when(() => importCallable.call<dynamic>(any<Object?>())).thenThrow(
            _fnEx('unavailable', 'wave/network'),
          );

          await expectLater(
            () => service.syncCustomers(),
            throwsA(isA<WaveNetwork>()),
          );
        },
      );

      test('FirebaseFunctionsException(internal) → WaveUnknown', () async {
        when(() => importCallable.call<dynamic>(any<Object?>())).thenThrow(
          _fnEx('internal', 'wave/unknown'),
        );

        await expectLater(
          () => service.syncCustomers(),
          throwsA(isA<WaveUnknown>()),
        );
      });
    });
  });

  // -------------------------------------------------------------------------
  // WaveFailure.toLocalizedMessage — light widget test
  // -------------------------------------------------------------------------

  group('WaveFailure.toLocalizedMessage', () {
    testWidgets('WaveAuthInvalid yields non-empty string', (tester) async {
      final ctx = await _pumpL10nContext(tester);
      expect(
        const WaveAuthInvalid().toLocalizedMessage(ctx),
        isNotEmpty,
      );
    });

    testWidgets('WaveRateLimited yields non-empty string', (tester) async {
      final ctx = await _pumpL10nContext(tester);
      expect(
        const WaveRateLimited().toLocalizedMessage(ctx),
        isNotEmpty,
      );
    });

    testWidgets('WaveValidation yields non-empty string', (tester) async {
      final ctx = await _pumpL10nContext(tester);
      expect(
        const WaveValidation().toLocalizedMessage(ctx),
        isNotEmpty,
      );
    });

    testWidgets(
      'WaveValidation(reason: notConnected) yields non-empty string',
      (tester) async {
        final ctx = await _pumpL10nContext(tester);
        expect(
          const WaveValidation(reason: 'notConnected').toLocalizedMessage(ctx),
          isNotEmpty,
        );
      },
    );

    testWidgets(
      'WaveValidation(reason: businessAmbiguous) yields a distinct message',
      (tester) async {
        final ctx = await _pumpL10nContext(tester);
        final ambiguous = const WaveValidation(
          reason: 'businessAmbiguous',
        ).toLocalizedMessage(ctx);
        expect(ambiguous, isNotEmpty);
        // Must not fall back to the generic validation message.
        expect(
          ambiguous,
          isNot(const WaveValidation().toLocalizedMessage(ctx)),
        );
      },
    );

    testWidgets('WaveNetwork yields non-empty string', (tester) async {
      final ctx = await _pumpL10nContext(tester);
      expect(
        const WaveNetwork().toLocalizedMessage(ctx),
        isNotEmpty,
      );
    });

    testWidgets('WaveUnknown yields non-empty string', (tester) async {
      final ctx = await _pumpL10nContext(tester);
      expect(
        const WaveUnknown().toLocalizedMessage(ctx),
        isNotEmpty,
      );
    });
  });
}
