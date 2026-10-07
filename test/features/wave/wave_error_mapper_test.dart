import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/wave/domain/wave_error_mapper.dart';
import 'package:scheduling/features/wave/domain/wave_failure.dart';

void main() {
  FirebaseFunctionsException fn({required String message, String code = 'x'}) =>
      FirebaseFunctionsException(message: message, code: code);

  group('WaveErrorMapper.map', () {
    test('passes a WaveFailure through unchanged', () {
      const failure = WaveAuthInvalid();
      expect(WaveErrorMapper.map(failure), same(failure));
    });

    test('maps an arbitrary error to WaveUnknown', () {
      expect(WaveErrorMapper.map(Exception('boom')), isA<WaveUnknown>());
    });

    test('wave/token-invalid message -> WaveAuthInvalid', () {
      expect(
        WaveErrorMapper.map(fn(message: 'wave/token-invalid')),
        isA<WaveAuthInvalid>(),
      );
    });

    test('rate limiting via message or code -> WaveRateLimited', () {
      expect(
        WaveErrorMapper.map(fn(message: 'wave/rate-limited')),
        isA<WaveRateLimited>(),
      );
      expect(
        WaveErrorMapper.map(fn(message: 'other', code: 'resource-exhausted')),
        isA<WaveRateLimited>(),
      );
    });

    test('network via message or code -> WaveNetwork', () {
      expect(
        WaveErrorMapper.map(fn(message: 'wave/network')),
        isA<WaveNetwork>(),
      );
      expect(
        WaveErrorMapper.map(fn(message: 'other', code: 'unavailable')),
        isA<WaveNetwork>(),
      );
    });

    test('validation via message or code -> WaveValidation', () {
      expect(
        WaveErrorMapper.map(fn(message: 'wave/validation')),
        isA<WaveValidation>(),
      );
      expect(
        WaveErrorMapper.map(fn(message: 'other', code: 'invalid-argument')),
        isA<WaveValidation>(),
      );
    });

    test('wave/not-bootstrapped -> WaveValidation(notConnected)', () {
      final result = WaveErrorMapper.map(fn(message: 'wave/not-bootstrapped'));
      expect(result, isA<WaveValidation>());
      expect((result as WaveValidation).reason, 'notConnected');
    });

    test('wave/business-ambiguous -> WaveValidation(businessAmbiguous)', () {
      final result = WaveErrorMapper.map(
        fn(message: 'wave/business-ambiguous'),
      );
      expect(result, isA<WaveValidation>());
      expect((result as WaveValidation).reason, 'businessAmbiguous');
    });

    test('wave/business-not-found -> WaveValidation(reason: null)', () {
      final result = WaveErrorMapper.map(
        fn(message: 'wave/business-not-found'),
      );
      expect(result, isA<WaveValidation>());
      expect((result as WaveValidation).reason, isNull);
    });

    test('a server feature-disabled refusal -> WavePaused', () {
      expect(
        WaveErrorMapper.map(
          fn(message: 'feature-disabled', code: 'failed-precondition'),
        ),
        isA<WavePaused>(),
      );
      // Any other failed-precondition keeps its old mapping.
      expect(
        WaveErrorMapper.map(fn(message: 'other', code: 'failed-precondition')),
        isA<WaveUnknown>(),
      );
    });

    test('wave/not-admin -> WaveUnknown', () {
      expect(
        WaveErrorMapper.map(fn(message: 'wave/not-admin')),
        isA<WaveUnknown>(),
      );
    });

    test('internal code -> WaveUnknown', () {
      expect(
        WaveErrorMapper.map(fn(message: 'other', code: 'internal')),
        isA<WaveUnknown>(),
      );
    });
  });
}
