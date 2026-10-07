import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/remote_config_service.dart';

final remoteConfigServiceProvider = Provider<RemoteConfigService>(
  (ref) => RemoteConfigService(logger: ref.watch(loggerProvider)),
);

final featureFlagsStreamProvider = StreamProvider<FeatureFlags>(
  (ref) => ref.watch(remoteConfigServiceProvider).watch(),
);

/// The flags every gate reads. Loading and error are the defaults: fail open.
final featureFlagsProvider = Provider<FeatureFlags>(
  (ref) => ref.watch(featureFlagsStreamProvider).value ?? FeatureFlags.defaults,
);
