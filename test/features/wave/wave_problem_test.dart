import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';

void main() {
  group('WaveProblem.fromMap', () {
    test('parses a blocking problem with detail', () {
      final problem = WaveProblem.fromMap(<String, dynamic>{
        'field': 'name',
        'code': 'TOO_LONG',
        'severity': 'blocking',
        'detail': <String, dynamic>{'length': 218, 'cap': 200},
      });

      expect(problem, isNotNull);
      expect(problem!.field, 'name');
      expect(problem.code, WaveProblemCode.tooLong);
      expect(problem.isBlocking, isTrue);
      expect(problem.length, 218);
      expect(problem.cap, 200);
    });

    test('parses each server code', () {
      WaveProblemCode codeOf(String raw) => WaveProblem.fromMap(
        <String, dynamic>{'field': 'name', 'code': raw, 'severity': 'blocking'},
      )!.code;

      expect(codeOf('EMPTY'), WaveProblemCode.empty);
      expect(codeOf('TOO_LONG'), WaveProblemCode.tooLong);
      expect(codeOf('INVALID_EMAIL'), WaveProblemCode.invalidEmail);
      expect(codeOf('NOT_DIALABLE'), WaveProblemCode.notDialable);
    });

    test('an unknown code parses as unknown rather than dropping', () {
      // The vocabulary is server-owned, so a code added backend-side must stay
      // renderable — the same lesson WaveSyncBadge's unknown-state warn holds.
      final problem = WaveProblem.fromMap(<String, dynamic>{
        'field': 'phone',
        'code': 'SOMETHING_NEW',
        'severity': 'blocking',
        'detail': null,
      });

      expect(problem!.code, WaveProblemCode.unknown);
      expect(problem.isBlocking, isTrue);
    });

    test('an unknown severity is NOT treated as blocking', () {
      // Guessing upward strands a client Wave is happy with, which is the one
      // outcome the blocking/advisory split exists to avoid.
      final problem = WaveProblem.fromMap(<String, dynamic>{
        'field': 'phone',
        'code': 'NOT_DIALABLE',
        'severity': 'weird',
      });

      expect(problem!.isBlocking, isFalse);
    });

    test('advisory severity is not blocking', () {
      final problem = WaveProblem.fromMap(<String, dynamic>{
        'field': 'phone',
        'code': 'NOT_DIALABLE',
        'severity': 'advisory',
      });

      expect(problem!.isBlocking, isFalse);
    });

    test('tolerates a missing detail', () {
      final problem = WaveProblem.fromMap(<String, dynamic>{
        'field': 'name',
        'code': 'EMPTY',
        'severity': 'blocking',
      });

      expect(problem!.length, isNull);
      expect(problem.cap, isNull);
    });

    test('returns null for a non-map entry', () {
      expect(WaveProblem.fromMap('nope'), isNull);
      expect(WaveProblem.fromMap(null), isNull);
    });

    test('returns null when the field name is missing', () {
      expect(
        WaveProblem.fromMap(<String, dynamic>{
          'code': 'EMPTY',
          'severity': 'blocking',
        }),
        isNull,
      );
    });
  });

  group('WaveProblem.parseList', () {
    test('drops junk entries and keeps the parseable ones', () {
      final list = WaveProblem.parseList(<dynamic>[
        <String, dynamic>{
          'field': 'name',
          'code': 'EMPTY',
          'severity': 'blocking',
        },
        'junk',
        42,
      ]);

      expect(list, hasLength(1));
      expect(list.first.code, WaveProblemCode.empty);
    });

    test(
      'returns an empty list for null, the wrong type, and an empty array',
      () {
        expect(WaveProblem.parseList(null), isEmpty);
        expect(WaveProblem.parseList('nope'), isEmpty);
        expect(WaveProblem.parseList(<dynamic>[]), isEmpty);
      },
    );

    test('preserves server order', () {
      final list = WaveProblem.parseList(<dynamic>[
        <String, dynamic>{
          'field': 'name',
          'code': 'TOO_LONG',
          'severity': 'blocking',
        },
        <String, dynamic>{
          'field': 'phone',
          'code': 'NOT_DIALABLE',
          'severity': 'advisory',
        },
      ]);

      expect(list.map((p) => p.field), <String>['name', 'phone']);
    });
  });

  group('hasBlocking', () {
    test('is true when any problem blocks', () {
      final list = WaveProblem.parseList(<dynamic>[
        <String, dynamic>{
          'field': 'phone',
          'code': 'NOT_DIALABLE',
          'severity': 'advisory',
        },
        <String, dynamic>{
          'field': 'name',
          'code': 'EMPTY',
          'severity': 'blocking',
        },
      ]);

      expect(list.hasBlocking, isTrue);
    });

    test('is false for advisories alone', () {
      final list = WaveProblem.parseList(<dynamic>[
        <String, dynamic>{
          'field': 'phone',
          'code': 'NOT_DIALABLE',
          'severity': 'advisory',
        },
      ]);

      expect(list.hasBlocking, isFalse);
    });
  });
}
