# P1 Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the redesign's foundation — new colour/type tokens with a full dark variant, the two new font families, the destination-type restructure that shrinks the hub to four tabs, the right-anchored end drawer, the reusable header pair, and the restyled toast — so P2–P7 have tokens and chrome to build on.

**Architecture:** Three phases, each independently shippable. **Phase A** rewrites the theme layer additively (new token vocabulary alongside the old, then flip, then delete) so the app compiles and runs at every commit. **Phase B** replaces the single `AdaptiveDestination` enum with a sealed `AppDestination` family split into `HubTab` (4 IndexedStack panes) and `PushedDestination` (plain routes), which makes "select a non-tab" a compile error instead of an `IndexedStack` range crash. **Phase C** builds the new chrome (header pair, drawer, toast) on top of both.

**Tech Stack:** Flutter 3.44.1 / Dart ^3.10.7 · Riverpod 3 · Firebase (Auth, Firestore, Storage, App Check) · showcaseview 5.x · gen_l10n (EN + FR)

## Global Constraints

Every task's requirements implicitly include this section.

- **Never branch on `isDark` / `Theme.of(context).brightness` for styling.** Every light↔dark divergence is a `ThemeExtension` field set in both `.light` and `.dark`, read through a `theme.<x>` getter. The only legitimate `isDark` is mode-*selection* UI, and there it must use `isDarkMode(themeMode, MediaQuery.platformBrightnessOf(context))`.
- **Never use static `AppColors.*` in a `build()` method** — map through `Theme.of(context).colorScheme` or a theme extension getter.
- **`ColorScheme.tertiary` is the warning palette (amber) in both themes — never use it for success.** Success reads `theme.statusColors.success`.
- **Touch targets ≥ 48×48 logical pixels.** The handoff's 38×38 icon buttons, 32×32 day circles and ~34px chips are *visual* sizes; pad the hit region to 48×48. Never shrink a hit area to match a mock.
- **No hardcoded status-bar or home-indicator insets.** Use `MediaQuery.paddingOf(context).top` / `SafeArea`; every bottom-floating element adds `padding.bottom`. A literal `62` or `42` inset anywhere is a bug.
- **Design px heights are 1.0-scale minimums.** Heights derive from scaled text, never fixed. Enforcement is a 0.8–2.0 text-scale sweep at 375×667.
- **Every new animation collapses to instant** when `MediaQuery.disableAnimationsOf(context)` is true.
- **Localisation:** every new string is a paired EN + FR ARB key with an `@key` metadata block in `lib/l10n/app_en.arb`. `required-resource-attributes: true` makes `flutter gen-l10n` fail on a bare key. A repo hook regenerates l10n on ARB edits — **do not run `flutter gen-l10n` manually**. Key naming `feature_keyName`; this plan uses the (currently empty) `nav_` bucket.
- **Load-bearing invariants unchanged:** `showActions` required with a `false` default · unique FAB `heroTag`s across tabs *and* pushed routes · `PrimaryScrollScope` on every simultaneously-mounted scrollable · `isSplitLayout` (rail — being deleted) vs `isTwoPane` (master-detail — survives) never conflated · no `LayoutBuilder` under `IntrinsicHeight` · offline fail-fast on entity writes · notices not SnackBars.
- **Save `.dart` files as UTF-8 without a BOM.**
- **Commit at the end of every task.** Commit messages must contain no double quotes (PowerShell 5.1 native-arg quoting mangles them).
- **Run `flutter analyze` after every task**; the repo's baseline is ~3 info lints and zero errors/warnings. Filter with `flutter analyze 2>&1 | grep -E "error -|warning -"`.

---

# Phase A — Theme foundation

No navigation changes. Each task compiles and passes tests on its own.

## Task A1: Bundle Instrument Sans and IBM Plex Mono

**Files:**
- Create: `assets/fonts/InstrumentSans-Regular.ttf`, `assets/fonts/InstrumentSans-Medium.ttf`, `assets/fonts/InstrumentSans-SemiBold.ttf`, `assets/fonts/InstrumentSans-Bold.ttf`, `assets/fonts/IBMPlexMono-Medium.ttf`, `assets/fonts/IBMPlexMono-SemiBold.ttf`, `assets/fonts/IBMPlexMono-Bold.ttf`
- Modify: `pubspec.yaml` (append two families to the existing `fonts:` block, lines 130–142)

**Interfaces:**
- Consumes: nothing
- Produces: font family names `InstrumentSans` and `IBMPlexMono`, resolvable via `TextStyle(fontFamily: ...)`

> **Why static instances, not variable fonts:** Flutter's pubspec `weight:` mapping selects a *file* per weight. A variable font declared once cannot have its `wght` axis driven from pubspec, so a variable Instrument Sans would render one weight everywhere. Reject any download that yields `InstrumentSans[wdth,wght].ttf`.

> **Why IBM Plex Mono 700 is bundled** even though the program constraint said "Mono 500/600": the numeral ramp (dashboard hero, KPI value, section metric, sub-metric) is all `700`. Flutter does not synthesise bold — it falls back to the nearest bundled weight — so without the 700 file every dashboard numeral silently renders at 600. This is a deliberate amendment to the constraint, ~100 KB.

- [x] **Step 1: Download the seven static TTFs**

Both families are SIL Open Font License, freely bundleable. These exact URLs were verified 2026-07-30 (HTTP 200, valid TrueType, no `fvar` table). Run from the repo root:

```bash
curl -fL -o assets/fonts/IBMPlexMono-Medium.ttf   "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Medium.ttf"
curl -fL -o assets/fonts/IBMPlexMono-SemiBold.ttf "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-SemiBold.ttf"
curl -fL -o assets/fonts/IBMPlexMono-Bold.ttf     "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/IBMPlexMono-Bold.ttf"
curl -fL -o assets/fonts/InstrumentSans-Regular.ttf  "https://raw.githubusercontent.com/Instrument/instrument-sans/master/fonts/ttf/InstrumentSans-Regular.ttf"
curl -fL -o assets/fonts/InstrumentSans-Medium.ttf   "https://raw.githubusercontent.com/Instrument/instrument-sans/master/fonts/ttf/InstrumentSans-Medium.ttf"
curl -fL -o assets/fonts/InstrumentSans-SemiBold.ttf "https://raw.githubusercontent.com/Instrument/instrument-sans/master/fonts/ttf/InstrumentSans-SemiBold.ttf"
curl -fL -o assets/fonts/InstrumentSans-Bold.ttf     "https://raw.githubusercontent.com/Instrument/instrument-sans/master/fonts/ttf/InstrumentSans-Bold.ttf"
```

> **Why Instrument Sans comes from upstream, not `google/fonts`.** The Google Fonts mirror ships Instrument Sans **variable-only** (`ofl/instrumentsans/InstrumentSans[wdth,wght].ttf`, axes `wdth,wght`) — unusable here per the note above. The upstream `Instrument/instrument-sans` repo ships pre-instanced statics at `fonts/ttf/`. That directory also contains `InstrumentSansCondensed-*` and `InstrumentSansSemiCondensed-*`, which are a different width instance — **do not download those**. The fontsource CDN was checked and rejected: it publishes only `.woff`/`.woff2`.

Expected sizes (verified): InstrumentSans Regular 86,232 · Medium 86,924 · SemiBold 87,004 · Bold 87,272 · IBMPlexMono Medium 136,704 · SemiBold 140,216 · Bold 137,784. **Total 744 KiB.**

> **Harmless metadata quirk, don't "fix" it.** The 500/600 files use legacy per-weight family naming (name ID 1 is "Instrument Sans Medium", not "Instrument Sans"). Flutter resolves fonts by the pubspec `family:`/`weight:` mapping, not the embedded name table, so this has no effect.

- [x] **Step 2: Verify every file is a real TTF, not an HTML error page**

```bash
for f in assets/fonts/InstrumentSans-*.ttf assets/fonts/IBMPlexMono-*.ttf; do printf '%s ' "$f"; head -c 4 "$f" | od -An -tx1; done
```

Expected: every line shows `00 01 00 00` (TrueType) or `4f 54 54 4f` (OTTO). Any file whose first bytes are `3c 21 44 4f` (`<!DO`) is a failed download. Also check sizes — anything under 20 KB is a failure:

```bash
ls -l assets/fonts/
```

- [x] **Step 3: Append the two families to `pubspec.yaml`**

Leave the existing Inter block in place (it is deleted in Task A5). Add after it, at the same indent:

```yaml
    - family: InstrumentSans
      fonts:
        - asset: assets/fonts/InstrumentSans-Regular.ttf
          weight: 400
        - asset: assets/fonts/InstrumentSans-Medium.ttf
          weight: 500
        - asset: assets/fonts/InstrumentSans-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/InstrumentSans-Bold.ttf
          weight: 700
    - family: IBMPlexMono
      fonts:
        - asset: assets/fonts/IBMPlexMono-Medium.ttf
          weight: 500
        - asset: assets/fonts/IBMPlexMono-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/IBMPlexMono-Bold.ttf
          weight: 700
```

- [x] **Step 4: Verify the bundle resolves**

```bash
flutter pub get
```

Then confirm nothing regressed (this task is purely additive — no widget reads the new families yet):

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
```

Expected: no output.

- [x] **Step 5: Commit**

```bash
git add assets/fonts pubspec.yaml
git commit -m "feat(p1): bundle Instrument Sans and IBM Plex Mono static weights"
```

---

## Task A2: Add the new token vocabulary alongside the old

**Files:**
- Modify: `lib/core/theme/design_tokens.dart` (currently 373 lines)
- Test: `test/core/theme/design_tokens_test.dart` (create)

**Interfaces:**
- Consumes: font family names from Task A1
- Produces: `kFontSans`, `kFontMono`, new `AppColors` role constants, `AppColors.crewPalette`, `AppPalette` + `theme.palette`, `AppMonoType` + `theme.monoType`, extended `AppStatusColors`, extended `AppCardStyle`, role radii on `AppRadius`, new `AppMotion` entries, `crewColorOf(ThemeData, int)`, `avatarForegroundFor(ThemeData, Color)`

> **Additive on purpose.** Every existing `AppColors.*` name keeps its current value in this task, so `themes.dart` and the five external call sites still compile untouched. Task A3 flips the theme onto the new names; Task A5 deletes the old ones. This ordering makes the value changes visible as call-site diffs instead of a silent in-place swap.

- [x] **Step 1: Write the failing test**

Create `test/core/theme/design_tokens_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/design_tokens.dart';

void main() {
  test('crew palette has ten distinct colours', () {
    expect(AppColors.crewPalette, hasLength(10));
    expect(
      AppColors.crewPalette.map((c) => c.toARGB32()).toSet(),
      hasLength(10),
    );
  });

  test('every canonical crew colour has a dark counterpart', () {
    final dark = AppPalette.dark;
    for (final colour in AppColors.crewPalette) {
      expect(
        dark.crewOverride[colour.toARGB32()],
        isNotNull,
        reason: '${colour.toARGB32().toRadixString(16)} has no dark lift',
      );
    }
  });

  test('crewColorOf is identity in light and lifts in dark', () {
    final light = ThemeData(extensions: const [AppPalette.light]);
    final dark = ThemeData(extensions: const [AppPalette.dark]);
    const blue = 0xFF005CC8;
    expect(crewColorOf(light, blue), const Color(blue));
    expect(crewColorOf(dark, blue), const Color(0xFF4B90F7));
  });

  test('crewColorOf HSL-lifts a custom colour only in dark', () {
    final light = ThemeData(extensions: const [AppPalette.light]);
    final dark = ThemeData(extensions: const [AppPalette.dark]);
    const custom = 0xFF123456; // not in the canonical palette
    expect(crewColorOf(light, custom), const Color(custom));
    final lifted = crewColorOf(dark, custom);
    expect(
      HSLColor.fromColor(lifted).lightness,
      greaterThan(HSLColor.fromColor(const Color(custom)).lightness),
    );
  });

  test('avatarForegroundFor returns contrast in light, hue-ink in dark', () {
    final light = ThemeData(extensions: const [AppPalette.light]);
    final dark = ThemeData(extensions: const [AppPalette.dark]);
    const mint = Color(0xFF2BC48E);
    expect(avatarForegroundFor(light, mint), Colors.black);
    final inked = avatarForegroundFor(dark, mint);
    expect(HSLColor.fromColor(inked).lightness, lessThan(0.15));
    expect(inked, isNot(Colors.black)); // keeps the hue, not pure black
  });
}
```

- [x] **Step 2: Run it to confirm it fails**

```bash
flutter test test/core/theme/design_tokens_test.dart
```

Expected: FAIL — `AppColors.crewPalette`, `AppPalette`, `crewColorOf`, `avatarForegroundFor` are all undefined.

- [x] **Step 3: Add the font family constants and the new colour vocabulary**

At the top of `lib/core/theme/design_tokens.dart`, above `AppColors`:

```dart
/// Sans family for all UI text. Bundled as a static-instance asset family.
const String kFontSans = 'InstrumentSans';

