import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scheduling/core/theme/extensions/app_card_style.dart';
import 'package:scheduling/core/theme/extensions/app_palette.dart';

// The four ThemeExtensions are re-exported so this stays THE token import.
export 'package:scheduling/core/theme/extensions/app_card_style.dart';
export 'package:scheduling/core/theme/extensions/app_mono_type.dart';
export 'package:scheduling/core/theme/extensions/app_palette.dart';
export 'package:scheduling/core/theme/extensions/app_status_colors.dart';

/// Sans family for all UI text. Bundled as a static-instance asset family.
const String kFontSans = 'InstrumentSans';

/// Mono family for numbers, times, counts and labels — via `AppMonoType`.
const String kFontMono = 'IBMPlexMono';

abstract final class AppColors {
  static const Color surface = Color(0xFFFFFFFF);

  // --- Redesign vocabulary (2026-07-30). Light roles. ---
  static const Color ink = Color(0xFF0B1A33);
  static const Color ink80 = Color(0xFF3E4C63);
  static const Color ink60 = Color(0xFF5A6B85);
  static const Color ink40 = Color(0xFF8A99B0);
  static const Color ink25 = Color(0xFFA6B2C4);
  static const Color ink15 = Color(0xFFC0CAD8);
  static const Color hairline = Color(0xFFDCE3EC);
  static const Color border = Color(0xFFE4E9F1);
  static const Color track = Color(0xFFEEF1F6);
  static const Color paper = Color(0xFFF1F4F9);
  static const Color paper2 = Color(0xFFE7ECF3);
  static const Color sheet = Color(0xFFF5F7FB);
  static const Color lockedPanel = Color(0xFFF7F9FC);
  static const Color surfaceHover = Color(0xFFFBFCFE);
  static const Color blue = Color(0xFF005CC8);
  static const Color navy = Color(0xFF00256B);
  static const Color blueTint = Color(0xFFEFF4FC);
  static const Color blueTintHover = Color(0xFFE2ECFA);
  static const Color blueTint2 = Color(0xFFE4F0FF);
  static const Color green = Color(0xFF0E9B6E);
  static const Color greenText = Color(0xFF0B7A57);
  static const Color greenFill = Color(0xFFE6F5EF);
  static const Color amber = Color(0xFFE08A00);
  static const Color amberText = Color(0xFF8A5C00);
  static const Color amberFill = Color(0xFFFFF4E5);
  static const Color red = Color(0xFFD61F3A);

  /// Overdue sits between amber and red on purpose — it is "late", not
  /// "failed", and `error` red already means cancelled on the same chart.
  static const Color orange = Color(0xFFF54A00);
  static const Color redText = Color(0xFFB01730);
  static const Color redFill = Color(0xFFFDE8EC);

  // --- Redesign vocabulary. Dark roles. ---
  static const Color darkPage = Color(0xFF0C1220);
  static const Color darkCard = Color(0xFF151E2E);
  static const Color darkSheet = Color(0xFF101827);
  static const Color darkSheetRow = Color(0xFF18212F);
  static const Color darkNotice = Color(0xFF1A2436);
  static const Color darkTextPrimary = Color(0xFFEEF2F8);
  static const Color darkTextSecondary = Color(0xFFB3C0D4);
  static const Color darkTextTertiary = Color(0xFF8593A9);
  static const Color darkTextMuted = Color(0xFF5C6A80);
  static const Color darkBlueText = Color(0xFF4B90F7);
  static const Color darkBlueFill = Color(0xFF1D6BE8);
  static const Color darkBlueOnTint = Color(0xFF7FB2FA);
  static const Color darkNavy = Color(0xFF1D4ED8);
  static const Color darkGreen = Color(0xFF1FA97A);
  static const Color darkGreenText = Color(0xFF4FD8A6);
  static const Color darkAmber = Color(0xFFF1A83C);
  static const Color darkRed = Color(0xFFFF6076);
  static const Color darkRedText = Color(0xFFFF8A99);
  static const Color darkOrange = Color(0xFFFF8A4C);

  /// The ten crew colours, stored as light-theme ARGB; see [crewColorOf].
  static const List<Color> crewPalette = [
    crewDefault, // blue
    Color(0xFF7A3FF2), // violet
    Color(0xFF0E9B6E), // green
    Color(0xFFE08A00), // amber
    Color(0xFF00A5C4), // cyan
    Color(0xFFC43F8E), // magenta
    Color(0xFFD61F3A), // red
    Color(0xFF5A6B85), // slate
    Color(0xFF8A5A2B), // brown
    Color(0xFF7A8F1F), // olive
  ];

  /// The decorative hue ring on the "custom colour" swatch; theme-independent.
  static const List<Color> decorativeHueRing = [
    Color(0xFFEF4444), // red
    Color(0xFFF59E0B), // amber
    Color(0xFF10B981), // emerald
    Color(0xFF06B6D4), // cyan
    Color(0xFF6366F1), // indigo
    Color(0xFFEC4899), // pink
    Color(0xFFEF4444), // back to red
  ];

  /// Fallback for an employee with no stored colour; must be in [crewPalette].
  static const Color crewDefault = blue;

