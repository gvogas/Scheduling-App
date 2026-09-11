import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';

/// The top-level named arguments of the `ThemeData(...)` call inside
/// [builder], read straight out of the source.
///
/// `ThemeData` exposes no "which sub-themes did you configure" view — every
/// unset slot reads back as a framework default rather than as absent — so the
/// only way to compare the two builders' shapes is to read them. The named
/// arguments sit at exactly four spaces of indentation; anything nested is
/// deeper.
Set<String> _themeDataKeys(String builder) {
  final source = File('lib/core/theme/themes.dart').readAsStringSync();
  final start = source.indexOf('ThemeData $builder()');
  expect(start, greaterThan(-1), reason: '$builder is gone');
  final body = source.substring(source.indexOf('return ThemeData(', start));
  final end = body.indexOf('\n}');
  return RegExp(r'^    (\w+):', multiLine: true)
      .allMatches(end == -1 ? body : body.substring(0, end))
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  test('both themes register all four extensions', () {
    for (final theme in [lightTheme(), darkTheme()]) {
      expect(theme.extension<AppStatusColors>(), isNotNull);
      expect(theme.extension<AppCardStyle>(), isNotNull);
      expect(theme.extension<AppPalette>(), isNotNull);
      expect(theme.extension<AppMonoType>(), isNotNull);
    }
  });

  test('both themes configure exactly the same set of sub-themes', () {
    // Two ~180-line builders that must stay parallel, with nothing enforcing
    // it. A sub-theme added to one and forgotten on the other is invisible
    // until somebody switches modes and finds an unstyled control — and the
    // asymmetry compiles, analyzes and renders perfectly well in the mode it
    // WAS added to. Asserting the key sets match is the proportionate answer;
    // an abstraction over the two builders is not.
    final light = _themeDataKeys('_buildLightTheme');
    final dark = _themeDataKeys('_buildDarkTheme');

    expect(light, isNotEmpty);
    expect(dark, equals(light));
  });

  test('the parallel set is the full sub-theme list, not just the basics', () {
    // A guard on the guard: a regex that silently stopped matching would make
    // the test above pass on two empty sets.
    expect(
      _themeDataKeys('_buildLightTheme'),
      containsAll(const [
        'colorScheme',
        'extensions',
        'textTheme',
        'appBarTheme',
        'cardTheme',
        'inputDecorationTheme',
        'filledButtonTheme',
        'outlinedButtonTheme',
        'bottomSheetTheme',
        'drawerTheme',
        'dividerTheme',
        'chipTheme',
        'floatingActionButtonTheme',
        'snackBarTheme',
      ]),
    );
  });

  test('the leftover app bar theme carries nothing blue', () {
    for (final theme in [lightTheme(), darkTheme()]) {
      final bar = theme.appBarTheme;
      expect(bar.backgroundColor, theme.scaffoldBackgroundColor);
      expect(bar.foregroundColor, theme.colorScheme.onSurface);
      expect(bar.titleTextStyle?.color, theme.colorScheme.onSurface);
      expect(bar.titleTextStyle?.fontFamily, kFontSans);
      expect(bar.surfaceTintColor, Colors.transparent);
      expect(bar.elevation, 0);
      expect(bar.centerTitle, isFalse);
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
      ramp.displayLarge,
      ramp.headlineLarge,
      ramp.headlineMedium,
      ramp.headlineSmall,
      ramp.titleLarge,
      ramp.titleMedium,
      ramp.titleSmall,
      ramp.bodyLarge,
      ramp.bodyMedium,
      ramp.bodySmall,
      ramp.labelLarge,
      ramp.labelMedium,
      ramp.labelSmall,
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
