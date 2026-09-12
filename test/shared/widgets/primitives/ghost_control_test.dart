import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_filter_bar.dart';
import 'package:scheduling/features/clients/widgets/sheets/clients_filter_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_back_button.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// The gesture area, NOT the box around it: every one of these controls already
/// reserved 48px of layout while the `InkWell` inside it was the painted tile.
Finder _gestureAreaAround(Finder content) =>
    find.ancestor(of: content, matching: find.byType(InkWell));

Widget _barHarness({ClientsFilter selected = const ClientsFilterAll()}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      home: Scaffold(
        body: Column(
          children: [
            ClientsFilterBar(selected: selected, onOpen: () {}),
          ],
        ),
      ),
    );

Widget _sheetHarness() => ProviderScope(
  overrides: [
    clientBuildingsProvider.overrideWith(
      (ref) => Future.value(const <ClientBuilding>[]),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: lightTheme(),
    home: Scaffold(
      body: ClientsFilterSheet(
        selected: const ClientsFilterAll(),
        onChanged: (_) {},
        onBack: () {},
      ),
    ),
  ),
);

void main() {
  testWidgets('the clients Filter button taps at 48x48, not at its tile', (
    tester,
  ) async {
    await tester.pumpWidget(_barHarness());
    await tester.pumpAndSettle();

    final size = tester.getSize(_gestureAreaAround(find.byIcon(Icons.tune)));
    expect(size.width, greaterThanOrEqualTo(kGhostTapTarget));
    expect(size.height, greaterThanOrEqualTo(kGhostTapTarget));
  });

  testWidgets('a pill taps at the 48px floor in every tone', (tester) async {
    for (final tone in GhostTone.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: lightTheme(),
          home: Scaffold(
            body: Align(
              child: GhostControl.pill(
                onTap: () {},
                label: 'Calendar',
                tone: tone,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final pill = _gestureAreaAround(find.text('Calendar'));
      expect(
        tester.getSize(pill).height,
        greaterThanOrEqualTo(kGhostTapTarget),
        reason: '$tone',
      );
    }
  });

  testWidgets('the filter sheet back tile taps at 48x48', (tester) async {
    await tester.pumpWidget(_sheetHarness());
    await tester.pumpAndSettle();

    final size = tester.getSize(_gestureAreaAround(find.byType(AppBackButton)));
    expect(size.width, greaterThanOrEqualTo(kGhostTapTarget));
    expect(size.height, greaterThanOrEqualTo(kGhostTapTarget));
  });

  // The floor must be reached by growing the HIT area, never the paint: the
  // ghost tile stays the design's 38px inside it.
  testWidgets('the painted tile stays smaller than the tap floor', (
    tester,
  ) async {
    await tester.pumpWidget(_barHarness());
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.byIcon(Icons.tune),
      matching: find.byType(Ink),
    );
    expect(tester.getSize(tile), const Size(kGhostTile, kGhostTile));
  });

  // A bare `Center` fills the width it is offered, which floated the Calendar
  // pill into the middle of the header row instead of beside the hamburger.
  testWidgets('a pill hugs its tile rather than the width it is offered', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme(),
        home: Scaffold(
          body: Row(
            children: [
              Flexible(
                child: GhostControl.pill(
                  onTap: () {},
                  label: 'Calendar',
                  icon: Icons.calendar_today_rounded,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final gesture = _gestureAreaAround(find.text('Calendar'));
    final tile = find.ancestor(
      of: find.text('Calendar'),
      matching: find.byType(Ink),
    );
    expect(tester.getSize(gesture).width, tester.getSize(tile).width);
  });
}
