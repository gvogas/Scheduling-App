import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_list_header.dart';
import 'package:scheduling/l10n/l10n.dart';

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(ClientsListHeader)));

Widget _harness({
  int? count,
  ClientsFilter filter = const ClientsFilterAll(),
  ClientsSort sort = ClientsSort.name,
  ValueChanged<ClientsSort>? onSortChanged,
  double textScale = 1,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: lightTheme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: ClientsListHeader(
        count: count,
        filter: filter,
        sort: sort,
        onSortChanged: onSortChanged ?? (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('names the whole roster when nothing is filtered', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(count: 3));
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).clients_showingAll(3)), findsOneWidget);
  });

  testWidgets('names the type when a type filter is on', (tester) async {
    await tester.pumpWidget(
      _harness(
        count: 3,
        filter: const ClientsFilterType(ClientType.commercial),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = _l10n(tester);
    expect(
      find.text(
        l10n.clients_showingType(
          3,
          clientTypeLabel(l10n, ClientType.commercial),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('names the building when an address filter is on', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(count: 4, filter: const ClientsFilterBuilding('k1')),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).clients_inThisBuilding(4)), findsOneWidget);
  });

  // Null is "not counted yet", which must not render as zero — the same rule
  // the row's job count follows.
  testWidgets('renders no count while the first page is still loading', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).clients_showingAll(0)), findsNothing);
  });

  testWidgets('names the active sort', (tester) async {
    await tester.pumpWidget(_harness(count: 1, sort: ClientsSort.mostJobs));
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).clients_sortMostJobs), findsOneWidget);
  });

  testWidgets('offers every sort and emits the picked one', (tester) async {
    ClientsSort? emitted;
    await tester.pumpWidget(
      _harness(count: 1, onSortChanged: (next) => emitted = next),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(_l10n(tester).clients_sortByName));
    await tester.pumpAndSettle();

    final l10n = _l10n(tester);
    expect(find.text(l10n.clients_sortMostJobs), findsOneWidget);
    expect(find.text(l10n.clients_sortRecentlyAdded), findsOneWidget);

    await tester.tap(find.text(l10n.clients_sortRecentlyAdded).last);
    await tester.pumpAndSettle();

    expect(emitted, ClientsSort.recentlyAdded);
  });

  testWidgets('does not overflow at 260px with 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(count: 1234, sort: ClientsSort.recentlyAdded, textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
