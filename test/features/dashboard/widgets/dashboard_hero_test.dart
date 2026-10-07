import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/dashboard/domain/dashboard_stats.dart';
import 'package:scheduling/features/dashboard/widgets/sections/dashboard_hero.dart';
import 'package:scheduling/l10n/l10n.dart';

const _delegates = <LocalizationsDelegate<Object?>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

const _ops = TodayOps(
  statusCounts: {'in_progress': 1, 'pending': 1, 'done': 1, 'cancelled': 1},
  unassignedCount: 0,
  upcoming: [],
);

Widget _harness() => MaterialApp(
  localizationsDelegates: _delegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: lightTheme(),
  home: Scaffold(
    body: DashboardHero(ops: _ops, now: DateTime(2026, 9, 11)),
  ),
);

/// The bar's segments. Scoped to the clip that rounds the bar, so the
/// transparent ColoredBox the Scaffold paints behind it stays out.
Finder _segments() => find.descendant(
  of: find.byType(ClipRRect),
  matching: find.byType(ColoredBox),
);

void main() {
  // A childless ColoredBox takes `constraints.smallest`, so under a Row's
  // default centre alignment every segment laid out 0 tall and the bar painted
  // nothing at all — with the legend beside it looking perfectly correct.
  testWidgets('the status bar segments have real height', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final boxes = _segments();
    expect(boxes, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      final size = tester.getSize(boxes.at(i));
      expect(size.height, greaterThan(0), reason: 'segment $i is invisible');
      expect(size.width, greaterThan(0), reason: 'segment $i is invisible');
    }
  });

  // `statusColors.accent` IS `scheme.primary`, which is the colour the hero's
  // own gradient starts from, so in-progress painted blue on blue.
  testWidgets('no segment is painted in the hero gradient colour', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final scheme = lightTheme().colorScheme;
    for (final box in tester.widgetList<ColoredBox>(_segments())) {
      expect(box.color, isNot(scheme.primary));
    }
  });
}
