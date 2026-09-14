import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/features/wave/data/wave_service.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';

class _MockFunctions extends Mock implements FirebaseFunctions {}

class _MockCallable extends Mock implements HttpsCallable {}

class _MockResult extends Mock implements HttpsCallableResult<dynamic> {}

class _FakeHttpsCallableOptions extends Fake implements HttpsCallableOptions {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeHttpsCallableOptions()));

  late _MockFunctions functions;
  late _MockCallable callable;
  late WaveService service;

  void bind(String name) {
    when(
      () => functions.httpsCallable(
        any(that: equals(name)),
        options: any(named: 'options'),
      ),
    ).thenReturn(callable);
  }

  setUp(() {
    functions = _MockFunctions();
    callable = _MockCallable();
    service = WaveService(functions: functions);
  });

  group('bootstrap', () {
    test('parses the connection payload', () async {
      bind('waveBootstrap');
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{
        'businessId': 'biz-1',
        'businessName': 'Acme Plumbing',
      });
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final conn = await service.bootstrap();

      expect(conn.businessId, 'biz-1');
      expect(conn.businessName, 'Acme Plumbing');
    });

    test(
      'tolerates an Android Map<dynamic, dynamic> callable payload',
      () async {
        bind('waveBootstrap');
        final result = _MockResult();
        // Android callables hand back Map<dynamic, dynamic>, not
        // Map<String, dynamic> — the loose cast must survive it.
        when(() => result.data).thenReturn(<dynamic, dynamic>{
          'businessId': 'biz-2',
          'businessName': 'Beta Co',
        });
        when(
          () => callable.call<dynamic>(any<Object?>()),
        ).thenAnswer((_) async => result);

        final conn = await service.bootstrap();

        expect(conn.businessId, 'biz-2');
      },
    );

    test('maps a callable failure to a WaveFailure', () async {
      bind('waveBootstrap');
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenThrow(Exception('boom'));

      await expectLater(service.bootstrap(), throwsA(isA<WaveFailure>()));
    });
  });

  group('getConnection', () {
    test('returns null when the payload is not connected', () async {
      bind('waveGetConnection');
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{'connected': false});
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      expect(await service.getConnection(), isNull);
    });

    test('parses a connected payload', () async {
      bind('waveGetConnection');
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{
        'connected': true,
        'businessId': 'biz-9',
        'businessName': 'Gamma Ltd',
      });
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final conn = await service.getConnection();

      expect(conn, isNotNull);
      expect(conn!.businessId, 'biz-9');
    });
  });

  group('syncCustomers', () {
    test('parses the import summary', () async {
      bind('waveImportCustomers');
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{
        'totalCount': 10,
        'imported': 7,
        'updated': 2,
        'skippedArchived': 1,
        'pages': 3,
      });
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final summary = await service.syncCustomers();

      expect(summary.totalCount, 10);
      expect(summary.imported, 7);
      expect(summary.updated, 2);
      expect(summary.skippedArchived, 1);
      expect(summary.pages, 3);
    });
  });

  group('retryFailedJobs', () {
    // The only WaveService method with no service-level test, and its own
    // comment calls it "the only way back" from a dead-lettered job — a job
    // that never retries on its own and surfaces only as an error badge on the
    // client.

    test('parses the retry counts', () async {
      bind('waveRetryFailedJobs');
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{
        'requeued': 2,
        'scanned': 3,
        'pushed': 2,
        'failed': 0,
      });
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final retry = await service.retryFailedJobs();

      expect(retry.requeued, 2);
      expect(retry.scanned, 3);
      expect(retry.pushed, 2);
      expect(retry.failed, 0);
    });

    test('a missing pushed/failed reads as NULL, not as zero', () async {
      // Null means the follow-up push failed or was skipped; the requeue still
      // committed, so the jobs are queued and will drain. Reading it as 0
      // would tell the admin nothing went through when everything did.
      bind('waveRetryFailedJobs');
      final result = _MockResult();
      when(
        () => result.data,
      ).thenReturn(<String, dynamic>{'requeued': 1, 'scanned': 1});
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final retry = await service.retryFailedJobs();

      expect(retry.requeued, 1);
      expect(retry.pushed, isNull);
      expect(retry.failed, isNull);
    });

    test('tolerates an Android Map<dynamic, dynamic> payload', () async {
      // The `as Map?` convention — never `as Map<String, dynamic>?`.
      bind('waveRetryFailedJobs');
      final result = _MockResult();
      when(() => result.data).thenReturn(<dynamic, dynamic>{
        'requeued': 4,
        'scanned': 4,
      });
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      expect((await service.retryFailedJobs()).requeued, 4);
    });

    test('an empty payload is all-zero rather than a throw', () async {
      bind('waveRetryFailedJobs');
      final result = _MockResult();
      when(() => result.data).thenReturn(null);
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      final retry = await service.retryFailedJobs();

      expect(retry.requeued, 0);
      expect(retry.scanned, 0);
    });

    test('maps a callable failure to a WaveFailure', () async {
      bind('waveRetryFailedJobs');
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenThrow(Exception('nope'));

      await expectLater(
        service.retryFailedJobs(),
        throwsA(isA<WaveFailure>()),
      );
    });

    test('maps an unparseable payload to a WaveFailure too', () async {
      // The second try/catch: a malformed response must not escape as a raw
      // TypeError into the Settings widget's generic catch.
      bind('waveRetryFailedJobs');
      final result = _MockResult();
      when(() => result.data).thenReturn(<String, dynamic>{'requeued': 'two'});
      when(
        () => callable.call<dynamic>(any<Object?>()),
      ).thenAnswer((_) async => result);

      await expectLater(
        service.retryFailedJobs(),
        throwsA(isA<WaveFailure>()),
      );
    });
  });
}
