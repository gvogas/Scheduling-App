import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/branding/brand_logo.dart';

/// First-launch welcome screen; "Get Started" calls [onFinish]. The per-role
/// feature tours carry the product walkthrough once signed in.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({required this.onFinish, super.key});

  /// Marks onboarding complete and advances to the auth/splash flow.
  final Future<void> Function() onFinish;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  @override
  void initState() {
    super.initState();
    ref
        .read(analyticsServiceProvider)
        .logScreenView(AnalyticsScreens.onboarding);
    // Onboarding owns the native splash handoff on fresh install.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
      // NOTE: remove() only schedules a warm-up frame, which is a no-op on a
      // static screen — force one so the handoff actually happens.
      WidgetsBinding.instance.scheduleForcedFrame();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sp32,
                ),
                // Center when the content fits; scroll instead of overflowing
                // on short viewports or at large accessibility text scales.
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const BrandMark(size: 96, decorative: true),
                        const SizedBox(height: AppSpacing.sp16),
                        Text(
                          brandName,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sp24),
                        Text(
                          context.l10n.onboarding_welcomeTitle,
                          style: theme.textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.sp12),
                        Text(
                          context.l10n.onboarding_welcomeBody,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sp24),
              child: AnimatedLoadingButton(
                label: context.l10n.onboarding_getStarted,
                onPressed: widget.onFinish,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
