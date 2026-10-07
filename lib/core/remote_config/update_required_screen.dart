import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/constants/app_store.dart';
import 'package:scheduling/core/launchers/external_uri_launcher.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Blocking screen for a build below `min_supported_build`. No way past it.
class UpdateRequiredScreen extends ConsumerStatefulWidget {
  const UpdateRequiredScreen({super.key});

  @override
  ConsumerState<UpdateRequiredScreen> createState() =>
      _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends ConsumerState<UpdateRequiredScreen> {
  bool _launchFailed = false;

  // The gate replaces NoticeListener, so the launcher's notice has no overlay.
  Future<void> _openStore() async {
    final opened = await launchExternalUri(
      context,
      ref,
      Uri.parse(kAppStoreUrl),
      tag: 'LAUNCH-URL',
      errorMessage: context.l10n.error_somethingWentWrongPleaseTryAgain,
      analyticsAction: AnalyticsContactActions.appStore,
    );
    if (mounted) setState(() => _launchFailed = !opened);
  }

  @override
  Widget build(BuildContext context) {
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
                if (_launchFailed) ...[
                  Text(
                    l10n.error_somethingWentWrongPleaseTryAgain,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sp12),
                ],
                FilledButton(
                  onPressed: _openStore,
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
