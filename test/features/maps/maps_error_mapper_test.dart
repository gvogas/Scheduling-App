import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/maps/data/maps_error_mapper.dart';
import 'package:scheduling/features/maps/domain/maps_failure.dart';

void main() {
  FirebaseFunctionsException fn(String code) =>
      FirebaseFunctionsException(message: code, code: code);

  group('MapsErrorMapper.map', () {
    test('passes a MapsFailure through unchanged', () {
      const failure = MapsFailureParse();
      expect(MapsErrorMapper.map(failure), same(failure));
    });

    test('resource-exhausted -> MapsFailureRateLimit', () {
      expect(
        MapsErrorMapper.map(fn('resource-exhausted')),
        isA<MapsFailureRateLimit>(),
      );
    });

    test(
      'unauthenticated / failed-precondition -> MapsFailureUnauthorized',
      () {
        expect(
          MapsErrorMapper.map(fn('unauthenticated')),
          isA<MapsFailureUnauthorized>(),
        );
        expect(
          MapsErrorMapper.map(fn('failed-precondition')),
          isA<MapsFailureUnauthorized>(),
        );
      },
    );

    test('a server feature-disabled refusal -> MapsFailurePaused', () {
      final error = FirebaseFunctionsException(
        message: 'feature-disabled',
        code: 'failed-precondition',
      );
      final failure = MapsErrorMapper.map(error);
      expect(failure, isA<MapsFailurePaused>());
      expect(failure.cause, same(error));
    });

    test('invalid-argument -> MapsFailureInvalidInput', () {
      expect(
        MapsErrorMapper.map(fn('invalid-argument')),
        isA<MapsFailureInvalidInput>(),
      );
    });

    test('an unmapped function code -> MapsFailureNetwork', () {
      expect(MapsErrorMapper.map(fn('internal')), isA<MapsFailureNetwork>());
    });

    test(
      'FormatException / JsonUnsupportedObjectError -> MapsFailureParse',
      () {
        expect(
          MapsErrorMapper.map(const FormatException('bad')),
          isA<MapsFailureParse>(),
        );
        expect(
          MapsErrorMapper.map(JsonUnsupportedObjectError(Object())),
          isA<MapsFailureParse>(),
        );
      },
    );

    test('an arbitrary error -> MapsFailureNetwork', () {
      expect(MapsErrorMapper.map(Exception('boom')), isA<MapsFailureNetwork>());
    });

    test('preserves the original error as the failure cause', () {
      final error = fn('internal');
      final failure = MapsErrorMapper.map(error) as MapsFailureNetwork;
      expect(failure.cause, same(error));
    });
  });
}
