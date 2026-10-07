import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/remote_config_service.dart';

class _MockRemoteConfig extends Mock implements FirebaseRemoteConfig {}

class _MockLogger extends Mock implements AppLogger {}

RemoteConfigValue _remote(String v) =>
    RemoteConfigValue(v.codeUnits, ValueSource.valueRemote);

Map<String, RemoteConfigValue> _values({bool wave = true}) => {
  for (final k in FeatureFlags.keys)
    k: _remote(k == 'min_supported_build' ? '0' : 'true'),
  'feature_wave_sync': _remote(wave ? 'true' : 'false'),
};

void main() {
  late _MockRemoteConfig rc;
  late _MockLogger logger;
  late StreamController<RemoteConfigUpdate> updates;

  setUp(() {
    rc = _MockRemoteConfig();
    logger = _MockLogger();
    updates = StreamController<RemoteConfigUpdate>.broadcast();
    when(() => rc.setDefaults(any())).thenAnswer((_) async {});
    when(() => rc.activate()).thenAnswer((_) async => true);
    when(() => rc.fetchAndActivate()).thenAnswer((_) async => true);
    when(() => rc.onConfigUpdated).thenAnswer((_) => updates.stream);
    when(() => rc.getAll()).thenReturn(_values());
  });

  tearDown(() => updates.close());

  test('emits the activated values first', () async {
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    expect(await service.watch().first, FeatureFlags.defaults);
    verify(
      () => rc.setDefaults(FeatureFlags.defaults.toRemoteConfigDefaults()),
    ).called(1);
  });

  test('a real-time update re-activates and emits again', () async {
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    final seen = <FeatureFlags>[];
    final sub = service.watch().listen(seen.add);
    await pumpEventQueue();
    when(() => rc.getAll()).thenReturn(_values(wave: false));
    updates.add(RemoteConfigUpdate({'feature_wave_sync'}));
    await pumpEventQueue();
    expect(seen.last.waveSync, isFalse);
    await sub.cancel();
  });

  test('a failed setDefaults/activate still emits, failing open', () async {
    when(() => rc.setDefaults(any())).thenThrow(Exception('boom'));
    when(() => rc.getAll()).thenReturn(const {});
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    expect(await service.watch().first, FeatureFlags.defaults);
    verify(
      () => logger.warn(any(that: startsWith('FLAGS')), any(), any()),
    ).called(greaterThanOrEqualTo(1));
  });

  test('a failed background fetch is logged, not thrown', () async {
    when(() => rc.fetchAndActivate()).thenThrow(Exception('offline'));
    final service = RemoteConfigService(remoteConfig: rc, logger: logger);
    await service.watch().first;
    await pumpEventQueue();
    verify(() => logger.warn('FLAGS fetch failed', any(), any())).called(1);
  });
}
