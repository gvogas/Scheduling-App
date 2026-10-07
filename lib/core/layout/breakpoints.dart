import 'package:flutter/widgets.dart';

abstract final class Breakpoints {
  /// Two-pane threshold for master-detail + nav rail on genuinely large screens.
  static const double tablet = 840;

  /// Tablet-class cutoff on shortest side. Landscape phones stay narrow and
  /// use list + sheet instead of two-pane.
  static const double tabletShortestSide = 600;

  /// Narrow-phone width gate: below this, dense rows stack vertically.
  static const double compactWidth = 360;

  /// Large-text gate: above this text scale, dense rows stack as if narrow.
  static const double compactTextScale = 1.4;

  /// The composed text-scale cap `main()` applies app-wide.
  static const double maxTextScale = 2.2;

  /// Short-viewport height gate (e.g. landscape phones): sheets grow taller.
  static const double shortViewportHeight = 700;
}

extension ResponsiveContext on BuildContext {
  bool get isWide => MediaQuery.sizeOf(this).width >= Breakpoints.tablet;

  /// Any device held in landscape (wider than tall).
  bool get isLandscape =>
      MediaQuery.orientationOf(this) == Orientation.landscape;

  /// Use a side nav rail with multi-pane layout on tablets or any landscape
  /// device. Portrait phones stay single-column.
  bool get isSplitLayout => isWide || isLandscape;

  /// Two-pane master-detail is only for tablet-class devices. Landscape
  /// phones fall back to a single list + sheet, even though isSplitLayout is
  /// true for them too.
  bool get isTwoPane =>
      MediaQuery.sizeOf(this).shortestSide >= Breakpoints.tabletShortestSide;

  /// True when dense rows (cards, headers, action bars) should stack
  /// vertically instead of horizontally — either the phone is narrow, or the
  /// text scale is large enough that a horizontal row would overflow.
  bool get isCompact =>
      MediaQuery.sizeOf(this).width < Breakpoints.compactWidth ||
      MediaQuery.textScalerOf(this).scale(1) > Breakpoints.compactTextScale;

  /// Narrow phone by width alone (ignores text scale) — for layouts that only
  /// need to fold when the screen itself is narrow.
  bool get isNarrowWidth =>
      MediaQuery.sizeOf(this).width < Breakpoints.compactWidth;
}
