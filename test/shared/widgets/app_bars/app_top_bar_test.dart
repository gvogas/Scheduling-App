import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/fields/app_search_bar.dart';
import 'package:scheduling/shared/widgets/primitives/app_back_button.dart';

const _delegates = <LocalizationsDelegate<Object?>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

/// The safe-area inset the header must add for itself.
const double _topInset = 24;

/// The header's own chrome: top gap, controls row, title gap, bottom gap.
const double _topGap = 24;
const double _controlsRow = 48;
const double _titleGap = 6;
const double _bottomGap = 14;

Widget _harness(AppTopBar bar, {double textScale = 1.0, Widget? drawer}) =>
    MaterialApp(
      localizationsDelegates: _delegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: const EdgeInsets.only(top: _topInset),
        ),
        child: inner ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        appBar: bar,
        endDrawer: drawer,
        body: const SizedBox.shrink(),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  AppTopBar bar, {
  Size size = const Size(400, 800),
  double textScale = 1.0,
  Widget? drawer,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(bar, textScale: textScale, drawer: drawer));
  await tester.pumpAndSettle();
}

double _renderedHeight(WidgetTester tester) =>
    tester.getSize(find.byType(AppTopBar)).height;

double _titleHeight(WidgetTester tester, String title) =>
    tester.getSize(find.text(title)).height;

void main() {
  testWidgets('the header renders its real rows and fits what it reserved', (
    tester,
  ) async {
    const bar = AppTopBar(title: 'Clients', actions: [AppHeaderPair()]);
    await _pump(tester, bar);

    final rendered = _renderedHeight(tester);
    expect(
      rendered,
      _topInset +
          _topGap +
          _controlsRow +
          _titleGap +
          _titleHeight(tester, 'Clients') +
          _bottomGap,
    );
    expect(
      bar.preferredSize.height + _topInset,
      greaterThanOrEqualTo(rendered),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bottom search bar adds exactly its own rendered height', (
    tester,
  ) async {
    const bare = AppTopBar(title: 'Clients', actions: [AppHeaderPair()]);
    await _pump(tester, bare);
    final withoutBottom = _renderedHeight(tester);

    const withBar = AppTopBar(
      title: 'Clients',
      actions: [AppHeaderPair()],
      bottom: AppSearchBar(),
    );
    await _pump(tester, withBar);

    final rendered = _renderedHeight(tester);
    expect(
      rendered,
      withoutBottom + tester.getSize(find.byType(AppSearchBar)).height,
    );
    expect(
      withBar.preferredSize.height + _topInset,
      greaterThanOrEqualTo(rendered),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the header still fits at 2x text on a 260px view', (
    tester,
  ) async {
    const bar = AppTopBar(
      title: 'Clients',
      actions: [AppHeaderPair()],
      // What a call site passes: MediaQuery.textScalerOf(context).
      bottom: AppSearchBar(textScaler: TextScaler.linear(2)),
    );
    await _pump(tester, bar, size: const Size(260, 800), textScale: 2);

    expect(tester.takeException(), isNull);
    expect(
      bar.preferredSize.height + _topInset,
      greaterThanOrEqualTo(_renderedHeight(tester)),
    );
  });

  testWidgets('compact puts the title on the controls row and reserves less', (
    tester,
  ) async {
    const bar = AppTopBar(
      title: 'Clients',
      compact: true,
      actions: [AppHeaderPair()],
    );
    await _pump(tester, bar, size: const Size(800, 400));

    // The title rides the controls row, so no separate title row is reserved.
    expect(find.text('Clients'), findsOneWidget);
    final rendered = _renderedHeight(tester);
    expect(rendered, _topInset + _topGap + _controlsRow + _bottomGap);
    expect(
      bar.preferredSize.height + _topInset,
      greaterThanOrEqualTo(rendered),
    );
    expect(
      bar.preferredSize.height,
      lessThan(
        const AppTopBar(
          title: 'Clients',
          actions: [AppHeaderPair()],
        ).preferredSize.height,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the back chevron appears only when onBack is given', (
    tester,
  ) async {
    await _pump(
      tester,
      const AppTopBar(title: 'Clients', actions: [AppHeaderPair()]),
    );
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    var tapped = 0;
    await _pump(
      tester,
      AppTopBar(
        title: 'Clients',
        onBack: () => tapped++,
        actions: const [AppHeaderPair()],
      ),
    );
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('the back chevron meets the 48px tap minimum', (tester) async {
    await _pump(
      tester,
      AppTopBar(
        title: 'Clients',
        onBack: () {},
        actions: const [AppHeaderPair()],
      ),
    );

    final size = tester.getSize(find.byType(AppBackButton));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('the menu button still opens the end drawer from the header', (
    tester,
  ) async {
    await _pump(
      tester,
      const AppTopBar(title: 'Clients', actions: [AppHeaderPair()]),
      drawer: const Drawer(child: Text('drawer-content')),
    );

    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('drawer-content'), findsOneWidget);
  });

  // The pill's gesture box abuts the menu either way; what drifted is the
  // PAINTED tile, which a bare Center floated into the middle of the row.
  testWidgets('the calendar tile sits beside the menu, not adrift in the row', (
    tester,
  ) async {
    const bar = AppTopBar(title: 'Clients', actions: [AppHeaderPair()]);
    await _pump(tester, bar);

    final tile = tester.getRect(
      find.ancestor(of: find.text('Calendar'), matching: find.byType(Ink)),
    );
    final menu = tester.getRect(find.byTooltip('Open menu'));
    expect(menu.left - tile.right, lessThan(12));
  });
}