/// Mono family for numbers, times, counts and all-caps section labels.
/// Reached through [AppMonoType], never by hand at a call site.
const String kFontMono = 'IBMPlexMono';
```

Add these to `AppColors` (keep every existing member for now):

```dart
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
  static const Color barTint = Color(0xFFC7D8EF);
  static const Color green = Color(0xFF0E9B6E);
  static const Color greenText = Color(0xFF0B7A57);
  static const Color greenFill = Color(0xFFE6F5EF);
  static const Color amber = Color(0xFFE08A00);
  static const Color amberText = Color(0xFF8A5C00);
  static const Color amberFill = Color(0xFFFFF4E5);
  static const Color red = Color(0xFFD61F3A);
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

  /// The ten assignable crew colours — the app's primary data encoding
  /// (card bar, avatar, calendar dot, map pin, workload bar, route rail).
  /// STORED in Firestore as the light-theme ARGB int; dark rendering
  /// resolves through [crewColorOf], never by re-storing a lifted value.
  static const List<Color> crewPalette = [
    Color(0xFF005CC8), // blue
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
```

> **The two added hues.** The handoff shipped eight and said "extend with two more distinct hues". Brown `#8A5A2B` (~30°, dark and desaturated) and olive `#7A8F1F` (~70°) are the two unclaimed bands. They survive red-green colour blindness: brown separates from amber by a large lightness gap and from red by lightness *and* saturation; olive separates from the teal-leaning green on the blue-yellow axis, which deutans and protans retain. Slate stays the neutral escape hatch.

> **Crew slot 1 is `#005CC8`, the same blue as primary UI accents** — that employee's colour bar visually merges with buttons and selection. Cosmetic and inherited from the handoff's ordering; order affects only *new* picks, so reorder before P4 ships the invite sheet if the owner objects.

- [x] **Step 4: Add the dark crew override map and the two resolvers**

Below `AppColors`, still in `design_tokens.dart`:

```dart
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

/// Resolves a STORED employee colour int to the colour this theme renders.
/// Canonical hues hit the exact per-theme map; anything custom-picked (or
/// left over from the pre-redesign palette) gets a generic HSL lift whose
/// amount is theme data — 0 in light, so light is exact identity.
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

/// Foreground for text/icons sitting on a crew-coloured surface (avatars,
/// map pins). Light: plain contrast. Dark: a near-black tint of the
/// surface's OWN hue — white on a lifted crew colour fails contrast at
/// avatar sizes (`09-dark-theme.md` rule 2).
Color avatarForegroundFor(ThemeData theme, Color background) {
  final inkLightness = theme.palette.avatarInkLightness;
  if (inkLightness == null) return contrastingForegroundFor(background);
  final hsl = HSLColor.fromColor(background);
  return hsl
      .withSaturation((hsl.saturation * 0.7).clamp(0.0, 1.0))
      .withLightness(inkLightness)
      .toColor();
}
```

`contrastingForegroundFor` is **kept** — it becomes the light-path primitive inside `avatarForegroundFor` plus the fallback for genuinely theme-free contrast checks.

- [x] **Step 5: Add the `AppPalette` extension**

Everything Material's `ColorScheme` has no slot for lives here. One deliberately fat extension: the concerns straddle (`barTint` is chart *and* blue-tint; `noticeMint` is status *and* notice), and each split multiplies `copyWith`/`lerp` ceremony for no lookup benefit.

```dart
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
    required this.barTint,
    required this.brandNavy,
    required this.sheetRow,
    required this.lockedPanel,
    required this.lockedPanelBorder,
    required this.track,
    required this.dangerFill,
    required this.onDangerFill,
    required this.noticeMint,
    required this.noticeInfo,
    required this.noticeAmber,
    required this.noticeRed,
    required this.heroGradient,
    required this.crewOverride,
    required this.crewCustomLift,
    required this.avatarInkLightness,
  });

  final Color textBody;         // body copy — Ink 80
  final Color textTertiary;     // labels — Ink 40
  final Color textMuted;        // captions, inactive — Ink 25
  final Color textFaint;        // chevrons, placeholder — Ink 15
  final Color decorFaint;       // grabber, decorative strokes
  final Color primaryAccent;    // blue for TEXT and ICONS (lifted in dark)
  final Color blueTintPressed;  // pressed state on tinted icon buttons
  final Color barTint;          // inactive chart bars
  final Color brandNavy;        // gradient end, owner avatar
  final Color sheetRow;         // row card inside a sheet
  final Color lockedPanel;      // read-only field group
  final Color lockedPanelBorder;
  final Color track;            // progress-bar tracks
  final Color dangerFill;       // saturated destructive button fill
  final Color onDangerFill;
  final Color noticeMint;       // toast dots — the toast surface is dark in
  final Color noticeInfo;       // BOTH themes, so these four are identical
  final Color noticeAmber;      // light and dark.
  final Color noticeRed;
  final Gradient heroGradient;
  final Map<int, Color> crewOverride;
  final double crewCustomLift;
  final double? avatarInkLightness; // null = plain contrast foreground

  static const light = AppPalette(
    textBody: AppColors.ink80,
    textTertiary: AppColors.ink40,
    textMuted: AppColors.ink25,
    textFaint: AppColors.ink15,
    decorFaint: AppColors.ink15,
    primaryAccent: AppColors.blue,
    blueTintPressed: AppColors.blueTintHover,
    barTint: AppColors.barTint,
    brandNavy: AppColors.navy,
    sheetRow: Color(0xFFFFFFFF),
    lockedPanel: AppColors.lockedPanel,
    lockedPanelBorder: Color(0x120B1A33),
    track: AppColors.track,
    dangerFill: AppColors.red,
    onDangerFill: Color(0xFFFFFFFF),
    noticeMint: Color(0xFF7FE3C0),
    noticeInfo: Color(0xFF7FCBFF),
    noticeAmber: Color(0xFFF0C36A),
    noticeRed: Color(0xFFFF9AA8),
    heroGradient: LinearGradient(
      begin: Alignment(-0.5, -1),
      end: Alignment(0.5, 1),
      colors: [AppColors.blue, AppColors.navy],
    ),
    crewOverride: {},
    crewCustomLift: 0,
    avatarInkLightness: null,
  );

  static const dark = AppPalette(
    textBody: Color(0xFFC5D0E2),
    textTertiary: AppColors.darkTextTertiary,
    textMuted: AppColors.darkTextMuted,
    textFaint: Color(0xFF3A465A),
    decorFaint: Color(0xFF2C3648),
    primaryAccent: AppColors.darkBlueText,
    blueTintPressed: Color(0x334B90F7),
    barTint: Color(0xFF31445F),
    brandNavy: AppColors.darkNavy,
    sheetRow: AppColors.darkSheetRow,
    lockedPanel: Color(0xFF121B2A),
    lockedPanelBorder: Color(0x12FFFFFF),
    track: Color(0x14FFFFFF),
    dangerFill: AppColors.red,
    onDangerFill: Color(0xFFFFFFFF),
    noticeMint: Color(0xFF7FE3C0),
    noticeInfo: Color(0xFF7FCBFF),
    noticeAmber: Color(0xFFF0C36A),
    noticeRed: Color(0xFFFF9AA8),
    heroGradient: LinearGradient(
      begin: Alignment(-0.5, -1),
      end: Alignment(0.5, 1),
      colors: [AppColors.darkBlueFill, AppColors.darkNavy],
    ),
    crewOverride: _darkCrewOverride,
    crewCustomLift: 0.18,
    avatarInkLightness: 0.07,
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
    Color? barTint,
    Color? brandNavy,
    Color? sheetRow,
    Color? lockedPanel,
    Color? lockedPanelBorder,
    Color? track,
    Color? dangerFill,
    Color? onDangerFill,
    Color? noticeMint,
    Color? noticeInfo,
    Color? noticeAmber,
    Color? noticeRed,
    Gradient? heroGradient,
    Map<int, Color>? crewOverride,
    double? crewCustomLift,
    double? avatarInkLightness,
  }) => AppPalette(
    textBody: textBody ?? this.textBody,
    textTertiary: textTertiary ?? this.textTertiary,
    textMuted: textMuted ?? this.textMuted,
    textFaint: textFaint ?? this.textFaint,
    decorFaint: decorFaint ?? this.decorFaint,
    primaryAccent: primaryAccent ?? this.primaryAccent,
    blueTintPressed: blueTintPressed ?? this.blueTintPressed,
    barTint: barTint ?? this.barTint,
    brandNavy: brandNavy ?? this.brandNavy,
    sheetRow: sheetRow ?? this.sheetRow,
    lockedPanel: lockedPanel ?? this.lockedPanel,
    lockedPanelBorder: lockedPanelBorder ?? this.lockedPanelBorder,
    track: track ?? this.track,
    dangerFill: dangerFill ?? this.dangerFill,
    onDangerFill: onDangerFill ?? this.onDangerFill,
    noticeMint: noticeMint ?? this.noticeMint,
    noticeInfo: noticeInfo ?? this.noticeInfo,
    noticeAmber: noticeAmber ?? this.noticeAmber,
    noticeRed: noticeRed ?? this.noticeRed,
    heroGradient: heroGradient ?? this.heroGradient,
    crewOverride: crewOverride ?? this.crewOverride,
    crewCustomLift: crewCustomLift ?? this.crewCustomLift,
    avatarInkLightness: avatarInkLightness ?? this.avatarInkLightness,
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
      barTint: Color.lerp(barTint, other.barTint, t)!,
      brandNavy: Color.lerp(brandNavy, other.brandNavy, t)!,
      sheetRow: Color.lerp(sheetRow, other.sheetRow, t)!,
      lockedPanel: Color.lerp(lockedPanel, other.lockedPanel, t)!,
      lockedPanelBorder:
          Color.lerp(lockedPanelBorder, other.lockedPanelBorder, t)!,
      track: Color.lerp(track, other.track, t)!,
      dangerFill: Color.lerp(dangerFill, other.dangerFill, t)!,
      onDangerFill: Color.lerp(onDangerFill, other.onDangerFill, t)!,
      noticeMint: Color.lerp(noticeMint, other.noticeMint, t)!,
      noticeInfo: Color.lerp(noticeInfo, other.noticeInfo, t)!,
      noticeAmber: Color.lerp(noticeAmber, other.noticeAmber, t)!,
      noticeRed: Color.lerp(noticeRed, other.noticeRed, t)!,
      heroGradient: Gradient.lerp(heroGradient, other.heroGradient, t)!,
      // Discrete data, not colours — snap at the midpoint.
      crewOverride: t < 0.5 ? crewOverride : other.crewOverride,
      crewCustomLift:
          lerpDouble(crewCustomLift, other.crewCustomLift, t) ?? crewCustomLift,
      avatarInkLightness:
          t < 0.5 ? avatarInkLightness : other.avatarInkLightness,
    );
  }
}

extension AppPaletteX on ThemeData {
  AppPalette get palette =>
      extension<AppPalette>() ??
      (brightness == Brightness.dark ? AppPalette.dark : AppPalette.light);
}
```

`lerpDouble` comes from `dart:ui` — add `import 'dart:ui' show lerpDouble;` at the top of the file if it is not already imported.

- [x] **Step 6: Add the `AppMonoType` extension**

This is the answer to "how does a call site say *this number is mono data*": `Text(time, style: theme.monoType.data)`.

```dart
/// Named mono styles for numbers, times, counts and all-caps labels.
/// A call site writes `theme.monoType.data` — never a raw fontFamily.
@immutable
class AppMonoType extends ThemeExtension<AppMonoType> {
  const AppMonoType({
    required this.data,
    required this.metric,
    required this.label,
    required this.groupLabel,
    required this.fieldLabel,
    required this.micro,
    required this.numeralHero,
    required this.numeralKpi,
    required this.numeralSection,
    required this.numeralSub,
  });

  final TextStyle data;           // 12.5 / 1.0 / 500 — times, counts
  final TextStyle metric;         // 15 / 1.0 / 600
  final TextStyle label;          // 11 / 1.0 / 600 / +1.1 — CALLER uppercases
  final TextStyle groupLabel;     // 10.5 / 1.0 / 600 / +1.16 — drawer groups
  final TextStyle fieldLabel;     // 10 / 1.0 / 600 / +0.9 — dropdown labels
  final TextStyle micro;          // 9.5 / 1.0 / 500 / +0.57
  final TextStyle numeralHero;    // 44 / 1.0 / 700 / -1.76
  final TextStyle numeralKpi;     // 22 / 1.0 / 700 / -0.66
  final TextStyle numeralSection; // 30 / 1.0 / 700 / -1.05
  final TextStyle numeralSub;     // 20 / 1.0 / 700

  static const light = _monoFor(
    ink: AppColors.ink,
    secondary: AppColors.ink60,
    tertiary: AppColors.ink40,
  );

  static const dark = _monoFor(
    ink: AppColors.darkTextPrimary,
    secondary: AppColors.darkTextSecondary,
    tertiary: AppColors.darkTextTertiary,
  );

  @override
  AppMonoType copyWith({
    TextStyle? data,
    TextStyle? metric,
    TextStyle? label,
    TextStyle? groupLabel,
    TextStyle? fieldLabel,
    TextStyle? micro,
    TextStyle? numeralHero,
    TextStyle? numeralKpi,
    TextStyle? numeralSection,
    TextStyle? numeralSub,
  }) => AppMonoType(
    data: data ?? this.data,
    metric: metric ?? this.metric,
    label: label ?? this.label,
    groupLabel: groupLabel ?? this.groupLabel,
    fieldLabel: fieldLabel ?? this.fieldLabel,
    micro: micro ?? this.micro,
    numeralHero: numeralHero ?? this.numeralHero,
    numeralKpi: numeralKpi ?? this.numeralKpi,
    numeralSection: numeralSection ?? this.numeralSection,
    numeralSub: numeralSub ?? this.numeralSub,
  );

  @override
  AppMonoType lerp(ThemeExtension<AppMonoType>? other, double t) {
    if (other is! AppMonoType) return this;
    return AppMonoType(
      data: TextStyle.lerp(data, other.data, t)!,
      metric: TextStyle.lerp(metric, other.metric, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      groupLabel: TextStyle.lerp(groupLabel, other.groupLabel, t)!,
      fieldLabel: TextStyle.lerp(fieldLabel, other.fieldLabel, t)!,
      micro: TextStyle.lerp(micro, other.micro, t)!,
      numeralHero: TextStyle.lerp(numeralHero, other.numeralHero, t)!,
      numeralKpi: TextStyle.lerp(numeralKpi, other.numeralKpi, t)!,
      numeralSection: TextStyle.lerp(numeralSection, other.numeralSection, t)!,
      numeralSub: TextStyle.lerp(numeralSub, other.numeralSub, t)!,
    );
  }
}

/// Builds one themed mono set. Sizes and tracking are theme-invariant —
/// only the three colours move between light and dark.
const AppMonoType _monoFor({
  required Color ink,
  required Color secondary,
  required Color tertiary,
}) => AppMonoType(
  data: TextStyle(
    fontFamily: kFontMono,
    fontSize: 12.5,
    height: 1,
    fontWeight: FontWeight.w500,
    color: secondary,
  ),
  metric: TextStyle(
    fontFamily: kFontMono,
    fontSize: 15,
    height: 1,
    fontWeight: FontWeight.w600,
    color: ink,
  ),
  label: TextStyle(
    fontFamily: kFontMono,
    fontSize: 11,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
    color: tertiary,
  ),
  groupLabel: TextStyle(
    fontFamily: kFontMono,
    fontSize: 10.5,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.16,
    color: tertiary,
  ),
  fieldLabel: TextStyle(
    fontFamily: kFontMono,
    fontSize: 10,
    height: 1,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.9,
    color: tertiary,
  ),
  micro: TextStyle(
    fontFamily: kFontMono,
    fontSize: 9.5,
    height: 1,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.57,
    color: tertiary,
  ),
  numeralHero: TextStyle(
    fontFamily: kFontMono,
    fontSize: 44,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.76,
    color: ink,
  ),
  numeralKpi: TextStyle(
    fontFamily: kFontMono,
    fontSize: 22,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.66,
    color: ink,
  ),
  numeralSection: TextStyle(
    fontFamily: kFontMono,
    fontSize: 30,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.05,
    color: ink,
  ),
  numeralSub: TextStyle(
    fontFamily: kFontMono,
    fontSize: 20,
    height: 1,
    fontWeight: FontWeight.w700,
    color: ink,
  ),
);

extension AppMonoTypeX on ThemeData {
  AppMonoType get monoType =>
      extension<AppMonoType>() ??
      (brightness == Brightness.dark ? AppMonoType.dark : AppMonoType.light);
}
```

> **Tracking arithmetic.** Flutter's `letterSpacing` is logical pixels; the design gives `em`. Multiply: mono Label `+0.1em × 11px = +1.1`; hero numeral `−0.04em × 44px = −1.76`; group label `+0.11em × 10.5px = +1.155 ≈ 1.16`. **`height:` is the design's ratio verbatim** — "26px / 1.1" is `fontSize: 26, height: 1.1` (a 28.6 px line box).

- [x] **Step 7: Extend `AppStatusColors` with the three neutral fields**

Add to the field list, the constructor, both `static const`s, `copyWith`, and `lerp` (same mechanical pattern as the existing 13):

```dart
  final Color neutralContainer;         // "Scheduled" + "Cancelled" chip fill
  final Color onNeutralContainer;       // "Scheduled" chip text
  final Color onNeutralContainerMuted;  // "Cancelled" chip text
```

Values — `light`: `neutralContainer: AppColors.paper` (`#F1F4F9`), `onNeutralContainer: AppColors.ink60` (`#5A6B85`), `onNeutralContainerMuted: AppColors.ink25` (`#A6B2C4`). `dark`: `neutralContainer: Color(0x12FFFFFF)`, `onNeutralContainer: AppColors.darkTextSecondary`, `onNeutralContainerMuted: AppColors.darkTextMuted`.

Leave the existing 13 field *values* alone in this task — they are revalued in Task A3 together with the `ColorScheme` they sit beside.

- [x] **Step 8: Extend `AppCardStyle` with the shadow set**

Add eight fields beside the existing `shadow` / `border` / `iconChipAlpha`, wiring them through the constructor, both consts, `copyWith`, and `lerp` (use `BoxShadow.lerpList` for each, matching the existing pattern):

```dart
  final List<BoxShadow> sheetShadow;
  final List<BoxShadow> dialogShadow;
  final List<BoxShadow> drawerShadow;
  final List<BoxShadow> noticeShadow;
  final List<BoxShadow> fabShadow;
  final List<BoxShadow> pillShadow;
  final List<BoxShadow> thumbShadow;
  final List<BoxShadow> knobShadow;
```

CSS alpha converts to a hex byte: `.05→0D`, `.07→12`, `.14→24`, `.3→4D`, `.4→66`, `.55→8C`, `.6→99`, `.65→A6`, `.8→CC`. CSS `blur B spread S` maps to `blurRadius: B, spreadRadius: S`.

```dart
  static const light = AppCardStyle(
    shadow: [
      BoxShadow(color: Color(0x0D0B1A33), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(
        color: Color(0x4D0B1A33),
        blurRadius: 24,
        spreadRadius: -16,
        offset: Offset(0, 10),
      ),
    ],
    border: null,
    iconChipAlpha: 0.10,
    sheetShadow: [
      BoxShadow(
        color: Color(0x660B1A33),
        blurRadius: 30,
        spreadRadius: -12,
        offset: Offset(0, 12),
      ),
    ],
    dialogShadow: [
      BoxShadow(
        color: Color(0x8C0B1A33),
        blurRadius: 50,
        spreadRadius: -16,
        offset: Offset(0, 22),
      ),
    ],
    drawerShadow: [
      BoxShadow(
        color: Color(0x660B1A33),
        blurRadius: 44,
        spreadRadius: -18,
        offset: Offset(-18, 0),
      ),
    ],
    noticeShadow: [
      BoxShadow(
        color: Color(0x990B1A33),
        blurRadius: 32,
        spreadRadius: -12,
        offset: Offset(0, 14),
      ),
    ],
    fabShadow: [
      BoxShadow(
        color: Color(0xA6005CC8),
        blurRadius: 24,
        spreadRadius: -8,
        offset: Offset(0, 10),
      ),
    ],
    pillShadow: [
      BoxShadow(
        color: Color(0x660B1A33),
        blurRadius: 16,
        spreadRadius: -6,
        offset: Offset(0, 6),
      ),
    ],
    thumbShadow: [
      BoxShadow(color: Color(0x240B1A33), blurRadius: 3, offset: Offset(0, 1)),
    ],
    knobShadow: [
      BoxShadow(color: Color(0x4D0B1A33), blurRadius: 2, offset: Offset(0, 1)),
    ],
  );

  static const dark = AppCardStyle(
    // Dark separates by surface stepping, not shadow — this is edge
    // definition only (`09-dark-theme.md` rule 1).
    shadow: [
      BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    border: Border.fromBorderSide(BorderSide(color: Color(0x12FFFFFF))),
    iconChipAlpha: 0.15,
    sheetShadow: [
      BoxShadow(
        color: Color(0xCC000000),
        blurRadius: 30,
        spreadRadius: -12,
        offset: Offset(0, 12),
      ),
    ],
    dialogShadow: [
      BoxShadow(
        color: Color(0xCC000000),
        blurRadius: 50,
        spreadRadius: -16,
        offset: Offset(0, 22),
      ),
    ],
    drawerShadow: [
      BoxShadow(
        color: Color(0xCC000000),
        blurRadius: 44,
        spreadRadius: -18,
        offset: Offset(-18, 0),
      ),
    ],
    noticeShadow: [
      BoxShadow(
        color: Color(0xCC000000),
        blurRadius: 32,
        spreadRadius: -12,
        offset: Offset(0, 14),
      ),
    ],
    fabShadow: [
      BoxShadow(
        color: Color(0xA61D6BE8),
        blurRadius: 24,
        spreadRadius: -8,
        offset: Offset(0, 10),
      ),
    ],
    pillShadow: [
      BoxShadow(
        color: Color(0xCC000000),
        blurRadius: 16,
        spreadRadius: -6,
        offset: Offset(0, 6),
      ),
    ],
    thumbShadow: [
      BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
    knobShadow: [
      BoxShadow(color: Color(0x66000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
  );
```

- [x] **Step 9: Add role radii, density spacing, and the new motion tokens**

Append to `AppRadius` (the numeric names keep their true values so they never lie; P2–P7 migrate call sites onto the role names):

```dart
  static const double rCard = 15;
  static const double rPanel = 18;
  static const double rHero = 20;
  static const double rSheet = 26;
  static const double rDialog = 22;
  static const double rFab = 20;
  static const double rIcon = 12;
  static const double rInput = 12;
  static const double rThumb = 9;
  static const double rRow = 13;
  static const double rSwatch = 12;
```

Append to `AppSpacing` (Balanced density — the program fixed the density setting):

```dart
  static const double cardPaddingY = 12;
  static const double cardGap = 9;
```

Append to `AppMotion` and revalue `sheetStyle`:

```dart
  /// Shared open/close curve for `showModalBottomSheet`.
  static const AnimationStyle sheetStyle = AnimationStyle(
    duration: Duration(milliseconds: 300),
    reverseDuration: Duration(milliseconds: 240),
    curve: Cubic(0.2, 0.9, 0.25, 1),
  );

  static const Curve emphasized = Cubic(0.2, 0.9, 0.25, 1);
  static const Duration popIn = Duration(milliseconds: 200);
  static const Duration drawer = Duration(milliseconds: 260);
  static const Duration riseIn = Duration(milliseconds: 300);
  static const Duration riseInShort = Duration(milliseconds: 240);
  static const Duration dropdownSheet = Duration(milliseconds: 280);

  /// Total in-hold-out lifetime of a notice (`06-sheets-and-dialogs.md` §11).
  static const Duration noticeCycle = Duration(milliseconds: 2600);
```

- [x] **Step 10: Run the test to verify it passes**

```bash
flutter test test/core/theme/design_tokens_test.dart
```

Expected: PASS, 5 tests.

- [x] **Step 11: Confirm nothing else regressed**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test
```

Expected: no analyzer output; the full suite still green (this task added tokens, changed no rendering).

- [x] **Step 12: Commit**

```bash
git add lib/core/theme/design_tokens.dart test/core/theme/design_tokens_test.dart
git commit -m "feat(p1): add redesign token vocabulary, AppPalette and AppMonoType"
```

---

## Task A3: Flip the themes onto the new tokens

**Files:**
- Modify: `lib/core/theme/themes.dart` (currently 362 lines — `_buildTextTheme` lines 5–60, `_buildLightTheme` 69–210, `_buildDarkTheme` 212–362)
- Modify: `lib/core/theme/design_tokens.dart` (revalue the 13 existing `AppStatusColors` fields)
- Test: `test/core/theme/themes_test.dart` (create)

**Interfaces:**
- Consumes: `kFontSans`, `kFontMono`, the new `AppColors` roles, `AppPalette`, `AppMonoType` (Task A2)
- Produces: `lightTheme()` / `darkTheme()` carrying the redesign `ColorScheme`, `TextTheme`, and all four extensions

> **This is where the app visibly changes.** Everything before it was additive.

**The placement rule that decides every colour.** A role goes on `ColorScheme` **iff Material's own widgets read that slot implicitly**; everything Material never reads goes on an extension. Where the design splits one Material slot in two (dark's fill-blue `#1D6BE8` vs text-blue `#4B90F7`), the slot takes the variant the framework's implicit consumers need and the extension takes the other. So `primary` is the **fill** blue (FilledButton, FAB, app bar, `Switch.adaptive activeTrackColor`), while `palette.primaryAccent` is the text/icon blue. Conversely `error` is the **lifted foreground** red in dark (`#FF6076` — Material's implicit `error` consumers are input error text and borders), while the saturated destructive *fill* is `palette.dangerFill`.

- [x] **Step 1: Write the failing test**

Create `test/core/theme/themes_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';

void main() {
  test('both themes register all four extensions', () {
    for (final theme in [lightTheme(), darkTheme()]) {
      expect(theme.extension<AppStatusColors>(), isNotNull);
      expect(theme.extension<AppCardStyle>(), isNotNull);
      expect(theme.extension<AppPalette>(), isNotNull);
      expect(theme.extension<AppMonoType>(), isNotNull);
    }
  });

  test('primary is the saturated fill blue, accent is the text blue', () {
    expect(lightTheme().colorScheme.primary, AppColors.blue);
    expect(lightTheme().palette.primaryAccent, AppColors.blue);
    expect(darkTheme().colorScheme.primary, AppColors.darkBlueFill);
    expect(darkTheme().palette.primaryAccent, AppColors.darkBlueText);
  });

  test('the notice surface is dark ink in both themes', () {
    expect(lightTheme().colorScheme.inverseSurface, AppColors.ink);
    expect(darkTheme().colorScheme.inverseSurface, AppColors.darkNotice);
  });

  test('M3 elevation tinting is disabled', () {
    expect(lightTheme().colorScheme.surfaceTint, Colors.transparent);
    expect(darkTheme().colorScheme.surfaceTint, Colors.transparent);
  });

  test('every text style uses the bundled sans family', () {
    final ramp = lightTheme().textTheme;
    for (final style in [
      ramp.displayLarge, ramp.headlineLarge, ramp.headlineMedium,
      ramp.headlineSmall, ramp.titleLarge, ramp.titleMedium, ramp.titleSmall,
      ramp.bodyLarge, ramp.bodyMedium, ramp.bodySmall,
      ramp.labelLarge, ramp.labelMedium, ramp.labelSmall,
    ]) {
      expect(style?.fontFamily, kFontSans);
    }
  });

  test('mono styles use the bundled mono family', () {
    final mono = lightTheme().monoType;
    expect(mono.data.fontFamily, kFontMono);
    expect(mono.numeralHero.fontFamily, kFontMono);
  });

  test('no text style falls below the 11px floor', () {
    final ramp = lightTheme().textTheme;
    for (final style in [ramp.labelSmall, ramp.labelMedium, ramp.bodySmall]) {
      expect(style!.fontSize, greaterThanOrEqualTo(11.0));
    }
  });
}
```

- [x] **Step 2: Run it to confirm it fails**

```bash
flutter test test/core/theme/themes_test.dart
```

Expected: FAIL — extensions `AppPalette`/`AppMonoType` are not registered, `primary` is the old value, `surfaceTint` is not transparent, families are Inter.

- [x] **Step 3: Replace `_buildTextTheme`**

Delete the existing `_buildTextTheme(Color onSurface, Color subtle)` (lines 5–60) and its `GoogleFonts.interTextTheme()` base. Replace with:

```dart
TextTheme _buildTextTheme({
  required Color ink,       // titles
  required Color body,      // body copy
  required Color secondary, // Ink 60
  required Color caption,   // Ink 25
}) {
  TextStyle s(
    double size,
    double height,
    FontWeight weight,
    double tracking,
    Color colour,
  ) => TextStyle(
    fontFamily: kFontSans,
    fontSize: size,
    height: height,
    fontWeight: weight,
    letterSpacing: tracking,
    color: colour,
  );

  return TextTheme(
    displayLarge: s(26, 1.1, FontWeight.w700, -0.65, ink),
    displayMedium: s(22, 1.2, FontWeight.w700, -0.55, ink),
    displaySmall: s(19, 1.25, FontWeight.w700, -0.38, ink),
    headlineLarge: s(22, 1.2, FontWeight.w700, -0.55, ink), // sheet title
    headlineMedium: s(19, 1.25, FontWeight.w700, -0.38, ink), // dialog title
    headlineSmall: s(17, 1.2, FontWeight.w600, -0.34, ink), // section title
    titleLarge: s(17, 1.2, FontWeight.w600, -0.34, ink), // app bar
    titleMedium: s(15, 1.25, FontWeight.w600, -0.15, ink), // row + card title
    titleSmall: s(13.5, 1.3, FontWeight.w600, 0, ink), // sub-row title
    bodyLarge: s(15, 1.4, FontWeight.w400, 0, ink), // inputs, lead body
    bodyMedium: s(13.5, 1.45, FontWeight.w400, 0, body), // body
    bodySmall: s(12.5, 1.3, FontWeight.w400, 0, secondary), // secondary
    labelLarge: s(14, 1, FontWeight.w600, 0, ink), // button, tab
    labelMedium: s(11.5, 1.45, FontWeight.w400, 0, caption), // caption
    labelSmall: s(11, 1.5, FontWeight.w600, 0, ink), // chip label
  );
}
```

Call sites become `_buildTextTheme(ink: AppColors.ink, body: AppColors.ink80, secondary: AppColors.ink60, caption: AppColors.ink25)` in light and `_buildTextTheme(ink: AppColors.darkTextPrimary, body: const Color(0xFFC5D0E2), secondary: AppColors.darkTextSecondary, caption: AppColors.darkTextMuted)` in dark.

> **Three ramp decisions worth knowing.** (1) **Card title 15.5 folds into `titleMedium` 15** — half a logical pixel is invisible at mobile DPR and `TextTheme` has no free slot; if P2 insists, `AppointmentCard` does a local `copyWith(fontSize: 15.5)`. (2) **The 9px `labelSmall` is gone.** The only sub-11px roles in the new ramp are mono micro-labels, which live on `AppMonoType.micro` — opt-in, never a Material default. (3) **`labelLarge` grows 11 → 14.** Any call site currently using it as a *small* label will visibly grow at this commit; P2–P7 correct those as they sweep screens.

- [x] **Step 4: Replace the light `ColorScheme`**

```dart
  const cs = ColorScheme.light(
    primary: AppColors.blue,
    onPrimary: Colors.white,
    primaryContainer: AppColors.blueTint,
    onPrimaryContainer: AppColors.blue,
    secondary: AppColors.green,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.greenFill,
    onSecondaryContainer: AppColors.greenText,
    tertiary: AppColors.amber, // WARNING slot — never success
    onTertiary: Colors.white,
    tertiaryContainer: AppColors.amberFill,
    onTertiaryContainer: AppColors.amberText,
    error: AppColors.red,
    onError: Colors.white,
    errorContainer: AppColors.redFill,
    onErrorContainer: AppColors.redText,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    onSurfaceVariant: AppColors.ink60,
    outline: AppColors.hairline,
    outlineVariant: AppColors.border,
    surfaceContainerLowest: AppColors.surfaceHover,
    surfaceContainerLow: AppColors.sheet,
    surfaceContainer: AppColors.paper,
    surfaceContainerHigh: AppColors.track,
    surfaceContainerHighest: AppColors.paper2,
    inverseSurface: AppColors.ink, // notice / toast background
    onInverseSurface: AppColors.darkTextPrimary,
    inversePrimary: AppColors.darkBlueText,
    surfaceTint: Colors.transparent, // kill M3 elevation tinting
    scrim: AppColors.ink,
    shadow: AppColors.ink,
  );
```

- [x] **Step 5: Replace the dark `ColorScheme`**

```dart
  const cs = ColorScheme.dark(
    primary: AppColors.darkBlueFill, // buttons stay saturated
    onPrimary: Colors.white,
    primaryContainer: Color(0x294B90F7), // 16% of #4B90F7
    onPrimaryContainer: AppColors.darkBlueOnTint,
    secondary: AppColors.darkGreen,
    onSecondary: Colors.white,
    secondaryContainer: Color(0x292BC48E),
    onSecondaryContainer: AppColors.darkGreenText,
    tertiary: AppColors.darkAmber,
    onTertiary: Color(0xFF1A1000), // near-black on amber
    tertiaryContainer: Color(0x29F1A83C),
    onTertiaryContainer: AppColors.darkAmber,
    error: AppColors.darkRed, // lifted — Material reads this as foreground
    onError: Color(0xFF1C060A),
    errorContainer: Color(0x29FF6076),
    onErrorContainer: AppColors.darkRedText,
    surface: AppColors.darkCard,
    onSurface: AppColors.darkTextPrimary,
    onSurfaceVariant: AppColors.darkTextSecondary,
    outline: Color(0x12FFFFFF), // 7% white hairline
    outlineVariant: Color(0x0FFFFFFF), // 6% white row divider
    surfaceContainerLowest: AppColors.darkPage,
    surfaceContainerLow: AppColors.darkSheet,
    surfaceContainer: AppColors.darkCard,
    surfaceContainerHigh: AppColors.darkSheetRow,
    surfaceContainerHighest: AppColors.darkNotice,
    inverseSurface: AppColors.darkNotice,
    onInverseSurface: AppColors.darkTextPrimary,
    inversePrimary: AppColors.blue,
    surfaceTint: Colors.transparent,
    scrim: Color(0xFF040810),
    shadow: Colors.black,
  );
```

> **Status chips move to 16%-alpha fills in dark** (`09-dark-theme.md` rule 3). `0x29` is 16% of 255 (40.8 → 41 → `0x29`).

- [x] **Step 6: Rewire the component themes**

In both builders: `scaffoldBackgroundColor` becomes `AppColors.paper` (light) / `AppColors.darkPage` (dark). Replace all nine `GoogleFonts.*` call sites with `TextStyle(fontFamily: kFontSans, ...)` keeping each site's existing size/weight. Add `fontFamily: kFontSans` to the `ThemeData(...)` call as a default for un-themed text. Register all four extensions:

```dart
    extensions: const [
      AppStatusColors.light,
      AppCardStyle.light,
      AppPalette.light,
      AppMonoType.light,
    ],
```

(and the `.dark` counterparts in the dark builder). Set the modal barrier to the design's scrim on `bottomSheetTheme`: `modalBarrierColor: const Color(0x730B1A33)` light (45%), `const Color(0x8C040810)` dark (55%).

- [x] **Step 7: Revalue the 13 existing `AppStatusColors` fields**

In `design_tokens.dart`, change the values (the field names and the three added in Task A2 are unchanged):

| Field | Light | Dark |
| --- | --- | --- |
| `success` | `AppColors.green` `#0E9B6E` | `AppColors.darkGreen` `#1FA97A` |
| `successContainer` | `AppColors.greenFill` `#E6F5EF` | `Color(0x292BC48E)` |
| `onSuccessContainer` | `AppColors.greenText` `#0B7A57` | `AppColors.darkGreenText` `#4FD8A6` |
| `warning` | `AppColors.amber` `#E08A00` | `AppColors.darkAmber` `#F1A83C` |
| `warningContainer` | `AppColors.amberFill` `#FFF4E5` | `Color(0x29F1A83C)` |
| `onWarningContainer` | `AppColors.amberText` `#8A5C00` | `AppColors.darkAmber` `#F1A83C` |
| `invitedContainer` | `AppColors.amberFill` `#FFF4E5` | `Color(0x29F1A83C)` |
| `onInvitedContainer` | `AppColors.amberText` `#8A5C00` | `AppColors.darkAmber` `#F1A83C` |
| `inProgressContainer` | `AppColors.blueTint2` `#E4F0FF` | `Color(0x294B90F7)` |
| `onInProgressContainer` | `AppColors.blue` `#005CC8` | `AppColors.darkBlueOnTint` `#7FB2FA` |
| `overdueContainer` | `AppColors.redFill` `#FDE8EC` | `Color(0x29FF6076)` |
| `onOverdueContainer` | `AppColors.redText` `#B01730` | `AppColors.darkRedText` `#FF8A99` |
| `accent` | `AppColors.blue` `#005CC8` | `AppColors.darkBlueText` `#4B90F7` |

> **The Invited chip moves off purple onto amber**, per the status model ("Employment status: Active green, **Invited amber**"). The `invited*` fields stay separate from `warning*` even though they now hold the same values, so employment chips keep their own name and can diverge later. The old `invitedTint`/`invitedText` purple constants die in Task A5.

- [x] **Step 8: Run the test to verify it passes**

```bash
flutter test test/core/theme/themes_test.dart
```

Expected: PASS, 7 tests.

- [x] **Step 9: Run the full suite and fix the fallout**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test
```

Expected breakage to fix here — these are the tests that assert on old theme values:
- any test asserting a specific `scheme.primary` / `scheme.surface` / `scaffoldBackgroundColor` value,
- any golden or pixel assertion,
- `test/core/theme/` existing files.
Update assertions to the new values; do **not** weaken a test into `isNotNull` to make it pass.

- [x] **Step 10: Commit**

```bash
git add lib/core/theme test/core/theme
git commit -m "feat(p1): flip light and dark themes onto the redesign palette and type ramp"
```

---

## Task A4: Migrate the call sites and remap the status chip

**Files:**
- Modify: `lib/shared/widgets/feedback/status_chip.dart` (`_colorsFor`, lines 76–98)
- Modify: `lib/shared/widgets/primitives/app_avatar.dart` (lines ~34, 56–58)
- Modify: `lib/features/employees/widgets/fields/employee_color_grid.dart` (line 32 and the swatch render)
- Modify: `lib/features/employees/widgets/sheets/employee_form_sheet.dart:65`
- Modify: `lib/features/dashboard/widgets/sections/dashboard_hero.dart:25`
- Modify: `lib/features/employees/widgets/dialogs/signup_code_dialog.dart:70`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb` (`status_pending`)
- Test: `test/shared/widgets/feedback/status_chip_test.dart` (update or create)

**Interfaces:**
- Consumes: `crewColorOf`, `avatarForegroundFor`, `AppColors.crewPalette`, `theme.statusColors`, `theme.monoType` (Tasks A2–A3)
- Produces: no new API — this task removes the last external readers of the dying `AppColors` names

- [x] **Step 1: Write the failing test**

In `test/shared/widgets/feedback/status_chip_test.dart`:

```dart
  test('scheduled and cancelled share the neutral fill with different text', () {
    final theme = lightTheme();
    final status = theme.statusColors;
    expect(status.neutralContainer, AppColors.paper);
    expect(status.onNeutralContainer, AppColors.ink60);
    expect(status.onNeutralContainerMuted, AppColors.ink25);
  });

  testWidgets('a pending chip renders neutral, not amber', (tester) async {
    await tester.pumpWidget(_wrap(const StatusChip(status: AppointmentStatus.pending)));
    final pill = tester.widget<StatusPill>(find.byType(StatusPill));
    expect(pill.background, lightTheme().statusColors.neutralContainer);
    expect(pill.foreground, lightTheme().statusColors.onNeutralContainer);
  });

  testWidgets('a cancelled chip leaves the error palette', (tester) async {
    await tester.pumpWidget(_wrap(const StatusChip(status: AppointmentStatus.cancelled)));
    final pill = tester.widget<StatusPill>(find.byType(StatusPill));
    expect(pill.background, lightTheme().statusColors.neutralContainer);
    expect(pill.foreground, lightTheme().statusColors.onNeutralContainerMuted);
    expect(pill.background, isNot(lightTheme().colorScheme.errorContainer));
  });
```

`_wrap` is a `MaterialApp` with `theme: lightTheme()` plus the three localization delegates and `AppLocalizations.supportedLocales` (`StatusChip` calls `context.l10n`).

- [x] **Step 2: Run it to confirm it fails**

```bash
flutter test test/shared/widgets/feedback/status_chip_test.dart
```

Expected: FAIL — pending resolves to `warningContainer`, cancelled to `scheme.errorContainer`.

- [x] **Step 3: Remap `_colorsFor`**

`pending` goes neutral grey (amber is now reserved for time-off Pending and employment Invited); `cancelled` leaves the error palette for neutral-with-muted-text. The `ColorScheme` parameter is dropped — nothing reads it any more:

```dart
  (Color, Color) _colorsFor(AppStatusColors statusColors) => switch (status) {
    AppointmentStatus.pending => ( // "Scheduled"
      statusColors.neutralContainer,
      statusColors.onNeutralContainer,
    ),
    AppointmentStatus.inProgress => (
      statusColors.inProgressContainer,
      statusColors.onInProgressContainer,
    ),
    AppointmentStatus.overdue => (
      statusColors.overdueContainer,
      statusColors.onOverdueContainer,
    ),
    AppointmentStatus.done => (
      statusColors.successContainer,
      statusColors.onSuccessContainer,
    ),
    AppointmentStatus.cancelled => (
      statusColors.neutralContainer,
      statusColors.onNeutralContainerMuted,
    ),
  };
```

Update the one caller in `build()` to drop the scheme argument. **The enum, `fromRaw`, `storedRaw`, `appointmentValues` and the Firestore allowlist are untouched** — this is display-only.

- [x] **Step 4: Confirm the `status_pending` label**

Per the program spec this relabel is **already shipped** (`status_pending` is "Scheduled" / "Planifié" in both ARBs). Verify rather than re-edit:

```bash
grep -n '"status_pending"' lib/l10n/app_en.arb lib/l10n/app_fr.arb
```

If either still says "Pending"/"En attente", fix both ARBs in lockstep. The repo hook regenerates l10n on ARB edits — **do not run `flutter gen-l10n` by hand.**

- [x] **Step 5: Migrate `AppAvatar` onto the crew resolvers**

In `lib/shared/widgets/primitives/app_avatar.dart`, resolve the stored colour through the theme instead of using it raw:

```dart
    final theme = Theme.of(context);
    final stored = color ?? _colorFromName(name);
    final background = crewColorOf(theme, stored.toARGB32());
    final foreground = avatarForegroundFor(theme, background);
```

`_colorFromName` keeps its shape but hashes into `AppColors.crewPalette` instead of `employeePalette`.

- [x] **Step 6: Migrate `EmployeeColorGrid` to resolve-at-display, store-canonical**

In `employee_color_grid.dart`, iterate `AppColors.crewPalette`, and render each swatch through `crewColorOf` while **still storing the canonical light int**:

```dart
    final theme = Theme.of(context);
    // …
    _SwatchButton(
      color: crewColorOf(theme, colour.toARGB32()), // display
      isSelected: colour.toARGB32() == selectedColor,
      onTap: () => _pick(colour.toARGB32()), // STORE canonical
    )
```

The custom-selected swatch resolves the same way: `color: crewColorOf(theme, selectedColor)`. The checkmark foreground moves from `contrastingForegroundFor` to `avatarForegroundFor(theme, resolvedColour)`.

- [x] **Step 7: Migrate the three remaining strays**

- `employee_form_sheet.dart:65` — `AppColors.employeePalette.first` becomes `AppColors.crewPalette.first`.
- `dashboard_hero.dart:25` — the `static const Color _inProgressSegment = AppColors.accent;` field is deleted; the widget reads `theme.statusColors.accent` in `build()` instead (a static const can't be theme-aware).
- `signup_code_dialog.dart:70` — the raw `fontFamily: 'monospace'` becomes `theme.monoType.data.copyWith(fontSize: 19)` (the design's invite-code size), deleting the last hand-rolled font family in `lib/`.

- [x] **Step 8: Fix `showConfirmDialog`'s destructive confirm**

Find the destructive filled-confirm styling in `showConfirmDialog` and repoint its background from `scheme.error` to `theme.palette.dangerFill`. **This is required, not cosmetic:** dark `scheme.error` is now the lifted foreground `#FF6076`, which is unusable as a white-text fill. Same for `destructiveOutlinedButtonStyle`'s *foreground* — that one correctly stays on `scheme.error` (it is a foreground).

- [x] **Step 9: Run the tests**

```bash
flutter test test/shared/widgets/feedback/status_chip_test.dart
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test
```

Expected: the status-chip tests pass; any other test asserting a cancelled chip on `errorContainer` needs its assertion updated to the neutral pair.

- [x] **Step 10: Commit**

```bash
git add lib test
git commit -m "feat(p1): migrate call sites to crew resolvers and remap the status chip"
```

---

## Task A5: Delete the old vocabulary, google_fonts, and Inter

**Files:**
- Modify: `lib/core/theme/design_tokens.dart` (delete the superseded `AppColors` members)
- Modify: `lib/main.dart:75-76` (delete the `GoogleFonts.config` line and its import)
- Modify: `pubspec.yaml` (drop `google_fonts: ^8.1.0`; drop the Inter `fonts:` family)
- Delete: `assets/fonts/Inter-*.ttf` (5 files)

**Interfaces:**
- Consumes: nothing new
- Produces: a single token vocabulary with no dead aliases

> Run this only when Tasks A2–A4 are green. The compiler enumerates any missed consumer.

- [x] **Step 1: Delete the superseded `AppColors` members**

Remove: `primary`, `primaryDark`, `primaryTint`, `primarySurface`, `background`, `surfaceAlt`, `onSurface`, `subtle`, `muted`, `outline`, `success`, `successTint`, `successText`, `warning`, `warningTint`, `warningText`, `error`, `errorTint`, `errorText`, `accent`, `invitedTint`, `invitedText`, `employeePalette`, and every `dark*` member superseded by the new dark roles (`darkBackground`, `darkSurface`, `darkSurfaceAlt`, `darkOnSurface`, `darkSubtle`, `darkMuted`, `darkOutline`, `darkPrimaryTint`, `darkPrimaryOnDark`, `darkSuccessTint`, `darkSuccessText`, `darkWarningTint`, `darkWarningText`, `darkErrorTint`, `darkErrorText`, `darkAccent`, `darkInvitedTint`, `darkInvitedText`).

Keep `surface` (`#FFFFFF`) — the new vocabulary still uses it.

- [x] **Step 2: Let the compiler find the stragglers**

```bash
flutter analyze 2>&1 | grep -E "error -"
```

Fix every reported site by mapping to the new role name. Expected count: zero, if A3 and A4 were complete.

- [x] **Step 3: Drop google_fonts**

Delete `lib/main.dart` lines 75–76 (the comment and `GoogleFonts.config.allowRuntimeFetching = false;`) and the now-unused `package:google_fonts/google_fonts.dart` import. Remove `google_fonts: ^8.1.0` from `pubspec.yaml` dependencies.

- [x] **Step 4: Drop the Inter assets**

Remove the `- family: Inter` block (and the stale comment above it explaining the google_fonts CDN arrangement) from `pubspec.yaml`, then:

```bash
git rm assets/fonts/Inter-Regular.ttf assets/fonts/Inter-Medium.ttf assets/fonts/Inter-SemiBold.ttf assets/fonts/Inter-Bold.ttf assets/fonts/Inter-ExtraBold.ttf
flutter pub get
```

- [x] **Step 5: Verify**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test
grep -rn "GoogleFonts\|employeePalette\|AppColors.subtle\|AppColors.muted" lib/ test/
```

Expected: no analyzer output, full suite green, and the grep returns nothing.

- [x] **Step 6: Run the text-scale sweep**

The theme change alters every font size, so re-run the accessibility enforcement across the screens with existing sweeps:

```bash
flutter test test/features/auth/screens/auth_screens_scale_sweep_test.dart
flutter test --plain-name "scale"
```

Expected: PASS with `tester.takeException()` null throughout. A new overflow here means a fixed height that the larger ramp no longer fits — fix the height to derive from scaled text, never by clamping the scale.

- [x] **Step 7: Commit**

```bash
git add -A
git commit -m "chore(p1): drop the legacy token names, google_fonts and Inter assets"
```

---

# Phase B — Navigation restructure

The hub shrinks to four tabs; History and Settings become pushed routes; the nav rail dies.

**The central decision.** `AdaptiveDestination` (6 members) is replaced by a sealed `AppDestination` family split into `HubTab` (4 IndexedStack panes) and `PushedDestination` (plain routes). Rejected alternatives: *one enum + a `hubTabs` list* and *one enum + `isHubTab`* both keep `select(settings)` compilable, which is exactly the bug this restructure exists to kill — `select` is called from the drawer, the redirect route, `navigateToDestination`, `main.dart` and tests, and one stray pushed value becomes an `IndexedStack` range crash at runtime. A type that makes the illegal state unrepresentable beats an assert, especially since P5 and P6 each edit the destination set again.

`implements Enum` is the trick that keeps `.name` and `.values` working on the union type while ensuring only enums can implement it (a non-abstract class may not implement `Enum`). `sealed` requires all implementers in one library, hence one file.

> **The ordinal coupling is fixed, not preserved.** `index: _current.index` becomes safe again because the `IndexedStack` children and the index now derive from the *same* list (`HubTab.values`). The original bug was indexing into a list that contained non-tab members; that list no longer exists.

## Task B1: Introduce the sealed destination family and delete the rail

**Files:**
- Create: `lib/core/navigation/app_destination.dart`
- Create: `lib/core/navigation/hub_shell_scope.dart`
- Delete: `lib/core/layout/adaptive_shell.dart`
- Modify: `lib/core/layout/breakpoints.dart` (remove `isExpanded` and `Breakpoints.expanded`)
- Modify: every importer of `adaptive_shell.dart` (~20 files — all are files this plan touches anyway)
- Test: `test/core/navigation/app_destination_test.dart` (create)

**Interfaces:**
- Consumes: `AppRoutes` constants and arg classes (unchanged)
- Produces: `sealed class AppDestination`, `enum HubTab {calendar, clients, employees, liveMap}`, `enum PushedDestination {dayRoute, history, dashboard, settings}`, `allDestinations`, `destinationByName(String)`, `destinationRoute(AppDestination, {...})`, `HubTabSelector` (now 3 methods), `HubShellScope` (+ `liveSelector`), `navigateToDestination`, `goHomeToCalendar(BuildContext)`

> **Naming decision: the enum member stays `employees`; only the *label* becomes "Team".** Reasons, in weight order: (1) the persisted tour-seen key and the showcase scope name both derive from `.name`, so a rename forces either a legacy-name mapping or a one-time tour replay for zero user-visible benefit; (2) "employee" is the domain noun everywhere else (`lib/features/employees/`, `employeeIds`, `employeeDocId`, `watchEmployees()`, the rules helpers) — a partial rename creates a third name; (3) P4 rewrites this screen anyway, so a deep rename belongs there. A new l10n key `nav_team` carries the label; `common_employees` is untouched.

- [x] **Step 1: Write the failing test**

Create `test/core/navigation/app_destination_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/navigation/app_destination.dart';

void main() {
  test('there are exactly four hub tabs', () {
    expect(HubTab.values, hasLength(4));
  });

  test('destination names are unique across both enums', () {
    // The names are also SharedPreferences seen-keys AND showcase scope
    // names, so a collision would be two silent bugs at once.
    final names = [for (final d in allDestinations) d.name];
    expect(names.toSet().length, names.length);
  });

  test('destinationByName round-trips every destination', () {
    for (final destination in allDestinations) {
      expect(destinationByName(destination.name), destination);
    }
    expect(destinationByName('nope'), isNull);
  });

  test('every destination resolves to a route', () {
    for (final destination in allDestinations) {
      final target = destinationRoute(
        destination,
        isAdmin: true,
        employeeId: 'e1',
      );
      expect(target.route, isNotEmpty);
    }
  });
}
```

- [x] **Step 2: Run it to confirm it fails**

```bash
flutter test test/core/navigation/app_destination_test.dart
```

Expected: FAIL — the library does not exist.

- [x] **Step 3: Create `lib/core/navigation/app_destination.dart`**

```dart
import 'package:scheduling/routes/app_routes.dart';

/// Anything the end drawer can navigate to. Sealed so switches stay
/// exhaustive; `implements Enum` so only enums can implement it and
/// `.name` works on the union type.
sealed class AppDestination implements Enum {}

/// The four persistent hub tabs (IndexedStack panes). The stack index is
/// [HubTab.index] — safe, because the stack children iterate
/// [HubTab.values], the same list the index derives from.
enum HubTab implements AppDestination { calendar, clients, employees, liveMap }

/// Destinations that push a plain route above the hub.
/// P5 adds `myDetails`; P6 adds `timeOff` — one member, one
/// [destinationRoute] case and one drawer row each, no restructure.
enum PushedDestination implements AppDestination {
  dayRoute,
  history,
  dashboard,
  settings,
}

/// Every destination. The seen store and [destinationByName] iterate this.
const List<AppDestination> allDestinations = [
  ...HubTab.values,
  ...PushedDestination.values,
];

/// Resolves a persisted `.name` back to its destination, or null for a name
/// that no longer exists.
AppDestination? destinationByName(String name) {
  for (final destination in allDestinations) {
    if (destination.name == name) return destination;
  }
  return null;
}

/// Route + typed args for a destination — the one mapping every nav surface
/// uses, so the drawer and outside-shell navigation cannot drift.
({String route, Object arguments}) destinationRoute(
  AppDestination destination, {
  required bool isAdmin,
  required String employeeId,
  String userName = '',
  String userEmail = '',
}) => switch (destination) {
  HubTab.calendar => (
    route: AppRoutes.mainCalendar,
    arguments: MainCalendarArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  HubTab.clients => (
    route: AppRoutes.clients,
    arguments: ClientsListArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  HubTab.employees => (
    route: AppRoutes.employees,
    arguments: MainCalendarArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  HubTab.liveMap => (
    route: AppRoutes.liveMap,
    arguments: MainCalendarArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.dayRoute => (
    route: AppRoutes.dayRoute,
    arguments: DayRouteArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.history => (
    route: AppRoutes.history,
    arguments: HistoryArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.dashboard => (
    route: AppRoutes.dashboard,
    arguments: DashboardArgs(
      isAdmin: isAdmin,
      employeeId: employeeId,
      userName: userName.isEmpty ? null : userName,
      email: userEmail.isEmpty ? null : userEmail,
    ),
  ),
  PushedDestination.settings => (
    route: AppRoutes.settings,
    arguments: SettingsArgs(
      name: userName,
      email: userEmail,
      role: isAdmin ? 'admin' : 'employee',
      employeeId: employeeId,
    ),
  ),
};
```

- [x] **Step 4: Create `lib/core/navigation/hub_shell_scope.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:scheduling/core/navigation/app_destination.dart';

/// Tab-switch contract, so core can drive navigation without importing the
/// routes layer's widgets.
abstract interface class HubTabSelector {
  /// Switches the visible hub tab, refreshing the identity args the hub
  /// screens are built from.
  void select(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName,
    String userEmail,
  });

  /// [select] plus a pop of everything stacked above the shell, so the
  /// chosen tab is actually revealed. No-op pop when nothing is stacked.
  void selectAndReveal(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName,
    String userEmail,
  });

  /// Calendar pill / go-home: [selectAndReveal] on the calendar tab using
  /// the shell's own sticky identity.
  void goHome();
}

/// Lets shell descendants reach the enclosing hub shell.
class HubShellScope extends InheritedWidget {
  const HubShellScope({
    required this.shell,
    required this.current,
    required super.child,
    super.key,
  });

  final HubTabSelector shell;
  final HubTab current;

  /// The most recently mounted shell, reachable from PUSHED routes — their
  /// subtree is a sibling overlay entry, so inheritance cannot find the
  /// scope. Set and cleared by HubShellState beside HubShell.liveState.
  static HubTabSelector? liveSelector;

  static HubTabSelector? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HubShellScope>()?.shell;

  /// The visible hub tab as a build dependency. Null outside the shell
  /// subtree — including on every pushed route.
  static HubTab? currentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HubShellScope>()?.current;

  /// One-shot read, no rebuild dependency — safe outside build.
  static HubTab? readCurrentOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HubShellScope>()?.current;

  @override
  bool updateShouldNotify(HubShellScope oldWidget) =>
      current != oldWidget.current || shell != oldWidget.shell;
}

/// The one nav action for changing destination. Hub tabs switch the tab
/// (revealing the shell first when invoked from a pushed route); pushed
/// destinations push, deduped against the current route.
void navigateToDestination(
  BuildContext context,
  AppDestination destination, {
  required bool isAdmin,
  required String employeeId,
  String userName = '',
  String userEmail = '',
}) {
  switch (destination) {
    case final HubTab tab:
      final scoped = HubShellScope.maybeOf(context);
      if (scoped != null) {
        // Inside the shell subtree — nothing is stacked above the shell.
        scoped.select(
          tab,
          isAdmin: isAdmin,
          employeeId: employeeId,
          userName: userName,
          userEmail: userEmail,
        );
        return;
      }
      final live = HubShellScope.liveSelector;
      if (live != null) {
        // A pushed route — collapse to the shell, then switch.
        live.selectAndReveal(
          tab,
          isAdmin: isAdmin,
          employeeId: employeeId,
          userName: userName,
          userEmail: userEmail,
        );
        return;
      }
      final target = destinationRoute(
        tab,
        isAdmin: isAdmin,
        employeeId: employeeId,
        userName: userName,
        userEmail: userEmail,
      );
      Navigator.pushReplacementNamed(
        context,
        target.route,
        arguments: target.arguments,
      );
    case final PushedDestination pushed:
      final target = destinationRoute(
        pushed,
        isAdmin: isAdmin,
        employeeId: employeeId,
        userName: userName,
        userEmail: userEmail,
      );
      // Re-tapping the drawer row for the screen you are on is a no-op.
      if (ModalRoute.settingsOf(context)?.name == target.route) return;
      Navigator.pushNamed(context, target.route, arguments: target.arguments);
  }
}

/// Calendar pill / drawer Calendar row: close the invoking surface's end
/// drawer, land on the calendar tab, collapse everything above the shell.
/// One canonical gesture — never hand-roll the parts.
void goHomeToCalendar(BuildContext context) {
  Scaffold.maybeOf(context)?.closeEndDrawer();
  final selector = HubShellScope.maybeOf(context) ?? HubShellScope.liveSelector;
  selector?.goHome();
}
```

> **Why `selectAndReveal` is mandatory, not a nicety.** From a pushed stack two deep (Dashboard → History), a drawer tap on a hub row using the old `pushReplacementNamed` path replaces *History* with the redirect route, which selects the tab and removes itself — leaving **Dashboard on top**. The user asked for Clients and sees Dashboard. Collapse-then-select is the only shape correct at any stack depth. `HubShellScope.liveSelector` exists for the same reason: a pushed route cannot reach the scope by inheritance.

- [x] **Step 5: Delete the rail and its only breakpoint**

Delete `lib/core/layout/adaptive_shell.dart` entirely (`AdaptiveShell` and `_RailEntry` die; the four type/function members it also held now live in the two new files). In `lib/core/layout/breakpoints.dart` remove `static const double expanded = 1200;` and the `bool get isExpanded` getter — `AdaptiveShell` lines 185 and 187 were their only consumers in `lib/`, and `test/` has zero.

**`isSplitLayout` survives** — it still gates `SettingsDrawer.endDrawerFor` (until Task C2 replaces that) and the calendar's month|agenda split. **`isTwoPane` survives untouched** — it gates list master-detail. Do not conflate them.

- [x] **Step 6: Repoint every importer**

```bash
grep -rln "core/layout/adaptive_shell.dart" lib/ test/
```

Each file swaps to `package:scheduling/core/navigation/app_destination.dart` and/or `.../hub_shell_scope.dart`, and every `AdaptiveDestination.x` becomes `HubTab.x` or `PushedDestination.x`. The compiler finds the rest.

- [x] **Step 7: Run the tests**

```bash
flutter test test/core/navigation/app_destination_test.dart
flutter analyze 2>&1 | grep -E "error -|warning -"
```

Expected: the new test passes. Analyzer errors remain in `hub_shell.dart`, `app_routes.dart` and the tour files — those are Tasks B2–B4. **This task does not end green on its own**; it is the type-level half of an atomic change. Commit it anyway so the diff stays reviewable, and treat B1–B4 as one landing unit that must be green before Phase C.

- [x] **Step 8: Commit**

```bash
git add lib/core test/core
git commit -m "feat(p1): split AdaptiveDestination into HubTab and PushedDestination, delete the nav rail"
```

---

## Task B2: Retype the hub shell and add the go-home helper

**Files:**
- Modify: `lib/routes/hub_shell.dart` (336 lines)
- Test: `test/routes/hub_shell_test.dart` (update two tests, add one)

**Interfaces:**
- Consumes: `HubTab`, `HubTabSelector`, `HubShellScope` (Task B1)
- Produces: `HubShell({required bool isAdmin, required String employeeId, HubTab initialTab, String userName, String userEmail, Widget Function(HubTab)? screenBuilder})`, `HubShellState` implementing all three `HubTabSelector` methods, `HubShell.liveState`, `HubShellState.currentTab`

- [x] **Step 1: Write the failing test**

Add to `test/routes/hub_shell_test.dart`:

```dart
  testWidgets('goHome pops back to the shell route and lands on calendar',
      (tester) async {
    await tester.pumpWidget(_app(initialTab: HubTab.clients));
    await tester.pump();
    expect(find.text('screen-clients'), findsOneWidget);

    // Stack two routes above the shell.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('pushed-one')),
    )));
    await tester.pumpAndSettle();
    unawaited(navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('pushed-two')),
    )));
    await tester.pumpAndSettle();
    expect(find.text('pushed-two'), findsOneWidget);

    HubShell.liveState!.goHome();
    await tester.pumpAndSettle();

    expect(find.text('pushed-one'), findsNothing);
    expect(find.text('pushed-two'), findsNothing);
    expect(find.text('screen-calendar'), findsOneWidget);
    expect(HubShell.liveState!.currentTab, HubTab.calendar);
  });
```

- [x] **Step 2: Run it to confirm it fails**

```bash
flutter test test/routes/hub_shell_test.dart
```

Expected: FAIL to compile — `HubTab`, `initialTab`, `currentTab` and `goHome` do not exist yet.

- [x] **Step 3: Retype the widget and state**

```dart
class HubShell extends StatefulWidget {
  const HubShell({
    required this.isAdmin,
    required this.employeeId,
    this.initialTab = HubTab.calendar,
    this.userName = '',
    this.userEmail = '',
    super.key,
    @visibleForTesting this.screenBuilder,
  });

  final HubTab initialTab;
  final Widget Function(HubTab tab)? screenBuilder;
  // isAdmin / employeeId / userName / userEmail unchanged

  static HubShellState? get liveState => HubShellState._live;
}
```

In `HubShellState`: `late HubTab _current = widget.initialTab;`, `late final Set<HubTab> _built = {widget.initialTab};`, `HubTab get currentTab => _current;`, `_screenCache` becomes `Map<HubTab, Widget>`. `select` keeps its body with the parameter retyped to `HubTab`. `_screenFor` drops its `history` and `settings` cases (and the `HistoryScreen` / `SettingsScreen` imports leave this file):

```dart
  Widget _screenFor(HubTab tab) {
    final builder = widget.screenBuilder;
    if (builder != null) return builder(tab);
    final key = ValueKey('hub-${tab.name}-$_isAdmin-$_employeeId');
    return switch (tab) {
      HubTab.calendar =>
        MainCalendar(key: key, isAdmin: _isAdmin, employeeId: _employeeId),
      HubTab.clients =>
        ListInformation(key: key, isAdmin: _isAdmin, employeeId: _employeeId),
      HubTab.employees =>
        AddEmployeePage(key: key, isAdmin: _isAdmin, employeeId: _employeeId),
      HubTab.liveMap =>
        LiveMapScreen(key: key, isAdmin: _isAdmin, employeeId: _employeeId),
    };
  }
```

`PopScope(canPop: _current == HubTab.calendar, ...)`, `showCalendar()`, `_handlePop` and the `_withBackSwipe` call-site exemption all repoint to `HubTab.calendar`. The `IndexedStack` becomes `for (final tab in HubTab.values)`.

- [x] **Step 4: Mirror the live selector and capture the shell's route**

```dart
  @override
  void initState() {
    super.initState();
    _live = this;
    HubShellScope.liveSelector = this;
  }

  @override
  void dispose() {
    if (_live == this) _live = null;
    if (HubShellScope.liveSelector == this) HubShellScope.liveSelector = null;
    super.dispose();
  }

  /// The shell's own route — [goHome]'s pop target. Null only in a bare test
  /// harness with no enclosing route.
  ModalRoute<dynamic>? _shellRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shellRoute = ModalRoute.of(context);
  }
