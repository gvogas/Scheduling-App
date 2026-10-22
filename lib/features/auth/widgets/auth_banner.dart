import 'package:flutter/material.dart';
import 'package:scheduling/core/animations/app_animation_constants.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

/// Error by default; `info` carries a non-failure handoff such as "your account is ready".
enum AuthBannerTone { error, info }

/// Inline banner for the auth forms: fade/size-animates a colored box in when
/// [message] is non-null and collapses it when cleared. A live region, so a
/// screen reader announces the message without the person hunting for it.
class AuthBanner extends StatelessWidget {
  const AuthBanner({
    required this.message,
    this.tone = AuthBannerTone.error,
    super.key,
  });

  final String? message;
  final AuthBannerTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = this.message;
    final isError = tone == AuthBannerTone.error;
    final fill = isError ? scheme.errorContainer : scheme.primaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onPrimaryContainer;

    return AnimatedSwitcher(
      duration: AppAnimationDurations.banner,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          alignment: AlignmentDirectional.topStart,
          child: child,
        ),
      ),
      child: message == null
          ? const SizedBox.shrink(key: ValueKey('banner_none'))
          : Padding(
              key: ValueKey('banner_${tone.name}_$message'),
              padding: const EdgeInsets.only(top: AppSpacing.sp12),
              child: Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.sp12),
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(AppRadius.r8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isError ? Icons.error_outline : Icons.info_outline,
                        color: isError ? scheme.error : foreground,
                        size: 16,
                      ),
                      const SizedBox(width: AppSpacing.sp8),
                      Expanded(
                        child: Text(
                          message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
