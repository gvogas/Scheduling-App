import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/remote_config/update_required_screen.dart';
import 'package:scheduling/features/settings/application/app_info_provider.dart';

/// Running build number, or null when it can't be parsed (fail open).
final appBuildNumberProvider = FutureProvider<int?>((ref) async {
  final info = await ref.watch(appInfoProvider.future);
  return int.tryParse(info.buildNumber);
});

bool isUpdateRequired({required int build, required int minSupported}) =>
    build < minSupported;

/// Swaps the app for [UpdateRequiredScreen] while this build is below `min_supported_build`.
class UpdateGate extends ConsumerWidget {
  const UpdateGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minSupported = ref.watch(
      featureFlagsProvider.select((f) => f.minSupportedBuild),
    );
    final build = ref.watch(appBuildNumberProvider).value;
    if (build != null &&
        isUpdateRequired(build: build, minSupported: minSupported)) {
      return const UpdateRequiredScreen();
    }
    return child;
  }
}
