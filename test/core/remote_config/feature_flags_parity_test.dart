import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  final fixture = loadSharedFixture('feature_flags.json');

  test('in-code Remote Config defaults match the shared fixture', () {
    expect(FeatureFlags.defaults.toRemoteConfigDefaults(), fixture['defaults']);
  });

  for (final c in sharedCases(fixture, 'boolCases')) {
    test('bool $c', () {
      expectAsserts(c, ['expect']);
      expect(
        FeatureFlags.parseBool(
          c['raw'] as String,
          fallback: c['default'] as bool,
        ),
        c['expect'],
      );
    });
  }

  for (final c in sharedCases(fixture, 'intCases')) {
    test('int $c', () {
      expectAsserts(c, ['expect']);
      expect(
        FeatureFlags.parseInt(
          c['raw'] as String,
          fallback: c['default'] as int,
        ),
        c['expect'],
      );
    });
  }
}
