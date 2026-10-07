import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/constants/app_store.dart';
import 'package:scheduling/core/launchers/external_uri_launcher.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Blocking screen for a build below `min_supported_build`. No way past it.
class UpdateRequiredScreen extends ConsumerWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.sp24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update, size: 48),
                const SizedBox(height: AppSpacing.sp16),
                Text(
                  l10n.common_updateRequiredTitle,
                  style: textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sp8),
                Text(
                  l10n.common_updateRequiredBody,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sp24),
                FilledButton(
                  onPressed: () => launchExternalUri(
                    context,
                    ref,
                    Uri.parse(kAppStoreUrl),
                    tag: 'LAUNCH-URL',
                    errorMessage: l10n.error_somethingWentWrongPleaseTryAgain,
                    analyticsAction: AnalyticsContactActions.appStore,
                  ),
                  child: Text(l10n.common_updateRequiredButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