```

> **`didChangeDependencies`, not `initState`.** `ModalRoute.of` calls `dependOnInheritedWidgetOfExactType`, which is a framework assert failure in `initState`. Re-runs are harmless — the shell's route identity is stable for its lifetime. The registered dependency costs one shell rebuild whenever a route is pushed or popped above it (its `isCurrent` flips); that is cheap because `build()` is backed by `_screenCache`.

- [x] **Step 5: Implement the three selector methods**

```dart
  @override
  void selectAndReveal(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {
    select(
      tab,
      isAdmin: isAdmin,
      employeeId: employeeId,
      userName: userName,
      userEmail: userEmail,
    );
    _popToShell();
  }

  @override
  void goHome() {
    showCalendar();
    _popToShell();
  }

  void _popToShell() {
    if (!mounted) return;
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return;
    final shellRoute = _shellRoute;
    // Null capture happens only in a bare harness; there the shell IS first.
    navigator.popUntil(
      shellRoute != null
          ? (route) => route == shellRoute
          : (route) => route.isFirst,
    );
  }
```

> **Select before pop** so the revealed shell is already on the target tab — no flash of the previous one. `popUntil((r) => r == shellRoute)` cannot spin: `goHome` only runs on a live shell state, and that state lives *inside* the shell route, so the route is provably in the stack. **Never `popUntil((r) => r.isFirst)`** — on `_hubRoute`'s fallback branch the shell is not route #1, so that predicate pops the shell itself and strands the user below it.

- [x] **Step 6: Update the two breaking tests**

`.settings` and `.history` are no longer selectable. In `test/routes/hub_shell_test.dart`, substitute remaining non-calendar tabs and retype the stub builder to `Widget Function(HubTab)`:

- `'system back on a non-calendar tab returns to the calendar tab instead of popping the root route'` — `AdaptiveDestination.settings` → `HubTab.liveMap`; the `find.text('screen-settings')` expectation → `find.text('screen-liveMap')`; `currentDestination` → `currentTab`.
- `'navigateToDestination inside the shell switches tabs without touching the navigator stack'` — `AdaptiveDestination.history` → `HubTab.employees`; `find.text('back-history')` → `find.text('back-employees')`.

- [x] **Step 7: Run the tests**

```bash
flutter test test/routes/hub_shell_test.dart
```

Expected: PASS, including the new `goHome` test.

- [x] **Step 8: Commit**

```bash
git add lib/routes/hub_shell.dart test/routes/hub_shell_test.dart
git commit -m "feat(p1): retype the hub shell to HubTab and add the go-home helper"
```

---

## Task B3: Make History and Settings pushed routes

**Files:**
- Modify: `lib/routes/app_routes.dart` (the `history` case lines 93–100, the `settings` case lines 111–121, `_hubRoute` lines 130–158)

**Interfaces:**
- Consumes: `HubTab` (Task B1)
- Produces: `AppRoutes.history` and `AppRoutes.settings` resolving to `AppPageRoute`

- [x] **Step 1: Convert both cases**

```dart
      case history:
        final args = settings.arguments! as HistoryArgs;
        return AppPageRoute(
          settings: settings,
          builder: (_) => HistoryScreen(
            isAdmin: args.isAdmin,
            employeeId: args.employeeId,
          ),
        );

      case AppRoutes.settings:
        final args = settings.arguments! as SettingsArgs;
        return AppPageRoute(
          settings: settings,
          builder: (_) => SettingsScreen(
            name: args.name,
            email: args.email,
            role: args.role,
            employeeId: args.employeeId,
          ),
        );
```

Add the two screen imports to `app_routes.dart` (they leave `hub_shell.dart` in Task B2).

- [x] **Step 2: Retype `_hubRoute`**

Its second positional parameter becomes `HubTab`; the fallback branch builds `HubShell(initialTab: tab, ...)`. The `employees`, `clients` and `liveMap` cases keep calling it with `HubTab.employees` etc.; `mainCalendar` is unchanged.

> **Keep `_hubRoute` and `HubTabRedirectRoute`.** They shrink to three tab routes and look like dead code once the drawer stops pushing named hub routes, but the redirect behaviour is pinned by `hub_shell_test.dart` and remains the cold-start fallback for a named push with no live shell. Do not delete in P1.

- [x] **Step 3: Verify**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test test/routes/
```

Expected: analyzer clean for `lib/routes/`; remaining errors are confined to the tour files (Task B4).

- [x] **Step 4: Commit**

```bash
git add lib/routes/app_routes.dart
git commit -m "feat(p1): route History and Settings as pushed pages"
```

---

## Task B4: Widen the feature tours to pushed routes

**Files:**
- Modify: `lib/features/feature_tour/widgets/feature_tour_host.dart`
- Modify: `lib/features/feature_tour/domain/tour_definitions.dart`
- Modify: `lib/features/feature_tour/application/tour_seen_store.dart`
- Modify: `lib/features/feature_tour/widgets/tour_showcase.dart` (param rename)
- Test: `test/features/feature_tour/domain/tour_definitions_test.dart`, `test/features/feature_tour/widgets/feature_tour_host_test.dart`

**Interfaces:**
- Consumes: `AppDestination`, `HubTab`, `PushedDestination`, `allDestinations` (Task B1)
- Produces: `FeatureTourHost({required AppDestination destination, ...})`, `tourScopeName(AppDestination)`, `tourStepsFor(AppDestination, {required bool isAdmin})`, `TourSeenController extends Notifier<Set<AppDestination>>`

**The problem:** `FeatureTourHost`'s gate is `HubShellScope.currentOf(context) == widget.tab`, which is **null on a pushed route** — the Settings and History tours would silently never start. Settings is one of only two employee tours.

**The fix:** the destination's own sealed type selects the gate mode. No explicit mode parameter, and *not* inferred from a null `HubShellScope` — a null scope is ambiguous, since it also describes a hub screen hosted standalone in a test, where the current "never start" behaviour must be preserved.

- [x] **Step 1: Rewrite the two breaking assertions**

In `test/features/feature_tour/domain/tour_definitions_test.dart`. The old "every enum value has an admin tour" forcing function is genuinely dead now (`dayRoute` and `dashboard` mount no tour host), but the exhaustive sweep is kept so a *new* destination still forces an explicit decision:

```dart
  /// Destinations that mount a FeatureTourHost. A new destination must
  /// either join this set with a catalog, or keep an empty one.
  const toured = <AppDestination>{
    HubTab.calendar,
    HubTab.clients,
    HubTab.employees,
    HubTab.liveMap,
    PushedDestination.history,
    PushedDestination.settings,
  };

  test('every toured destination has an admin tour and no catalog has '
      'duplicates', () {
    for (final destination in allDestinations) {
      final steps = tourStepsFor(destination, isAdmin: true);
      if (toured.contains(destination)) {
        expect(steps, isNotEmpty,
            reason: '$destination should have an admin tour');
      } else {
        expect(steps, isEmpty, reason: '$destination has no tour host');
      }
      expect(steps.toSet().length, steps.length,
          reason: '$destination catalog has duplicate steps');
    }
  });

  test('employee tours exist only for calendar and settings', () {
    for (final destination in allDestinations) {
      final steps = tourStepsFor(destination, isAdmin: false);
      if (destination == HubTab.calendar ||
          destination == PushedDestination.settings) {
        expect(steps, isNotEmpty,
            reason: '$destination should have an employee tour');
      } else {
        expect(steps, isEmpty, reason: '$destination is admin-only');
      }
    }
  });
```

- [x] **Step 2: Run to confirm it fails**

```bash
flutter test test/features/feature_tour/domain/tour_definitions_test.dart
```

Expected: FAIL to compile — `tourStepsFor` still takes `AdaptiveDestination`.

- [x] **Step 3: Widen the definitions and the seen store**

```dart
String tourScopeName(AppDestination destination) => 'tour_${destination.name}';

List<TourStepId> tourStepsFor(
  AppDestination destination, {
  required bool isAdmin,
}) => switch (destination) {
  HubTab.calendar => [
    TourStepId.calendarGrid,
    TourStepId.calendarDayList,
    if (isAdmin) TourStepId.calendarAddAppointment,
    TourStepId.calendarDayRoute,
  ],
  HubTab.clients => [
    if (isAdmin) ...[TourStepId.clientsSearch, TourStepId.clientsAdd],
  ],
  HubTab.employees => [
    if (isAdmin) ...[TourStepId.employeesSearch, TourStepId.employeesAdd],
  ],
  HubTab.liveMap => [
    if (isAdmin) ...[TourStepId.liveMapRoster, TourStepId.liveMapRecenter],
  ],
  PushedDestination.history => [if (isAdmin) TourStepId.historySearch],
  PushedDestination.settings => [
    TourStepId.settingsAppearance,
    TourStepId.settingsNotifications,
    TourStepId.settingsReplay,
  ],
  PushedDestination.dayRoute => const [],
  PushedDestination.dashboard => const [],
};
```

`TourSeenController extends Notifier<Set<AppDestination>>`; `tourSeenProvider` and `markSeen(AppDestination)` retype to match. `_load` becomes lookup-based and drops unknown names:

```dart
      state = {
        for (final name in names)
          if (destinationByName(name) case final destination?) destination,
      };
```

> **No SharedPreferences migration is needed — and that is by design, not luck.** The key stays `'tour_seen_tabs'` and the value space (`calendar, clients, employees, history, liveMap, settings`) is preserved *because* Task B1 kept the member name `employees` and both enums kept today's names. Any future member rename must either add a legacy-name mapping here or knowingly accept a one-time replay of that one tour. The uniqueness test added in B1 pins the invariant.

- [x] **Step 4: Add the sealed-type gate to `FeatureTourHost`**

Rename the field `tab` → `destination` (type `AppDestination`) and add:

```dart
  /// Captured each build in route mode. ModalRoute.of cannot be called from
  /// a post-frame callback without registering a spurious dependency, so
  /// the one-shot recheck reads this field instead.
  ModalRoute<Object?>? _route;

  bool _isVisible(BuildContext context) {
    switch (widget.destination) {
      case final HubTab tab:
        return HubShellScope.currentOf(context) == tab;
      case PushedDestination():
        final route = ModalRoute.of(context);
        _route = route;
        return route?.isCurrent ?? false;
    }
  }
```

`build()` changes one line: `final visible = _isVisible(context);`. The post-frame recheck inside `_start()` becomes:

```dart
      final stillVisible = switch (widget.destination) {
        final HubTab tab => HubShellScope.readCurrentOf(context) == tab,
        PushedDestination() => _route?.isCurrent ?? false,
      };
      if (!stillVisible) {
        _started = false; // Re-arm for the next visibility rebuild.
        return;
      }
```

> **`ModalRoute.of` in `build()` is safe here and is load-bearing.** It depends on the route's `_ModalScopeStatus`, which notifies on `isCurrent`/`canPop`/identity changes — not per animation frame. That dependency is the *only* rebuild trigger route mode has (`HubShellScope` never changes for a pushed screen), and it is what re-opens the start gate when a route above pops.
>
> **A modal sheet over a pushed screen** is a navigator route, so `isCurrent` flips false. Idle: the gate stays closed and the sheet-close flip provides the retry rebuild — no wedge. Mid-tour: the existing `_wasVisible && !visible && _tourRunning` branch dismisses and marks seen. That is **identical to today's mid-tour tab-switch policy**, deliberately inherited — state it in review so it is not "fixed" later.

- [x] **Step 5: Wait out the route entrance transition before measuring**

Hub tabs never move, but a pushed Settings slides in over ~300 ms, and showcaseview measures target `GlobalKey`s when `startShowCase` runs. Without this, the first-ever Settings visit (a fresh install's employee tour) paints mis-placed cutouts. In `_start()`, after the `ready` await and before the post-frame callback:

```dart
    await _routeTransitionSettled();
    if (!mounted) return;
```

```dart
  /// Route mode only (hub mode never sets _route): waits out the page's
  /// entrance transition so showcase measures settled target positions.
  Future<void> _routeTransitionSettled() async {
    final animation = _route?.animation;
    if (animation == null || !animation.isAnimating) return;
    final completer = Completer<void>();
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        return;
      }
      animation.removeStatusListener(onStatus);
      if (!completer.isCompleted) completer.complete();
    }
    animation.addStatusListener(onStatus);
    await completer.future;
  }
```

- [x] **Step 6: Rename the `TourShowcase` parameter**

`TourShowcase`'s `tab` field becomes `final AppDestination destination;`, rippling to every step call site (~a dozen, all mechanical, all in screens this plan touches).

- [x] **Step 7: Add a route-mode host test**

In `test/features/feature_tour/widgets/feature_tour_host_test.dart`, add a test that pumps a `FeatureTourHost(destination: PushedDestination.settings, ...)` inside a pushed `MaterialPageRoute`, pushes a second route on top, and asserts the tour does not start; then pops and asserts it does. The existing fake `HubTabSelector` must gain the two new methods (`selectAndReveal`, `goHome`).

- [x] **Step 8: Run the tests**

```bash
flutter test test/features/feature_tour/
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test
```

Expected: **the whole suite is green here** — B1–B4 land as one unit.

- [x] **Step 9: Commit**

```bash
git add lib/features/feature_tour test/features/feature_tour
git commit -m "feat(p1): gate feature tours by route when the destination is pushed"
```

---

## Task B5: Point the appointment deep link at the go-home helper

**Files:**
- Modify: `lib/main.dart` (`_openAppointmentDeepLink`, line ~280)

- [x] **Step 1: Replace the pop**

```dart
    // Collapse stacked routes to open the appointment over the shell.
    shell.goHome();
```

replacing `_navigatorKey.currentState?.popUntil((route) => route.isFirst);`. The earlier `shell.showCalendar()` at line ~272 stays (it flips the tab immediately while the record fetch races); `goHome()`'s re-select is an idempotent no-op that does not clear the screen cache.

> **Why:** the existing line carries exactly the latent bug the program spec flagged — on `_hubRoute`'s fallback branch the shell is not route #1, so `popUntil(isFirst)` pops the shell itself and strands the user. The handler already holds the `HubShellState` from `_awaitLiveHub()`, so no new lookup is needed. One pre-existing gap is unchanged: neither the old line nor `goHome()` closes a drawer left open on a tab screen under a deep link.

- [x] **Step 2: Verify**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test test/routes/ test/features/notifications/
```

- [x] **Step 3: Commit**

```bash
git add lib/main.dart
git commit -m "fix(p1): collapse to the shell route on appointment deep links"
```

---

# Phase C — The new chrome

## Task C1: The header pair

**Files:**
- Create: `lib/shared/widgets/app_bars/app_header_pair.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- Test: `test/shared/widgets/app_bars/app_header_pair_test.dart` (create)

**Interfaces:**
- Consumes: `goHomeToCalendar(BuildContext)` (Task B1), `theme.palette`, `AppRadius.rIcon`
- Produces: `AppHeaderPair({bool showBack = false})` — a `Row` of `[Calendar pill, hamburger]` for `AppTopBar.actions`; `AppHeaderBackButton` for the leading slot

**Design:** icon button **38×38** visual, radius 12, `blueTint` fill, blue glyph, pressed `blueTintHover`. Calendar pill **auto × 38** visual, radius 99, padding `8/13/8/11`, blue-tint fill, 15px calendar glyph + "Calendar" 12.5/600 blue. Back chevron **36×36** visual, radius 12, transparent, pressed `paper`.

> **Visual size is not hit area.** Every control here is below the 48×48 minimum. Wrap each in a `SizedBox(width: 48, height: 48)` (or give the `InkResponse` a 24 radius) centring the smaller painted box. Never shrink the hit region to match the mock.

- [x] **Step 1: Add the l10n keys**

To `lib/l10n/app_en.arb` (with `@key` blocks) and `lib/l10n/app_fr.arb` in lockstep:

| Key | EN | FR |
| --- | --- | --- |
| `nav_goToCalendar` | Calendar | Calendrier |
| `nav_openMenu` | Open menu | Ouvrir le menu |
| `nav_team` | Team | Équipe |
| `nav_dayRoute` | Day route | Itinéraire du jour |
| `nav_dashboard` | Dashboard | Tableau de bord |
| `nav_myDetails` | My details | Mes informations |
| `nav_groupToday` | TODAY | AUJOURD'HUI |
| `nav_groupPeople` | PEOPLE | PERSONNES |
| `nav_groupBusiness` | THE BUSINESS | L'ENTREPRISE |
| `nav_groupAccount` | ACCOUNT | COMPTE |

Each `@key` block needs a `description`. The group labels are rendered uppercase by the mono `groupLabel` style but stored uppercase here so the FR accent (`AUJOURD'HUI`) is authored correctly rather than produced by `toUpperCase()`. The ARB hook regenerates l10n — do not run `flutter gen-l10n`.

- [x] **Step 2: Write the failing test**

```dart
  testWidgets('the calendar pill and menu button meet the 48px tap minimum',
      (tester) async {
    await tester.pumpWidget(_wrap(const AppHeaderPair()));
    for (final finder in [
      find.byTooltip('Calendar'),
      find.byTooltip('Open menu'),
    ]) {
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('tapping the menu button opens the end drawer', (tester) async {
    await tester.pumpWidget(_wrapWithDrawer(const AppHeaderPair()));
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('drawer-content'), findsOneWidget);
  });

  testWidgets('the pair survives text scale 2.0 without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_wrap(const AppHeaderPair(), textScale: 2.0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
```

- [x] **Step 3: Run to confirm it fails**

```bash
flutter test test/shared/widgets/app_bars/app_header_pair_test.dart
```

Expected: FAIL — `AppHeaderPair` does not exist.

- [x] **Step 4: Build the widget**

`AppHeaderPair` is a `StatelessWidget` rendering a `Row(mainAxisSize: MainAxisSize.min, children: [_CalendarPill(), SizedBox(width: 6), _MenuButton()])`.

- The pill's `onTap` is `() => goHomeToCalendar(context)` — the one canonical go-home gesture. It carries `Semantics`/`tooltip: l10n.nav_goToCalendar`.
- The menu button's `onTap` is `() => Scaffold.of(context).openEndDrawer()`, tooltip `l10n.nav_openMenu`. **Use `Scaffold.of(context)`, not a `GlobalKey`** — the header pair sits inside its screen's Scaffold subtree, so the lookup resolves without any per-screen key plumbing. This is what lets Task C3 skip adding 7 scaffold keys.
- The pill's label must not force overflow at large scale: give the `Text` `overflow: TextOverflow.ellipsis` inside a `Flexible`, and let the 38px visual height grow from the scaled text rather than being a fixed `height: 38`. Use `ConstrainedBox(constraints: BoxConstraints(minHeight: 38))`.
- Colours: fill `theme.colorScheme.primaryContainer`, glyph and label `theme.colorScheme.onPrimaryContainer`, pressed overlay `theme.palette.blueTintPressed`.

`AppHeaderBackButton` is the leading-slot variant: 36×36 visual in a 48×48 target, transparent, `onTap: () => Navigator.maybePop(context)`.

- [x] **Step 5: Run the tests**

```bash
flutter test test/shared/widgets/app_bars/app_header_pair_test.dart
```

Expected: PASS, 3 tests.

- [x] **Step 6: Commit**

```bash
git add lib/shared/widgets/app_bars/app_header_pair.dart lib/l10n test
git commit -m "feat(p1): add the calendar-pill and hamburger header pair"
```

---

## Task C2: The grouped end drawer

**Files:**
- Create: `lib/features/navigation/widgets/app_nav_drawer.dart`
- Create: `lib/features/navigation/domain/drawer_catalog.dart`
- Delete: `lib/features/settings/widgets/views/settings_drawer.dart`
- Test: `test/features/navigation/domain/drawer_catalog_test.dart` (create), `test/features/navigation/widgets/app_nav_drawer_test.dart` (create)

**Interfaces:**
- Consumes: `AppDestination`, `navigateToDestination`, `goHomeToCalendar`, `theme.monoType.groupLabel`, `theme.cardStyle.drawerShadow`, `currentUserNameProvider`, `userRoleProvider`
- Produces: `AppNavDrawer({required bool isAdmin, required String employeeId, String? userName, String? email})`, `drawerGroups({required bool isAdmin})`

**Design:** right-anchored, **284px** wide, full height, `surface`, `cardStyle.drawerShadow`, over a `rgba(11,26,51,.42)` scrim, 260ms. Header: `SafeArea` top + 20px horizontal + 18px bottom, bottom hairline — 42px avatar + name (15.5/600) + `"<Role> · <brandName>"` (12px, `palette.textTertiary`). Items: padding `14/12/20`, **16px between groups**, 2px between rows; each row `12px 13px`, radius `AppRadius.rRow` (13) — a 9px rounded colour square, label 14.5/600, optional mono count right-aligned. Active row: `primaryContainer` fill, `onPrimaryContainer` label. Group labels use `theme.monoType.groupLabel` in `palette.textMuted`, padding `0 13px 7px`. Version string pinned at the bottom in `theme.monoType.micro`, `palette.textFaint`.

> **`brandName` is a proper noun — never localize it**, and the in-app wordmark stays "Plombier Eau Secours!" (distinct from the "ES Pro" launcher name; do not unify).

> **The counts cost nothing while the drawer is closed.** Verified against the Flutter SDK 2026-07-30: `_DrawerControllerState._buildDrawer` returns `SizedBox.shrink()` (or a bare drag-detector) while `_controller.isDismissed`, so the drawer's child is **never built** until it opens. A `ref.watch` of an `.autoDispose` count provider inside the drawer body therefore subscribes only while the drawer is open and tears down after it closes. **Do not add an "is the drawer open" flag or an `onEndDrawerChanged` hook to work around a cost that does not exist.**

- [x] **Step 1: Write the failing catalog test**

```dart
  test('an admin sees ten rows in four groups', () {
    final groups = drawerGroups(isAdmin: true);
    expect(groups, hasLength(4));
    expect(groups.expand((g) => g.rows), hasLength(8)); // 10 once P5+P6 land
  });

  test('an employee sees only TODAY and ACCOUNT', () {
    final groups = drawerGroups(isAdmin: false);
    final rows = groups.expand((g) => g.rows).toList();
    expect(rows, contains(HubTab.calendar));
    expect(rows, contains(PushedDestination.dayRoute));
    expect(rows, contains(PushedDestination.settings));
    expect(rows, isNot(contains(HubTab.clients)));
    expect(rows, isNot(contains(HubTab.employees)));
    expect(rows, isNot(contains(HubTab.liveMap)));
    expect(rows, isNot(contains(PushedDestination.dashboard)));
    expect(rows, isNot(contains(PushedDestination.history)));
  });
```

- [x] **Step 2: Write the catalog**

```dart
typedef DrawerGroup = ({String Function(AppLocalizations) title,
                        List<AppDestination> rows});

/// Grouped drawer rows for a role, grouped by WHEN you would reach for
/// them, not by object type. Employees get TODAY + ACCOUNT only.
List<DrawerGroup> drawerGroups({required bool isAdmin}) => [
  (
    title: (l10n) => l10n.nav_groupToday,
    rows: [
      HubTab.calendar,
      PushedDestination.dayRoute,
      if (isAdmin) HubTab.liveMap,
    ],
  ),
  if (isAdmin)
    (
      title: (l10n) => l10n.nav_groupPeople,
      // PushedDestination.timeOff joins here in P6.
      rows: [HubTab.employees, HubTab.clients],
    ),
  if (isAdmin)
    (
      title: (l10n) => l10n.nav_groupBusiness,
      rows: [PushedDestination.dashboard, PushedDestination.history],
    ),
  (
    title: (l10n) => l10n.nav_groupAccount,
    // PushedDestination.myDetails joins here in P5.
    rows: [PushedDestination.settings],
  ),
];
```

Dot colours and labels stay drawer-local render concerns (the destination enum stays presentation-free). Per `02-navigation.md`: Calendar `#005CC8` · Day route `#D61F3A` · Live map `#00A5C4` · Team `#0E9B6E` · Time off `#00A5C4` · Clients `#7A3FF2` · Dashboard `#E08A00` · History `#C43F8E` · My details `#8A99B0` · Settings `#5A6B85`. **These are crew-palette hues used as decoration — resolve each through `crewColorOf(theme, hex)`** so they lift in dark like everything else.

- [x] **Step 3: Build `AppNavDrawer`**

Every row's handler is the same shape regardless of whether the row is a tab or a pushed page:

```dart
  void _go(BuildContext context, AppDestination destination) {
    Scaffold.of(context).closeEndDrawer();
    if (destination == HubTab.calendar) {
      goHomeToCalendar(context);
      return;
    }
    navigateToDestination(
      context,
      destination,
      isAdmin: isAdmin,
      employeeId: employeeId,
      userName: userName ?? '',
      userEmail: email ?? '',
    );
  }
```

The Calendar row routes through `goHomeToCalendar` rather than plain `navigateToDestination` so it also collapses any pushed stack — "no screen is a dead end."

Active-row highlight: compare against `HubShellScope.readCurrentOf(context)` for tabs and `ModalRoute.settingsOf(context)?.name` for pushed rows.

Header identity reads `ref.watch(currentUserNameProvider)` and `ref.watch(userRoleProvider)` — both derive from the app-wide, already-subscribed `currentUserDocProvider`, so they add no stream. **Never feed the header through `select()`** — that would nuke the hub's screen cache mid-session.

Counts: Calendar watches an `.autoDispose` today-range provider (`appointmentsInRangeProvider` for admins, `myAppointmentsProvider` for employees, range `today..tomorrow`, keyed off `ref.watch(currentDayProvider)` so it re-buckets at midnight) and renders `list.length`. Live map watches `liveMapPointsProvider` + `liveMapTickProvider` and renders the **fresh-only** count:

```dart
    final points = ref.watch(liveMapPointsProvider).value ?? const [];
    ref.watch(liveMapTickProvider); // recompute every 30 s
    final now = ref.watch(liveMapClockProvider)();
    final onTheClock =
        points.where((p) => !LiveMapAggregator.isStale(p.updatedAt, now)).length;
```

A null/absent count renders **nothing** (the empty-omitted rule) — that is also how the Time off row behaves until P6 supplies its provider.

- [x] **Step 4: Delete `SettingsDrawer`**

Remove the file and its six `endDrawer: SettingsDrawer.endDrawerFor(...)` call sites (they are replaced in Task C3). **`endDrawerFor`'s null-on-split-layout behaviour dies with it** — the drawer is now the nav surface at every size, per program decision 4.

- [x] **Step 5: Run the tests**

```bash
flutter test test/features/navigation/
```

- [x] **Step 6: Commit**

```bash
git add lib/features/navigation test/features/navigation
git rm lib/features/settings/widgets/views/settings_drawer.dart
git commit -m "feat(p1): add the grouped right-anchored nav drawer"
```

---

## Task C3: Wire the header pair and drawer into every screen

**Files (9 `AppTopBar` call sites):**
- `lib/features/calendar/screens/main_calendar_screen.dart:316`
- `lib/features/dashboard/screens/dashboard_screen.dart:73`
- `lib/features/clients/screens/history_screen.dart:67`
- `lib/features/clients/screens/clients_screen.dart:104`
- `lib/features/employees/screens/employees_screen.dart:149`
- `lib/features/presence/screens/live_map_screen.dart:162`
- `lib/features/settings/screens/settings_screen.dart:335`
- `lib/features/calendar/screens/day_route_screen.dart:119`
- `lib/features/settings/screens/text_size_screen.dart:13`

- [x] **Step 1: Give every screen the drawer and the pair**

For each: `endDrawer: AppNavDrawer(isAdmin: ..., employeeId: ..., userName: ..., email: ...)` and `AppTopBar(..., actions: const [AppHeaderPair()])`. **Settings, Day route and text-size gain a drawer for the first time.**

Because `AppHeaderPair` calls `Scaffold.of(context)`, **no screen needs a `GlobalKey<ScaffoldState>`.** Delete the two hand-rolled ones (`main_calendar_screen.dart:47`, `dashboard_screen.dart:45`) along with their manual menu `IconButton`s, unless the key is used for something else in that file — check before removing.

> Placing the pair in `actions` suppresses Flutter's automatic `EndDrawerButton` (four screens relied on it today). That is intended: the pair *is* the replacement, and it is now uniform across all nine screens.

Pushed screens get a back chevron: `AppTopBar(onBack: ...)` already renders `AppBackButton`; switch pushed screens to `AppHeaderBackButton` for the new styling. Settings and History currently call `navigateToDestination(calendar)` for their back affordance (`settings_screen.dart:338`, `history_screen.dart:48`) — **these become plain `Navigator.maybePop(context)`**, since they are pushed routes now and back means back, not go-home. The Calendar pill covers go-home.

- [x] **Step 2: Scope the pushed routes' scroll controllers**

History, Settings, Dashboard, Day route and the text-size sub-page each wrap their scrollable in `PrimaryScrollScope`. A pushed route sits above the tab scopes and would otherwise attach to the root `PrimaryScrollController`, throwing "attached to more than one ScrollPosition" against the app-wide `Scrollbar`.

- [x] **Step 3: Check the FAB hero tags**

Current set: `addFab`, `todayFab` (calendar), `clientsAddFab`, `employeesAddFab`, `liveMapRosterFab`, `liveMapRecenterFab`. History and Settings have no FAB, so the restructure changes nothing — but confirm no new duplicate appeared:

```bash
grep -rn "heroTag" lib/
```

- [x] **Step 4: Verify**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
flutter test
```

Fix any screen test that asserted on the old `EndDrawerButton` or `SettingsDrawer`.

- [x] **Step 5: Commit**

```bash
git add lib test
git commit -m "feat(p1): wire the header pair and nav drawer into every screen"
```

---

## Task C4: Restyle the notice as the dark pill

**Files:**
- Modify: `lib/core/notices/notice_listener.dart` (255 lines)
- Modify: `lib/core/theme/design_tokens.dart` (nothing new — `AppMotion.noticeCycle` landed in A2)
- Test: `test/core/notices/notice_banner_test.dart`

**Interfaces:**
- Consumes: `scheme.inverseSurface` / `onInverseSurface`, `palette.noticeMint` / `noticeInfo` / `noticeRed`, `cardStyle.noticeShadow`, `AppMotion.noticeCycle`
- Produces: no API change — `NoticeService`, `AppNotice` and the per-kind haptic are untouched

**Design:** left/right **14px**, **56px from the top** (plus safe-area), `#0B1A33` light / `#1A2436` dark (= `inverseSurface`), radius **16**, padding `13px 15px`: a 9px status dot + copy 13.5/500 in `onInverseSurface`. Enters from above, holds, exits — **2600 ms total**, self-dismissing. Dot colours: mint `#7FE3C0` success · `#7FCBFF` info · `#FF9AA8` error.

> **Only three kinds ship.** `AppNotice` is a sealed family of `NoticeSuccess` / `NoticeInfo` / `NoticeError`. The design's fourth dot, amber `#F0C36A` "request sent", belongs to time-off, so the `noticeAmber` token exists (Task A2) but no kind uses it until P6 adds one. Do not invent a kind now.

> **Accessibility carve-out.** The design has no close button; the old one is asserted by an existing test and is a real dismiss affordance for switch and screen-reader users. Decision: **render the close button only when `MediaQuery.accessibleNavigationOf(context)` is true**, keep the swipe-up `Dismissible` for everyone, and keep the existing longer hold (6 s) under accessible navigation. Branching on an accessibility flag is legitimate — the banned branch is on *brightness*.

- [x] **Step 1: Update the test**

In `test/core/notices/notice_banner_test.dart`:
- `'close button is a 48px IconButton with a tooltip'` — wrap the harness in `MediaQuery(data: MediaQueryData(accessibleNavigation: true), ...)` so the button renders; keep the 48px and tooltip assertions.
- Add `'no close button without accessible navigation'` asserting `find.byTooltip('Close')` is `findsNothing` under the default harness.
- `'auto-dismiss timer is preserved'` — pump `AppMotion.noticeCycle` instead of `Duration(seconds: 3)`.
- Add `'the notice renders on the inverse surface with a kind-coloured dot'` asserting the container colour is `lightTheme().colorScheme.inverseSurface` and the dot is `lightTheme().palette.noticeMint` for a success.

- [x] **Step 2: Run to confirm it fails**

```bash
flutter test test/core/notices/notice_banner_test.dart
```

- [x] **Step 3: Restyle `_show` and `_TopNotice`**

In `_show`, replace the per-kind `(bg, fg, icon)` tuple with a per-kind **dot colour** only — the surface is now the same for all three:

```dart
    final dot = switch (notice) {
      NoticeSuccess() => theme.palette.noticeMint,
      NoticeInfo() => theme.palette.noticeInfo,
      NoticeError() => theme.palette.noticeRed,
    };
```

The haptic switch is unchanged. In `_TopNotice`:
- position: `top: padding.top + 56 - <status bar allowance>` — express it as `Positioned(top: padding.top + AppSpacing.sp16, left: padding.left + 14, right: padding.right + 14)`. **Never a literal 56 measured from the physical top**; the design's 56 assumes a 40px status bar, and `padding.top` already supplies the real one.
- `Material(color: scheme.inverseSurface, borderRadius: BorderRadius.circular(AppRadius.r16), elevation: 0)` wrapped in a `DecoratedBox` carrying `theme.cardStyle.noticeShadow`.
- content: `Row([9px dot Container, SizedBox(width: 10), Expanded(Text(message, style: TextStyle(color: scheme.onInverseSurface, fontSize: 13.5, fontWeight: FontWeight.w500)))])`, plus the conditional close `IconButton`.
- timing: total lifetime `AppMotion.noticeCycle` (2600 ms) — entrance `AppAnimationDurations.banner` (280 ms), hold, exit. Under `MediaQuery.disableAnimationsOf(context)` the slide collapses to instant while the hold still runs.
- keep `Semantics(liveRegion: true)` and the `Dismissible(direction: DismissDirection.up)`.

- [x] **Step 4: Run the tests**

```bash
flutter test test/core/notices/
```

- [x] **Step 5: Commit**

```bash
git add lib/core/notices test/core/notices
git commit -m "feat(p1): restyle the notice as the dark status-dot pill"
```

---

## Task C5: Full verification sweep

**Files:** none — this task only verifies and fixes fallout.

- [x] **Step 1: Static checks**

```bash
flutter analyze 2>&1 | grep -E "error -|warning -"
```

Expected: no output.

- [x] **Step 2: Full suite**

```bash
flutter test
```

Expected: green. The baseline before P1 was 1068 tests; this plan adds roughly 20 and rewrites about 10.

- [x] **Step 3: Text-scale sweeps at 375×667**

Every screen this plan touched needs the 0.8–2.0 sweep, per the cross-cutting accessibility requirement:

```bash
flutter test --plain-name "scale"
flutter test test/features/auth/screens/auth_screens_scale_sweep_test.dart
```

Assert `tester.takeException()` is null throughout. A new overflow means a height that stopped deriving from scaled text — fix the height, never clamp the scale.

- [x] **Step 4: Check for BOMs**

The rules call this out as a repo that has been bitten before:

```bash
for f in $(git diff --name-only main...HEAD -- '*.dart'); do
  if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' ')" = "efbbbf" ]; then echo "BOM: $f"; fi
done
```

Expected: no output.

- [x] **Step 5: Confirm the dead code is gone**

```bash
grep -rn "AdaptiveShell\|AdaptiveDestination\|_RailEntry\|isExpanded\|Breakpoints.expanded\|SettingsDrawer\|GoogleFonts\|employeePalette" lib/ test/
```

Expected: no output. `isSplitLayout` and `isTwoPane` **must still be present** — only `isExpanded` dies.

- [ ] **Step 6: Device pass** — OWNER-GATED, still outstanding

The biometric app lock, camera capture, image pipeline, push taps and the presence stream are all method-channel paths with no test coverage. Run on a device and walk: sign in → drawer opens from every screen → each of the 8 rows lands correctly → Calendar pill returns home from a pushed page *and* from two-deep → Settings and History tours start on first visit → a notice fires and self-dismisses → dark mode across all four tabs.

```bash
flutter run
```

- [x] **Step 7: Update the docs**

`docs/ARCHITECTURE.md` references `AdaptiveDestination` and the nav rail; update it to the new destination family and the drawer. Add a line to `CHANGELOG.md`. Update the CLAUDE.md sections that describe the hub tab set, the drawer, and the token layer — but do this in one pass at the end of P1, not per task.

- [x] **Step 8: Commit**

```bash
git add -A
git commit -m "docs(p1): update architecture and changelog for the foundation redesign"
```

---

## Known deferrals and accepted costs

Recorded so a later pass does not "discover" and re-litigate them.

1. **Legacy stored employee colours are not remapped.** Existing employees hold pre-redesign palette ints (`0xFF6366F1` indigo etc.). They are not in the new crew list, so they render as-stored in light, HSL-lifted in dark, and show as the "custom" swatch in the grid. Deliberate — silently recolouring a tech's identity across every card, pin and bar is worse than letting admins re-pick.
2. **`day_route_screen.dart:467` and `staff_marker_icon.dart:139` still call `contrastingForegroundFor` directly.** They compile fine; dark map pins just show unresolved crew colours until their own project migrates them to `crewColorOf` + `avatarForegroundFor`.
3. **`labelLarge` grew 11 → 14 and card title 15.5 folded into `titleMedium` 15.** Any call site using `labelLarge` as a small label visibly grows; P2–P7 correct these as they sweep screens.
4. **A modal sheet over a pushed screen dismisses a running tour and marks it seen** — inherited deliberately from the existing mid-tour tab-switch policy, not a new regression.
5. **Drawer re-tap of the current pushed screen is a no-op** (the `ModalRoute.settingsOf` guard). New, correct behaviour.
6. **`_hubRoute` and `HubTabRedirectRoute` survive** at three tab routes. They look like dead code but remain the cold-start fallback and are pinned by `hub_shell_test.dart`.
7. **Derived dark values needing designer sign-off** (the handoff omits dark counterparts): body text `#C5D0E2`, amber chip fill `0x29F1A83C`, track `0x14FFFFFF`, bar tint `#31445F`, locked panel `#121B2A`, blue-tint pressed `0x334B90F7`, `onError` `#1C060A`, the brown/olive crew hues and their lifts, and the 150° gradient approximated as `Alignment(-0.5,-1) → Alignment(0.5,1)`.
8. **Instrument Sans 500 is bundled but the sans ramp only uses 400/600/700.** Droppable later if app size matters (~87 KB).
9. **The drawer sits *below* modal sheets, not above them.** `02-navigation.md` specifies z-order sheets 50–57 < drawer 60 < notice 70. Flutter's end drawer lives inside its `Scaffold`, so any modal route (bottom sheet, dialog) paints over it; only the notice — which rides the Navigator's overlay via `navigatorKey` — is genuinely on top. Accepted rather than engineered around: the drawer is only reachable from the header pair, which is itself covered while a sheet is open, so the two are never on screen together. Do not rebuild the drawer as a route to "fix" the ordering — that would break `Scaffold.of(context).openEndDrawer()` and the local-history-entry back behaviour the whole design depends on.
10. **`AppTopBar`'s `compact == context.isLandscape` assert stays.** Every call site touched in Task C3 must keep passing `compact: context.isLandscape`, or the assert fires in debug.

## Not in P1

The calendar grid replacement, appointment-card API change, sheet and form restyles (P2) · client model and archive (P3) · team model (P4) · auth and invites (P4b) · settings and my-details screens (P5) · time off (P6) · dashboard and history (P7). This plan delivers only the tokens, fonts, destination types, drawer, header pair and toast those projects build on.


