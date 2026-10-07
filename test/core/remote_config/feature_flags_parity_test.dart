import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  test('in-code Remote Config defaults match the shared fixture', () {
    expect(
      FeatureFlags.defaults.toRemoteConfigDefaults(),
      loadSharedFixture('feature_flags.json')['defaults'],
    );
  });
}
