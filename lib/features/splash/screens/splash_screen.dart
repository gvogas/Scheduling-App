import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/animations/app_animation_constants.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/providers/firebase_providers.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/auth/data/auth_cache.dart';
import 'package:scheduling/features/splash/application/splash_controller.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:scheduling/shared/widgets/branding/brand_logo.dart';

/// Auth-gate splash that matches the native splash's visual handoff. An
/// optimistic fast path routes returning users instantly via AuthCache, a
/// live role stream upgrades admins, and account listeners handle
/// disabled/deleted accounts.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  bool _splashRemoved = false;
  bool _navigated = false;
  bool _useAuthoritative = false;

  @override
  void initState() {
    super.initState();
    // Register once (not in build to avoid repeated callbacks on rebuilds).
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _removeNativeSplashOnce(),
    );
    _decideRoute();
  }

  /// Optimistic fast path — a cache hit routes immediately as an employee; a
  /// miss falls back to the authoritative provider.
  Future<void> _decideRoute() async {
    // Held for the whole boot: both handlers run after an await, where `ref.read` throws.
    final logger = ref.read(loggerProvider);
    final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
    final cacheFuture = uid == null
        ? null
        : ref.read(authCacheProvider).loadIfMatch(uid).catchError((
            Object e,
            StackTrace st,
          ) {
            logger.warn('SPLASH auth cache load failed', e, st);
            return null;
          });

    // Await App Check activation before navigating to prevent request races.
    try {
      await ref.read(firebaseReadyProvider.future);
    } catch (e, st) {
      logger.warn('SPLASH firebase init failed', e, st);
    }
    if (!mounted || _navigated) return;

    if (uid == null) {
      _go(const SplashGoToLogin());
      return;
    }
    final cached = await cacheFuture;
    if (!mounted || _navigated) return;
    if (cached != null) {
      _go(SplashGoToCalendar(isAdmin: false, employeeId: cached.id));
      return;
    }
    setState(() => _useAuthoritative = true);
  }

  void _removeNativeSplashOnce() {
    if (_splashRemoved) return;
    _splashRemoved = true;
    FlutterNativeSplash.remove();
  }

  void _go(SplashDestination destination) {
    if (_navigated || !mounted) return;
    _navigated = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      switch (destination) {
        case SplashGoToLogin():
          nav.pushReplacementNamed(AppRoutes.login);
        case SplashGoToAccountSetup(:final firstName, :final lastName):
          nav.pushReplacementNamed(
            AppRoutes.accountSetup,
            arguments: AccountSetupArgs(
              firstName: firstName,
              lastName: lastName,
            ),
          );
        case SplashGoToChangePassword():
          nav.pushReplacementNamed(AppRoutes.changePassword);
        case SplashGoToCalendar(:final isAdmin, :final employeeId):
          nav.pushReplacementNamed(
            AppRoutes.mainCalendar,
            arguments: MainCalendarArgs(
              isAdmin: isAdmin,
              employeeId: employeeId,
            ),
          );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_useAuthoritative) {
      ref.listen<AsyncValue<SplashDestination>>(splashDestinationProvider, (
        _,
        next,
      ) {
        next.when(
          data: _go,
          error: (e, st) {
            ref.read(loggerProvider).warn('SPLASH resolution failed', e, st);
            _go(const SplashGoToLogin());
          },
          loading: () {},
        );
      });

      ref.read(splashDestinationProvider).whenData(_go);
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: scheme.primary,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: Center(child: _buildHero(theme))),
            Padding(
              padding: const EdgeInsets.only(bottom: 48, left: 48, right: 48),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.rFull),
                child: LinearProgressIndicator(
                  backgroundColor: scheme.onPrimary.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.onPrimary),
                  minHeight: 3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mascot mark (static and opaque, to line up with the native splash) plus
  /// a wordmark that fades in. Scroll-wrapped to handle text-scale overflow.
  Widget _buildHero(ThemeData theme) {
    Widget wordmark = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp24),
      child: Text(
        brandName,
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineSmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    if (!MediaQuery.disableAnimationsOf(context)) {
      wordmark = wordmark
          .animate()
          .fadeIn(duration: 450.ms, curve: Curves.easeOut)
          .slideY(
            begin: 0.4,
            end: 0,
            duration: 450.ms,
            curve: AppAnimationCurves.entrance,
          );
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandMark(size: 156, decorative: true),
          const SizedBox(height: AppSpacing.sp24),
          wordmark,
        ],
      ),
    );
  }
}