  /// The three calendar holiday-marker hues, in the gaps [crewPalette] leaves.
  static const Color holidayStatutory = Color(0xFF0F766E);
  static const Color holidayOrthodox = Color(0xFF8E3DAE);
  static const Color holidayConstruction = Color(0xFFB45309);

  static const Color darkHolidayStatutory = Color(0xFF3FBFB0);
  static const Color darkHolidayOrthodox = Color(0xFFC482E8);
  // NOT `darkAmber`: that is dark crew amber, and the two would twin.
  static const Color darkHolidayConstruction = Color(0xFFEA802E);

  /// The nine nav-drawer row hues, deliberately decoupled from [crewPalette].
  static const Color navCalendar = Color(0xFF005CC8);
  static const Color navDayRoute = Color(0xFFD61F3A);
  static const Color navLiveMap = Color(0xFF00A5C4);
  static const Color navTeam = Color(0xFF0E9B6E);
  static const Color navClients = Color(0xFF7A3FF2);
  static const Color navDashboard = Color(0xFFE08A00);
  static const Color navHistory = Color(0xFFC43F8E);
  static const Color navSettings = Color(0xFF5A6B85);
  static const Color navOverdueReview = Color(0xFF8A5A2B);
}

/// Resolves a STORED employee colour int to the colour this theme renders.
Color crewColorOf(ThemeData theme, int storedArgb) {
  final palette = theme.palette;
  final mapped = palette.crewOverride[storedArgb];
  if (mapped != null) return mapped;
  if (palette.crewCustomLift == 0) return Color(storedArgb);
  final hsl = HSLColor.fromColor(Color(storedArgb));
  return hsl
      .withLightness((hsl.lightness + palette.crewCustomLift).clamp(0.0, 0.92))
      .withSaturation((hsl.saturation * 0.9).clamp(0.0, 1.0))
      .toColor();
}

/// Foreground on a crew-coloured surface; dark tints it with its own hue.
Color avatarForegroundFor(ThemeData theme, Color background) {
  final inkLightness = theme.palette.avatarInkLightness;
  if (inkLightness == null) return contrastingForegroundFor(background);
  final hsl = HSLColor.fromColor(background);
  return hsl
      .withSaturation((hsl.saturation * 0.7).clamp(0.0, 1.0))
      .withLightness(inkLightness)
      .toColor();
}

abstract final class AppSpacing {
  static const double sp4 = 4;
  static const double sp8 = 8;
  static const double sp12 = 12;
  static const double sp16 = 16;
  static const double sp24 = 24;
  static const double sp32 = 32;

  static const double cardPaddingY = 12;
}

/// The corner-radius scale — a complete rung ladder; don't prune rungs.
abstract final class AppRadius {
  static const double r8 = 8;
  static const double r12 = 12;
  static const double r16 = 16;
  static const double r20 = 20;
  static const double r24 = 24;
  static const double rFull = 999;

  static const double rCard = 15;
  static const double rPanel = 18;
  static const double rSheet = 26;
  static const double rDialog = 22;
  static const double rFab = 20;
  static const double rRow = 13;
}

abstract final class AppShadow {
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> sheet = [
    BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, -4)),
  ];

  /// Tight lift under a small selected control (segmented pill).
  static const List<BoxShadow> pill = [
    BoxShadow(color: Color(0x1A000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
}

abstract final class AppDuration {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration shimmer = Duration(milliseconds: 1200);
}

abstract final class AppMotion {
  /// Shared open/close curve for `showModalBottomSheet` across the app.
  static const AnimationStyle sheetStyle = AnimationStyle(
    duration: Duration(milliseconds: 300),
    reverseDuration: Duration(milliseconds: 240),
    curve: Cubic(0.2, 0.9, 0.25, 1),
  );

  /// Cross-fade duration when switching hub tabs (persistent shell fades between mounted tabs).
  static const Duration tabSwitch = Duration(milliseconds: 220);

  static const Curve emphasized = Cubic(0.2, 0.9, 0.25, 1);
  static const Duration popIn = Duration(milliseconds: 200);
  static const Duration riseInShort = Duration(milliseconds: 240);

  /// Total in-hold-out lifetime of a notice (`06-sheets-and-dialogs.md` §11).
  static const Duration noticeCycle = Duration(milliseconds: 2600);
}

/// Black or white, whichever contrasts with [background].
Color contrastingForegroundFor(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark
    ? Colors.white
    : Colors.black;

/// Status-bar icon style for a screen with no `AppBar`, read off [surface].
SystemUiOverlayStyle overlayStyleFor(Color surface) =>
    ThemeData.estimateBrightnessForColor(surface) == Brightness.dark
    ? SystemUiOverlayStyle.light
    : SystemUiOverlayStyle.dark;

/// Surface-card decoration shared across settings. Light/dark treatment
/// comes from [AppCardStyle].
BoxDecoration appCardDecoration(
  ThemeData theme, {
  double radius = AppRadius.r12,
  Color? color,
}) {
  final style = theme.cardStyle;
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: style.shadow,
    border: style.border,
  );
}
