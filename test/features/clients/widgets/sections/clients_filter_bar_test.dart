import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_filter_bar.dart';
import 'package:scheduling/l10n/l10n.dart';

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(ClientsFilterBar)));

Widget _harness({
  required ClientsFilter selected,
  VoidCallback? onOpen,
  VoidCallback? onClear,
  ValueChanged<ClientsFilter>? onSelect,
  String? buildingLabel,
  double textScale = 1,
  // The tour wraps this bar in a showcase, which hands its child UNBOUNDED
  // width — the shape that broke the first version of this widget.
  bool unbounded = false,
}) {
  final bar = ClientsFilterBar(
    selected: selected,
    onOpen: onOpen ?? () {},
    onClear: onClear ?? () {},
    onSelect: onSelect ?? (_) {},
    activeBuildingLabel: buildingLabel,
  );
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    // The REAL theme, not the Material default: it makes every OutlinedButton
    // full-width, which is exactly what broke this bar in a Row.
    theme: lightTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: unbounded ? Row(children: [bar]) : Column(children: [bar]),
      ),
    ),
  );
}

void main() {
  testWidgets('offers All, every pickable type and Archived as chips', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(selected: const ClientsFilterAll()));
    await tester.pumpAndSettle();

    final l10n = _l10n(tester);
    expect(find.text(l10n.clients_filterAll), findsOneWidget);
    for (final type in ClientType.pickable) {
      expect(find.text(clientTypeLabel(l10n, type)), findsOneWidget);
    }
    expect(find.text(l10n.clients_filterArchived), findsOneWidget);
  });

  testWidgets('tapping a type chip selects that type', (tester) async {
    ClientsFilter? picked;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterAll(),
        onSelect: (filter) => picked = filter,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.text(clientTypeLabel(_l10n(tester), ClientType.commercial)),
    );
    await tester.pumpAndSettle();

    expect(picked, const ClientsFilterType(ClientType.commercial));
  });

  testWidgets('tapping the Archived chip selects the archived filter', (
    tester,
  ) async {
    ClientsFilter? picked;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterAll(),
        onSelect: (filter) => picked = filter,
      ),
    );
    await tester.pumpAndSettle();

    // Last in the row, so it is the one that needs the scroller.
    final archived = find.text(_l10n(tester).clients_filterArchived);
    await tester.ensureVisible(archived);
    await tester.pumpAndSettle();
    await tester.tap(archived);
    await tester.pumpAndSettle();

    expect(picked, const ClientsFilterArchived());
  });

  testWidgets('tapping All clears back to the whole roster', (tester) async {
    ClientsFilter? picked;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterArchived(),
        onSelect: (filter) => picked = filter,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l10n(tester).clients_filterAll));
    await tester.pumpAndSettle();

    expect(picked, const ClientsFilterAll());
  });

  // An address is discovered from the data and there can be dozens, so it gets
  // a removable chip rather than a chip of its own in the row.
  testWidgets('an active building shows a removable chip with its label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterBuilding('k1'),
        buildingLabel: '1200 Rue Sherbrooke',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1200 Rue Sherbrooke'), findsOneWidget);
  });

  testWidgets('dismissing the building chip clears the filter', (tester) async {
    var cleared = false;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterBuilding('k1'),
        buildingLabel: '1200 Rue Sherbrooke',
        onClear: () => cleared = true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);
  });

  testWidgets('tapping the Filter button calls onOpen', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterAll(), onOpen: () => opened++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('lays out under UNBOUNDED width, as the tour showcase gives it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterBuilding('k1'),
        buildingLabel: '1200 Rue Sherbrooke Ouest, Montreal',
        unbounded: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('1200 Rue Sherbrooke Ouest, Montreal'), findsOneWidget);
  });

  testWidgets('the chips scroll rather than overflow at 260px with 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterType(ClientType.residential),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    // The button is the one control that must never be pushed off the row.
    expect(find.byIcon(Icons.tune), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
