import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'package:scheduling/core/animations/app_animation_constants.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/shared/widgets/branding/brand_logo.dart';

/// The auth screens' outer chrome: the gradient hero block and the shell that
/// rides a form card over it.
///
/// One of the three files that replaced `auth_form_widgets.dart`, which held
/// eight public classes — the one genuine "one class per file" violation in
/// the tree, and the file `AuthPasswordField` (a credential surface) was
/// buried in. Its siblings are `auth_text.dart` and `auth_fields.dart`.

/// The gradient block at the top of an auth screen. [thin] drops the brand
/// mark for the secondary screens, which lead with their own title.
class AuthHero {
  const AuthHero({
    required this.title,
    required this.subtitle,
    this.thin = false,
  });

  final String title;
  final String subtitle;
  final bool thin;
}

/// Outer shell for auth forms: keyboard dismissal, standard padding,
/// [AutofillGroup] for OS password managers. With a [hero] the form rides in a
/// lifted card overlapping the gradient block; without one the child sits
/// straight on the surface.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({required this.child, this.hero, super.key});

  /// How far the card overlaps the hero block above it.
  static const double _cardLift = 28;

  final Widget child;
  final AuthHero? hero;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hero = this.hero;
    // Gradient.colors is on the base class, so this reads the token without
    // caring which gradient shape the palette carries.
    final heroInk = theme.palette.heroGradient.colors.last;

    // The hero is full-bleed behind the status bar and these screens have no
    // app bar, so nothing else sets the overlay style. Derived from the colour
    // actually behind the bar, not the theme brightness.
    final statusBarSurface = hero == null ? scheme.surface : heroInk;
    final overlay = overlayStyleFor(statusBarSurface);

    var card = child;
    if (hero != null) {
      card = DecoratedBox(
        decoration: appCardDecoration(
          theme,
          radius: AppRadius.r20,
          color: scheme.surface,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sp24),
          child: child,
        ),
      );
    }

    // Fades and slides the whole form in on entrance. Under reduce-motion it
    // skips straight to the end state instead of animating.
    Widget content = AutofillGroup(child: card);
    if (!MediaQuery.disableAnimationsOf(context)) {
      content = content
          .animate()
          .fadeIn(duration: 360.ms, curve: Curves.easeOut)
          .slideY(
            begin: 0.04,
            end: 0,
            duration: 360.ms,
            curve: AppAnimationCurves.entrance,
          );
    }

    Widget body = Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.sp24,
        hero == null ? AppSpacing.sp32 : 0,
        AppSpacing.sp24,
        AppSpacing.sp32,
      ),
      // Caps the width for tablets and landscape — this is a no-op on
      // phones narrower than 440.
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: content,
        ),
      ),
    );
    if (hero != null) {
      // Lifts the card over the hero. A negative EdgeInsets would assert, and
      // the extra slack this leaves lands harmlessly at the scroll bottom.
      body = Transform.translate(
        offset: const Offset(0, -_cardLift),
        child: body,
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Scaffold(
          backgroundColor: scheme.surface,
          body: SafeArea(
            // The hero paints behind the status bar and pads itself instead.
            top: hero == null,
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hero != null)
                    _AuthHeroBlock(hero: hero, bottomGap: _cardLift),
                  body,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthHeroBlock extends StatelessWidget {
  const _AuthHeroBlock({required this.hero, required this.bottomGap});

  final AuthHero hero;
  final double bottomGap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gradient = theme.palette.heroGradient;
    final foreground = contrastingForegroundFor(gradient.colors.last);
    final topInset = MediaQuery.paddingOf(context).top;

    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.sp24,
          topInset + (hero.thin ? AppSpacing.sp24 : AppSpacing.sp32),
          AppSpacing.sp24,
          AppSpacing.sp24 + bottomGap,
        ),
        child: Column(
          children: [
            if (!hero.thin) ...[
              const BrandMark(),
              const SizedBox(height: AppSpacing.sp16),
            ],
            Text(
              hero.title,
              style: theme.textTheme.headlineLarge?.copyWith(color: foreground),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sp4),
            Text(
              hero.subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foreground.withValues(alpha: 0.82),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
