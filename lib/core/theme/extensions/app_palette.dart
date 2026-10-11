import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';

/// Stored (light) crew ARGB -> the colour the dark theme renders instead.
/// Lifted ~15% in lightness per `09-dark-theme.md`.
const Map<int, Color> _darkCrewOverride = {
  0xFF005CC8: Color(0xFF4B90F7),
  0xFF7A3FF2: Color(0xFF9B6BFF),
  0xFF0E9B6E: Color(0xFF2BC48E),
  0xFFE08A00: Color(0xFFF1A83C),
  0xFF00A5C4: Color(0xFF35C2DE),
  0xFFC43F8E: Color(0xFFE45FA8),
  0xFFD61F3A: Color(0xFFFF6076),
  0xFF5A6B85: Color(0xFF8593A9),
  0xFF8A5A2B: Color(0xFFC9985A),
  0xFF7A8F1F: Color(0xFFB9CC45),
};

/// Every design role Material's ColorScheme has no slot for.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.textBody,
    required this.textTertiary,
    required this.textMuted,
    required this.textFaint,
    required this.decorFaint,
    required this.primaryAccent,
    required this.blueTintPressed,
    required this.sheetRow,
    required this.lockedPanel,
    required this.lockedPanelBorder,
    required this.track,
    required this.dangerFill,
    required this.onDangerFill,
    required this.noticeMint,
    required this.noticeInfo,
    required this.noticeRed,
    required this.heroGradient,
    required this.crewOverride,
    required this.crewCustomLift,
    required this.avatarInkLightness,
    required this.holidayStatutory,
    required this.holidayOrthodox,
    required this.holidayConstruction,
  });

  final Color textBody; // body copy — Ink 80
  final Color textTertiary; // labels — Ink 40
  final Color textMuted; // captions, inactive — Ink 25
  final Color textFaint; // chevrons, placeholder — Ink 15
  final Color decorFaint; // grabber, decorative strokes
  final Color primaryAccent; // blue for TEXT and ICONS (lifted in dark)
  final Color blueTintPressed; // pressed state on tinted icon buttons
  final Color sheetRow; // row card inside a sheet
  final Color lockedPanel; // read-only field group
  final Color lockedPanelBorder;
  final Color track; // progress-bar tracks
  final Color dangerFill; // saturated destructive button fill
  final Color onDangerFill;
  final Color noticeMint; // toast dots — the toast surface is dark in
  final Color noticeInfo; // BOTH themes, so these four are identical
  final Color noticeRed;
  final Gradient heroGradient;
  final Map<int, Color> crewOverride;
  final double crewCustomLift;
  final double? avatarInkLightness; // null = plain contrast foreground

  // Plain fields, not a `HolidaySet` map: `lerp` would snap a map mid-animation (ADR-0161).
  final Color holidayStatutory;
  final Color holidayOrthodox;
  final Color holidayConstruction;

  static const light = AppPalette(
    textBody: AppColors.ink80,
    textTertiary: AppColors.ink40,
    textMuted: AppColors.ink25,
    textFaint: AppColors.ink15,
    decorFaint: AppColors.ink15,
    primaryAccent: AppColors.blue,
    blueTintPressed: AppColors.blueTintHover,
    sheetRow: Color(0xFFFFFFFF),
    lockedPanel: AppColors.lockedPanel,
    lockedPanelBorder: Color(0x120B1A33),
    track: AppColors.track,
    dangerFill: AppColors.red,
    onDangerFill: Color(0xFFFFFFFF),
    noticeMint: Color(0xFF7FE3C0),
    noticeInfo: Color(0xFF7FCBFF),
    noticeRed: Color(0xFFFF9AA8),
    heroGradient: LinearGradient(
      begin: Alignment(-0.5, -1),
      end: Alignment(0.5, 1),
      colors: [AppColors.blue, AppColors.navy],
    ),
    crewOverride: {},
    crewCustomLift: 0,
    avatarInkLightness: null,
    holidayStatutory: AppColors.holidayStatutory,
    holidayOrthodox: AppColors.holidayOrthodox,
    holidayConstruction: AppColors.holidayConstruction,
  );

  static const dark = AppPalette(
    textBody: Color(0xFFC5D0E2),
    textTertiary: AppColors.darkTextTertiary,
    textMuted: AppColors.darkTextMuted,
    textFaint: Color(0xFF3A465A),
    decorFaint: Color(0xFF2C3648),
    primaryAccent: AppColors.darkBlueText,
    blueTintPressed: Color(0x334B90F7),
    sheetRow: AppColors.darkSheetRow,
    lockedPanel: Color(0xFF121B2A),
    lockedPanelBorder: Color(0x12FFFFFF),
    track: Color(0x14FFFFFF),
    dangerFill: AppColors.red,
    onDangerFill: Color(0xFFFFFFFF),
    noticeMint: Color(0xFF7FE3C0),
    noticeInfo: Color(0xFF7FCBFF),
    noticeRed: Color(0xFFFF9AA8),
    heroGradient: LinearGradient(
      begin: Alignment(-0.5, -1),
      end: Alignment(0.5, 1),
      colors: [AppColors.darkBlueFill, AppColors.darkNavy],
    ),
    crewOverride: _darkCrewOverride,
    crewCustomLift: 0.18,
    avatarInkLightness: 0.07,
    holidayStatutory: AppColors.darkHolidayStatutory,
    holidayOrthodox: AppColors.darkHolidayOrthodox,
    holidayConstruction: AppColors.darkHolidayConstruction,
  );

  @override
  AppPalette copyWith({
    Color? textBody,
    Color? textTertiary,
    Color? textMuted,
    Color? textFaint,
    Color? decorFaint,
    Color? primaryAccent,
    Color? blueTintPressed,
    Color? sheetRow,
    Color? lockedPanel,
    Color? lockedPanelBorder,
    Color? track,
    Color? dangerFill,
    Color? onDangerFill,
    Color? noticeMint,
    Color? noticeInfo,
    Color? noticeRed,
    Gradient? heroGradient,
    Map<int, Color>? crewOverride,
    double? crewCustomLift,
    double? avatarInkLightness,
    Color? holidayStatutory,
    Color? holidayOrthodox,
    Color? holidayConstruction,
  }) => AppPalette(
    textBody: textBody ?? this.textBody,
    textTertiary: textTertiary ?? this.textTertiary,
    textMuted: textMuted ?? this.textMuted,
    textFaint: textFaint ?? this.textFaint,
    decorFaint: decorFaint ?? this.decorFaint,
    primaryAccent: primaryAccent ?? this.primaryAccent,
    blueTintPressed: blueTintPressed ?? this.blueTintPressed,
    sheetRow: sheetRow ?? this.sheetRow,
    lockedPanel: lockedPanel ?? this.lockedPanel,
    lockedPanelBorder: lockedPanelBorder ?? this.lockedPanelBorder,
    track: track ?? this.track,
    dangerFill: dangerFill ?? this.dangerFill,
    onDangerFill: onDangerFill ?? this.onDangerFill,
    noticeMint: noticeMint ?? this.noticeMint,
    noticeInfo: noticeInfo ?? this.noticeInfo,
    noticeRed: noticeRed ?? this.noticeRed,
    heroGradient: heroGradient ?? this.heroGradient,
    crewOverride: crewOverride ?? this.crewOverride,
    crewCustomLift: crewCustomLift ?? this.crewCustomLift,
    avatarInkLightness: avatarInkLightness ?? this.avatarInkLightness,
    holidayStatutory: holidayStatutory ?? this.holidayStatutory,
    holidayOrthodox: holidayOrthodox ?? this.holidayOrthodox,
    holidayConstruction: holidayConstruction ?? this.holidayConstruction,
  );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      textBody: Color.lerp(textBody, other.textBody, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textFaint: Color.lerp(textFaint, other.textFaint, t)!,
      decorFaint: Color.lerp(decorFaint, other.decorFaint, t)!,
      primaryAccent: Color.lerp(primaryAccent, other.primaryAccent, t)!,
      blueTintPressed: Color.lerp(blueTintPressed, other.blueTintPressed, t)!,
      sheetRow: Color.lerp(sheetRow, other.sheetRow, t)!,
      lockedPanel: Color.lerp(lockedPanel, other.lockedPanel, t)!,
      lockedPanelBorder: Color.lerp(
        lockedPanelBorder,
        other.lockedPanelBorder,
        t,
      )!,
      track: Color.lerp(track, other.track, t)!,
      dangerFill: Color.lerp(dangerFill, other.dangerFill, t)!,
      onDangerFill: Color.lerp(onDangerFill, other.onDangerFill, t)!,
      noticeMint: Color.lerp(noticeMint, other.noticeMint, t)!,
      noticeInfo: Color.lerp(noticeInfo, other.noticeInfo, t)!,
      noticeRed: Color.lerp(noticeRed, other.noticeRed, t)!,
      heroGradient: Gradient.lerp(heroGradient, other.heroGradient, t)!,
      // Discrete data, not colours — snap at the midpoint.
      crewOverride: t < 0.5 ? crewOverride : other.crewOverride,
      crewCustomLift:
          lerpDouble(crewCustomLift, other.crewCustomLift, t) ?? crewCustomLift,
      avatarInkLightness: t < 0.5
          ? avatarInkLightness
          : other.avatarInkLightness,
      holidayStatutory: Color.lerp(
        holidayStatutory,
        other.holidayStatutory,
        t,
      )!,
      holidayOrthodox: Color.lerp(holidayOrthodox, other.holidayOrthodox, t)!,
      holidayConstruction: Color.lerp(
        holidayConstruction,
        other.holidayConstruction,
        t,
      )!,
    );
  }
}

extension AppPaletteX on ThemeData {
  AppPalette get palette =>
      extension<AppPalette>() ??
      (brightness == Brightness.dark ? AppPalette.dark : AppPalette.light);
}
