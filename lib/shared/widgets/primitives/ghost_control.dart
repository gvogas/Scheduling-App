import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// Painted size of a ghost tile — a VISUAL size, never a hit area.
const double kGhostTile = 38;

/// The tap floor every ghost control clears, inside its own gesture detector.
const double kGhostTapTarget = 48;

/// How a ghost control is painted.
enum GhostTone {
  /// Surface fill, `outlineVariant` border, `onSurface` content.
  ghost,

  /// Surface fill behind a primary border, with primary content.
  accent,

  /// Inverted: `onSurface` fill and page-colour content.
  selected,

  /// Primary fill with `onPrimary` content.
  active,
}

/// The app's one ghost control: an `rFull` tile of [kGhostTile] painted inside
/// a [kGhostTapTarget] tap floor.
///
/// The floor lives INSIDE the `InkWell`, which is the whole reason this widget
/// exists — the six hand-spelled copies it replaced reserved 48px of layout
/// around a gesture area that was only ever the painted tile, so half the
/// chrome in the app was a 38px target.
class GhostControl extends StatelessWidget {
  /// A round icon tile — the menu, crew filter, day route and filter buttons.
  const GhostControl.icon({
    required this.onTap,
    required IconData this.icon,
    required String this.tooltip,
    this.tone = GhostTone.ghost,
    this.iconSize = 19,
    this.showBadge = false,
    super.key,
  }) : label = null,
       iconColor = null,
       child = null;

  /// A labelled pill, optionally led by an icon — the Calendar pill and the
  /// clients filter chips.
  const GhostControl.pill({
    required this.onTap,
    required String this.label,
    this.icon,
    this.iconColor,
    this.iconSize = 15,
    this.tooltip,
    this.tone = GhostTone.ghost,
    super.key,
  }) : showBadge = false,
       child = null;

  /// A tile around a control that brings its own glyph and press feedback —
  /// today only the filter sheet's `AppBackButton`.
  const GhostControl.wrapping({
    required this.onTap,
    required Widget this.child,
    this.tone = GhostTone.ghost,
    super.key,
  }) : icon = null,
       iconColor = null,
       iconSize = 0,
       label = null,
       tooltip = null,
       showBadge = false;

  final VoidCallback onTap;
  final IconData? icon;

  /// Overrides the tone's content colour for the glyph alone — the Calendar
  /// pill keeps its calendar icon in `scheme.primary` beside an `onSurface`
  /// label.
  final Color? iconColor;
  final double iconSize;
  final String? label;
  final String? tooltip;
  final GhostTone tone;

  /// The clients Filter button's "a filter is on" dot.
  final bool showBadge;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = _contentColor(theme);
    final control = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        highlightColor: theme.palette.blueTintPressed,
        // The 48px floor sits inside the gesture detector; the tile it centres
        // is smaller on purpose.
        child: label == null
            ? SizedBox(
                width: kGhostTapTarget,
                height: kGhostTapTarget,
                child: Center(child: _tile(theme, content)),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kGhostTapTarget),
                // widthFactor pins the box to the tile: a bare Center fills
                // the width it is offered, which floated the pill mid-row.
                child: Center(widthFactor: 1, child: _tile(theme, content)),
              ),
      ),
    );
    return tooltip == null
        ? control
        : Tooltip(message: tooltip, child: control);
  }

  /// The painted tile. `Ink` rather than a nested `Material`, so the `InkWell`
  /// above it still draws its splash ON TOP of the fill.
  Widget _tile(ThemeData theme, Color content) {
    // Sized OUTSIDE the Ink: a decoration's border pads its child, so sizing
    // the child instead would grow the tile by the border width.
    final tile = _ink(theme, content);
    return label == null
        ? SizedBox(width: kGhostTile, height: kGhostTile, child: tile)
        : ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kGhostTile),
            child: tile,
          );
  }

  Widget _ink(ThemeData theme, Color content) => Ink(
    decoration: BoxDecoration(
      color: _fillColor(theme),
      borderRadius: BorderRadius.circular(AppRadius.rFull),
      border: _border(theme),
    ),
    child: label == null
        ? Center(child: child ?? _glyph(content))
        : Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: AppSpacing.sp8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: iconSize, color: iconColor ?? content),
                  const SizedBox(width: AppSpacing.sp8),
                ],
                Flexible(
                  child: Text(
                    label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kFontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: content,
                    ),
                  ),
                ),
              ],
            ),
          ),
  );

  Widget _glyph(Color content) {
    final glyph = Icon(icon, size: iconSize, color: iconColor ?? content);
    if (!showBadge) return glyph;
    return Stack(
      alignment: Alignment.center,
      children: [
        glyph,
        Positioned(
          top: 7,
          right: 7,
          child: DecoratedBox(
            decoration: BoxDecoration(color: content, shape: BoxShape.circle),
            child: const SizedBox(width: 6, height: 6),
          ),
        ),
      ],
    );
  }

  Color _fillColor(ThemeData theme) => switch (tone) {
    GhostTone.ghost || GhostTone.accent => theme.colorScheme.surface,
    GhostTone.selected => theme.colorScheme.onSurface,
    GhostTone.active => theme.colorScheme.primary,
  };

  Color _contentColor(ThemeData theme) => switch (tone) {
    GhostTone.ghost => theme.colorScheme.onSurface,
    GhostTone.accent => theme.colorScheme.primary,
    GhostTone.selected => theme.scaffoldBackgroundColor,
    GhostTone.active => theme.colorScheme.onPrimary,
  };

  BoxBorder? _border(ThemeData theme) => switch (tone) {
    GhostTone.ghost => Border.all(color: theme.colorScheme.outlineVariant),
    GhostTone.accent => Border.all(
      color: theme.colorScheme.primary,
      width: 1.5,
    ),
    GhostTone.selected => null,
    GhostTone.active => Border.all(color: theme.colorScheme.primary),
  };
}
