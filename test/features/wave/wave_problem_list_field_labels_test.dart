import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';
import 'package:scheduling/features/wave/widgets/wave_problem_list.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _wrap(Widget child) {
  return ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: 1,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  // Every `field: "x"` value `customer_contract.js` can emit — read from
  // source so a field added there is checked here rather than silently
  // falling back to the raw key on screen (I5).
  final source = File('functions/wave/customer_contract.js').readAsStringSync();
  final fields = {
    for (final m in RegExp(r'field:\s*"([^"]+)"').allMatches(source))
      m.group(1)!,
  }.toList()..sort();

  test('customer_contract.js still names the fields this test expects', () {
    // Pins the extraction itself: if this fails because the field SET
    // changed, add the new field's case to `_fieldLabel`
    // (wave_problem_list.dart) and to this list together. If it fails
    // because the literal shape changed (e.g. no longer `field: "x"`), fix
    // the regex above instead.
    expect(fields, [
      'address',
      'addressLine2',
      'city',
      'email',
      'firstName',
      'lastName',
      'mobile',
      'name',
      'phone',
      'postalCode',
    ]);
  });

  testWidgets('every contract field renders a real label, not the raw key', (
    tester,
  ) async {
    final problems = [
      for (final field in fields)
        WaveProblem(
          field: field,
          code: WaveProblemCode.tooLong,
          isBlocking: true,
          length: 10,
          cap: 5,
        ),
    ];

    await tester.pumpWidget(_wrap(WaveProblemList(problems: problems)));
    await tester.pumpAndSettle();

    for (final field in fields) {
      // `_fieldLabel`'s fallback arm returns the raw field unchanged, so a
      // field with no case in the switch renders this exact sentence.
      final fallback = '$field is too long (10 / 5)';
      expect(
        find.text(fallback),
        findsNothing,
        reason:
            '_fieldLabel has no case for "$field" and fell back to the '
            'raw key',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a couple of labels read as expected prose', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const WaveProblemList(
          problems: [
            WaveProblem(
              field: 'addressLine2',
              code: WaveProblemCode.tooLong,
              isBlocking: true,
              length: 10,
              cap: 5,
            ),
            WaveProblem(
              field: 'postalCode',
              code: WaveProblemCode.tooLong,
              isBlocking: true,
              length: 10,
              cap: 5,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Address line 2 is too long (10 / 5)'), findsOneWidget);
    expect(find.text('Postal code is too long (10 / 5)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
