import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/branding/brand_logo.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

/// First-launch intro carousel — swipeable slides with a page-dot indicator,
/// and "Get Started"/"Skip" actions that both call [onFinish].
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({required this.onFinish, super.key});

  /// Marks onboarding complete and advances to the auth/splash flow.
  final Future<void> Function() onFinish;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _controller = PageController();
  int _index = 0;

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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _advance(int count) {
    if (_index >= count - 1) {
      widget.onFinish();
      return;
    }
    _controller.nextPage(duration: AppDuration.normal, curve: Curves.easeOut);
  }

  void _back() {
    _controller.previousPage(
      duration: AppDuration.normal,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final slides = <_OnboardingSlide>[
      _OnboardingSlide(
        icon: FontAwesomeIcons.calendarCheck,
        title: context.l10n.onboarding_slide1Title,
        body: context.l10n.onboarding_slide1Body,
      ),
      _OnboardingSlide(
        icon: FontAwesomeIcons.userGroup,
        title: context.l10n.onboarding_slide2Title,
        body: context.l10n.onboarding_slide2Body,
      ),
      _OnboardingSlide(
        icon: FontAwesomeIcons.screwdriverWrench,
        title: context.l10n.onboarding_slide3Title,
        body: context.l10n.onboarding_slide3Body,
      ),
    ];
    final isLast = _index == slides.length - 1;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            _OnboardingTopBar(showSkip: !isLast, onSkip: widget.onFinish),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                onPageChanged: (i) => setState(() => _index = i),
                itemCount: slides.length,
                itemBuilder: (context, index) =>
                    _SlideView(slide: slides[index]),
              ),
            ),
            SmoothPageIndicator(
              controller: _controller,
              count: slides.length,
              effect: ExpandingDotsEffect(
                dotHeight: 8,
                dotWidth: 8,
                activeDotColor: scheme.primary,
                dotColor: scheme.outlineVariant,
              ),
            ),
            _buildActions(context, isLast, slides.length),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context, bool isLast, int slideCount) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.sp24),
      child: Row(
        children: [
          if (_index > 0) ...[
            TextButton(
              onPressed: _back,
              child: Text(context.l10n.onboarding_back),
            ),
            const SizedBox(width: AppSpacing.sp8),
          ],
          Expanded(
            child: AnimatedLoadingButton(
              label: isLast
                  ? context.l10n.onboarding_getStarted
                  : context.l10n.onboarding_next,
              onPressed: () => _advance(slideCount),
            ),
          ),
        ],
      ),
    );
  }
}

/// Onboarding chrome: the brand mark + wordmark on the left, a "Skip" action on
/// the right (hidden on the final slide, where "Get Started" supersedes it).
class _OnboardingTopBar extends StatelessWidget {
  const _OnboardingTopBar({required this.showSkip, required this.onSkip});

  final bool showSkip;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp8,
        AppSpacing.sp8,
        0,
      ),
      child: Row(
        children: [
          const BrandMark(size: 32, decorative: true),
          const SizedBox(width: AppSpacing.sp8),
          Expanded(
            child: Text(
              brandName,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          if (showSkip)
            TextButton(
              onPressed: onSkip,
              child: Text(context.l10n.onboarding_skip),
            ),
        ],
      ),
    );
  }
}

class _OnboardingSlide {
  const _OnboardingSlide({
    required this.icon,
    required this.title,
    required this.body,
  });

  // FontAwesome icons are FaIconData (a distinct type from IconData in v11).
  final FaIconData icon;
  final String title;
  final String body;
}

class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide});

  final _OnboardingSlide slide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp32),
      // Center when the content fits; scroll instead of overflowing on short
      // (landscape-phone) viewports or at large accessibility text scales.
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.r16),
                ),
                alignment: Alignment.center,
                child: FaIcon(slide.icon, size: 40, color: scheme.primary),
              ),
              const SizedBox(height: AppSpacing.sp24),
              Text(
                slide.title,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sp12),
              Text(
                slide.body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
