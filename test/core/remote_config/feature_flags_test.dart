import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';

RemoteConfigValue _remote(String v) =>
    RemoteConfigValue(v.codeUnits, ValueSource.valueRemote);
RemoteConfigValue _static() => RemoteConfigValue(null, ValueSource.valueStatic);

void main() {
  test('defaults: every feature on, no build blocked', () {
    const d = FeatureFlags.defaults;
    expect(d.addressAutocomplete, isTrue);
    expect(d.presence, isTrue);
    expect(d.liveActivities, isTrue);
    expect(d.waveSync, isTrue);
    expect(d.minSupportedBuild, 0);
  });

  test('reads published remote values', () {
    final flags = FeatureFlags.fromValues({
      'feature_address_autocomplete': _remote('true'),
      'feature_presence': _remote('false'),
      'feature_live_activities': _remote('true'),
      'feature_wave_sync': _remote('false'),
      'min_supported_build': _remote('93'),
    });
    expect(flags.presence, isFalse);
    expect(flags.waveSync, isFalse);
    expect(flags.minSupportedBuild, 93);
  });

  test('a static value (no default installed) fails OPEN, not closed', () {
    final flags = FeatureFlags.fromValues({
      for (final key in FeatureFlags.keys) key: _static(),
    });
    expect(flags, FeatureFlags.defaults);
  });

  test('a malformed remote value fails OPEN, not closed', () {
    final flags = FeatureFlags.fromValues({
      'feature_address_autocomplete': _remote('yes'),
      'feature_presence': _remote(''),
      'feature_live_activities': _remote('0'),
      'feature_wave_sync': _remote('off'),
      'min_supported_build': _remote('1.5'),
    });
    expect(flags, FeatureFlags.defaults);
  });

  test('a missing key fails open', () {
    expect(FeatureFlags.fromValues(const {}), FeatureFlags.defaults);
  });
}
