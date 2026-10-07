import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_filter_bar.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

Widget _harness({
  required ClientsFilter selected,
  VoidCallback? onOpen,
  double textScale = 1,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  // The REAL theme, not the Material default: it makes every OutlinedButton
  // full-width, which is right for a stacked action bar and wrong in a row.
  theme: lightTheme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: Row(
        children: [
          ClientsFilterBar(selected: selected, onOpen: onOpen ?? () {}),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('tapping it calls onOpen', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterAll(), onOpen: () => opened++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  // The dot is the only thing on this control that says a filter is on; the
  // sentence beside it in the header names which.
  testWidgets('carries no badge while nothing is filtered', (tester) async {
    await tester.pumpWidget(_harness(selected: const ClientsFilterAll()));
    await tester.pumpAndSettle();

    expect(
      tester.widget<GhostControl>(find.byType(GhostControl)).showBadge,
      isFalse,
    );
  });

  testWidgets('carries a badge under every non-All filter', (tester) async {
    for (final filter in const <ClientsFilter>[
      ClientsFilterType(ClientType.commercial),
      ClientsFilterArchived(),
      ClientsFilterBuilding('k1'),
    ]) {
      await tester.pumpWidget(_harness(selected: filter));
      await tester.pumpAndSettle();

      expect(
        tester.widget<GhostControl>(find.byType(GhostControl)).showBadge,
        isTrue,
        reason: '$filter',
      );
    }
  });

  testWidgets('keeps the 48px tap floor at 2x text', (tester) async {
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterAll(), textScale: 2),
    );
    await tester.pumpAndSettle();

    final size = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.tune),
        matching: find.byType(InkWell),
      ),
    );
    expect(size.width, greaterThanOrEqualTo(kGhostTapTarget));
    expect(size.height, greaterThanOrEqualTo(kGhostTapTarget));
    expect(tester.takeException(), isNull);
  });
}
