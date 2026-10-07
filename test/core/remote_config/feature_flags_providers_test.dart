import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';

void main() {
  test('loading reads as the defaults (fail open)', () {
    final container = ProviderContainer(
      overrides: [
        featureFlagsStreamProvider.overrideWith(
          (ref) => StreamController<FeatureFlags>().stream,
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(featureFlagsProvider), FeatureFlags.defaults);
  });

  test('an error reads as the defaults (fail open)', () async {
    final container = ProviderContainer(
      overrides: [
        featureFlagsStreamProvider.overrideWith(
          (ref) => Stream<FeatureFlags>.error(Exception('x')),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(featureFlagsStreamProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(featureFlagsProvider), FeatureFlags.defaults);
  });

  test('a value passes through', () async {
    const paused = FeatureFlags(
      addressAutocomplete: true,
      presence: false,
      liveActivities: true,
      waveSync: true,
      minSupportedBuild: 0,
    );
    final container = ProviderContainer(
      overrides: [
        featureFlagsStreamProvider.overrideWith((ref) => Stream.value(paused)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(featureFlagsStreamProvider, (_, _) {});
    await pumpEventQueue();
    expect(container.read(featureFlagsProvider).presence, isFalse);
  });
}
