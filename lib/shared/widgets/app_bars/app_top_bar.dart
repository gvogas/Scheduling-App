import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/shared/widgets/primitives/app_back_button.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// The standard screen header: a large title on the page colour, ghost
/// controls beside it, and no coloured app bar.
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({
    required this.title,
    super.key,
    this.onBack,
    this.actions,
    this.bottom,
    this.compact = false,
  });

  final String title;

  /// When non-null, a back chevron is shown at the start of the controls row.
  final VoidCallback? onBack;
  final List<Widget>? actions;

  /// Optional row rendered beneath the header.
  final PreferredSizeWidget? bottom;

  /// Drops the title onto the controls row for short (landscape) viewports.
  final bool compact;

  static const double _topGap = AppSpacing.sp24;
  static const double _titleGap = 6;
  static const double _bottomGap = 14;

  /// The 48px tap floor every ghost control in the row already clears.
  static const double _controlsRow = kGhostTapTarget;

  static const double _displayTitleLine = 28.6; // displayLarge, 26 / 1.1

  /// An upper bound, not the rendered height: `Scaffold` takes its content top
  /// from the laid-out header and only ever CLIPS what this understates, and it
  /// adds `padding.top` itself, so the safe-area inset is deliberately absent.
  @override
  Size get preferredSize => Size.fromHeight(
    _topGap +
        _controlsRow * Breakpoints.maxTextScale +
        (compact
            ? 0
            : _titleGap + _displayTitleLine * Breakpoints.maxTextScale) +
        _bottomGap +
        (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    assert(
      compact == context.isLandscape,
      'AppTopBar.compact must equal context.isLandscape. '
      'Pass compact: context.isLandscape at the call site.',
    );
    final theme = Theme.of(context);
    final surface = theme.scaffoldBackgroundColor;
    // No AppBar means nothing sets the system overlay style for this screen.
    final overlay = overlayStyleFor(surface);
    final titleLine = _TitleLine(
      title: title,
      style: compact
          ? theme.textTheme.titleLarge
          : theme.textTheme.displayLarge,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlay,
      child: ColoredBox(
        color: surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.sp16,
                MediaQuery.paddingOf(context).top + _topGap,
                AppSpacing.sp16,
                0,
              ),
              child: _ControlsRow(
                compact: compact,
                onBack: onBack,
                actions: actions,
                title: titleLine,
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: _titleGap),
              // Yields rather than overflowing when the row outgrows the bound.
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sp16,
                  ),
                  child: titleLine,
                ),
              ),
            ],
            // Outside the gutter padding: the search pill carries its own.
            ?bottom,
            const SizedBox(height: _bottomGap),
          ],
        ),
      ),
    );
  }
}

class _ControlsRow extends StatelessWidget {
  const _ControlsRow({
    required this.compact,
    required this.onBack,
    required this.actions,
    required this.title,
  });

  final bool compact;
  final VoidCallback? onBack;
  final List<Widget>? actions;
  final Widget title;

  @override
  Widget build(BuildContext context) {
    final leading = onBack == null ? null : _BackChevron(onTap: onBack!);
    final trailing = actions == null
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final action in actions!) Flexible(child: action)],
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppTopBar._controlsRow),
      // A non-flex row child lays out unbounded, so the controls must flex.
      child: compact
          ? Row(
              children: [
                ?leading,
                Expanded(child: title),
                ?trailing,
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                leading ?? const SizedBox.shrink(),
                if (trailing != null) Flexible(child: trailing),
              ],
            ),
    );
  }
}

class _BackChevron extends StatelessWidget {
  const _BackChevron({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Nudged left so the glyph, not its tile, lines up with the gutter.
    return Transform.translate(
      offset: const Offset(-14, 0),
      child: SizedBox(
        width: AppTopBar._controlsRow,
        height: AppTopBar._controlsRow,
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(foregroundColor: scheme.onSurface),
          ),
          child: AppBackButton(onTap: onTap),
        ),
      ),
    );
  }
}

class _TitleLine extends StatelessWidget {
  const _TitleLine({required this.title, required this.style});

  final String title;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      Text(title, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
}
