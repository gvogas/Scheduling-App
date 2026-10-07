import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/layout/primary_scroll_scope.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/scroll_to_top_button.dart';

const _delegates = <LocalizationsDelegate<Object?>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

/// The host shape the button is designed for: a list and the button stacked
/// over it, sharing one `PrimaryScrollScope`.
Widget _harness() => MaterialApp(
  localizationsDelegates: _delegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: lightTheme(),
  home: Scaffold(
    body: PrimaryScrollScope(
      child: Stack(
        children: [
          ListView.builder(
            itemCount: 200,
            itemBuilder: (context, index) =>
                SizedBox(height: 60, child: Text('row $index')),
          ),
          const Positioned(left: 16, bottom: 16, child: ScrollToTopButton()),
        ],
      ),
    ),
  ),
);

ScrollController _controller(WidgetTester tester) =>
    PrimaryScrollController.of(tester.element(find.byType(ScrollToTopButton)));

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.descendant(
        of: find.byType(ScrollToTopButton),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void main() {
  testWidgets('stays hidden while the list is at the top', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(_opacity(tester), 0);
    expect(
      tester
          .widget<IgnorePointer>(
            find.descendant(
              of: find.byType(ScrollToTopButton),
              matching: find.byType(IgnorePointer),
            ),
          )
          .ignoring,
      isTrue,
    );
  });

  testWidgets('appears once the list is scrolled past the threshold', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    _controller(tester).jumpTo(1200);
    await tester.pumpAndSettle();

    expect(_opacity(tester), 1);
  });

  testWidgets('tapping it returns the list to the top', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    _controller(tester).jumpTo(4143);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ScrollToTopButton));
    await tester.pumpAndSettle();

    expect(_controller(tester).offset, 0);
    // And it takes itself away again.
    expect(_opacity(tester), 0);
  });

  // `ScrollController.offset` asserts unless exactly ONE scroll view is
  // attached, and a list that swaps its body has two for a frame. That threw
  // a red screen over the clients list.
  testWidgets('survives two scroll views sharing the primary controller', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: _delegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: Scaffold(
          body: PrimaryScrollScope(
            child: Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      child: ListView(children: const [SizedBox(height: 900)]),
                    ),
                    Expanded(
                      child: ListView(children: const [SizedBox(height: 900)]),
                    ),
                  ],
                ),
                const Positioned(
                  left: 16,
                  bottom: 16,
                  child: ScrollToTopButton(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Nothing it can act on, so it stays out of the way.
    expect(_opacity(tester), 0);
  });
}
