import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/shared/widgets/fields/attached_dropdown.dart';

void main() {
  Widget harness(Widget child, {double textScale = 1}) => MaterialApp(
    theme: lightTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: child),
    ),
  );

  // The client row this replaced painted ~36px and hung a shrinkWrap
  // TextButton inside the InkWell that already did the same thing. Both halves
  // are the bug: a sub-floor target, and two targets for one action.
  testWidgets('a single-line row holds the 48px tap floor', (tester) async {
    await tester.pumpWidget(
      harness(
        AttachedDropdown(
          children: [
            AttachedDropdownRow(headline: 'Marie Tremblay', onTap: () {}),
          ],
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(AttachedDropdownRow)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('the row is the only tap target', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      harness(
        AttachedDropdown(
          children: [
            AttachedDropdownRow(
              headline: 'Marie Tremblay',
              onTap: () => taps++,
            ),
          ],
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(AttachedDropdownRow),
        matching: find.byType(ButtonStyleButton),
      ),
      findsNothing,
      reason: 'no second, smaller target for the action the row performs',
    );
    await tester.tap(find.text('Marie Tremblay'));
    await tester.pump();
    expect(taps, 1);
  });

  // It floats over the form; with no fill it borrowed the sheet colour and in
  // dark was separated only by a 6%-white hairline.
  testWidgets('the panel paints its own surface and lift', (tester) async {
    await tester.pumpWidget(
      harness(
        AttachedDropdown(
          children: [AttachedDropdownRow(headline: 'Row', onTap: () {})],
        ),
      ),
    );

    final theme = lightTheme();
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AttachedDropdown),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, theme.palette.sheetRow);
    expect(decoration.boxShadow, isNotNull);
    expect(decoration.boxShadow, isNotEmpty);
  });

  testWidgets('rows are divided, so two suggestions never read as one', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        AttachedDropdown(
          children: [
            AttachedDropdownRow(headline: 'One', onTap: () {}),
            AttachedDropdownRow(headline: 'Two', onTap: () {}),
          ],
        ),
      ),
    );

    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('a caption band pushes a divider above the first row', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        AttachedDropdown(
          caption: 'NO EXACT MATCH',
          children: [AttachedDropdownRow(headline: 'One', onTap: () {})],
        ),
      ),
    );

    expect(find.text('NO EXACT MATCH'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('a long two-line headline survives 260px at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        AttachedDropdown(
          children: [
            AttachedDropdownRow(
              leading: const Icon(Icons.location_on_outlined, size: 18),
              headline: '1234 Rue Sainte-Catherine Ouest, Montréal, QC, Canada',
              headlineMaxLines: 2,
              onTap: () {},
            ),
          ],
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
