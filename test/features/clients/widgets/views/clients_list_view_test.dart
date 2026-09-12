import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/client_grouping.dart';
import 'package:scheduling/features/clients/domain/clients_repository.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/widgets/lists/clients_sliver_list.dart';
import 'package:scheduling/features/clients/widgets/views/clients_list_view.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/skeleton_loader.dart';

class _MockClientsRepo extends Mock implements ClientsRepository {}

const _sophie = ClientRecord(
  id: 'c1',
  name: 'Sophie Tremblay',
  phone: '514-555-0101',
  email: 'sophie@example.com',
);

Widget _wrap(
  ClientsRepository repo, {
  String searchQuery = '',
  ClientsFilter filter = const ClientsFilterAll(),
  double? height,
  ClientsSort sort = ClientsSort.name,
  void Function(int count)? onCountChanged,
  List<Override> extraOverrides = const [],
  bool grouped = false,
  String? buildingLabel,
}) {
  final view = ClientsListView(
    searchQuery: searchQuery,
    isAdmin: true,
    filter: filter,
    sort: sort,
    onCountChanged: onCountChanged,
    grouped: grouped,
    buildingLabel: buildingLabel,
  );
  return ProviderScope(
    overrides: [
      clientsRepositoryProvider.overrideWithValue(repo),
      ...extraOverrides,
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: Scaffold(
          body: height == null
              ? view
              // The keyboard-shortened box the master-detail Expanded hands the
              // view while a search is open.
              : Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(height: height, child: view),
                ),
        ),
      ),
    ),
  );
}

void main() {
  late _MockClientsRepo repo;

  // mocktail needs a concrete instance before any(<ClientType>) is usable.
  setUpAll(() {
    registerFallbackValue(ClientType.unset);
    registerFallbackValue(ClientsSort.name);
  });

  setUp(() {
    repo = _MockClientsRepo();
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const []);
    when(
      () => repo.fetchClientsByType(any()),
    ).thenAnswer((_) async => const []);
  });

  testWidgets('search error offers a Retry that re-runs the search', (
    tester,
  ) async {
    when(() => repo.searchClients(any())).thenThrow(Exception('boom'));

    // Start with an empty query, then type one, so the debounce commits the
    // search the way live typing does.
    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie'));
    // Let the search debounce commit, then the provider fail.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't load clients"), findsOneWidget);

    when(
      () => repo.searchClients(any()),
    ).thenAnswer((_) async => const [_sophie]);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sophie'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('committed search results refresh after a clientsRefresh bump '
      '(deleted client disappears)', (tester) async {
    when(
      () => repo.searchClients(any()),
    ).thenAnswer((_) async => const [_sophie]);

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sophie'), findsWidgets);

    // Simulate a delete flow: the repository stops returning the client and
    // the write path bumps clientsRefreshProvider.
    when(() => repo.searchClients(any())).thenAnswer((_) async => const []);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ClientsListView)),
    );
    container.read(clientsRefreshProvider.notifier).bump();
    await tester.pumpAndSettle();

    expect(find.textContaining('Sophie'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the type filter renders only that type of client', (
    tester,
  ) async {
    when(() => repo.fetchClientsByType(ClientType.commercial)).thenAnswer(
      (_) async => const [
        ClientRecord(
          id: 'v1',
          name: 'Commercial Client',
          type: ClientType.commercial,
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(repo, filter: const ClientsFilterType(ClientType.commercial)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Commercial Client'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the type filter never touches the paginated list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(repo, filter: const ClientsFilterType(ClientType.commercial)),
    );
    await tester.pumpAndSettle();

    // It is a separate bounded read. Filtering the paginated list in Dart would
    // shorten a full server page and stop paging early.
    verifyNever(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    );
    verify(() => repo.fetchClientsByType(ClientType.commercial)).called(1);
  });

  // The repro: with a filter active, picking a sort rebuilt the view but
  // nothing downstream consumed the new value, so the rows never moved.
  testWidgets('a sort change RE-ORDERS the filtered list, with no refetch', (
    tester,
  ) async {
    when(() => repo.fetchClientsByType(ClientType.commercial)).thenAnswer(
      (_) async => const [
        ClientRecord(
          id: 'v1',
          name: 'Alpha Co',
          type: ClientType.commercial,
          jobCount: 1,
        ),
        ClientRecord(
          id: 'v2',
          name: 'Zulu Co',
          type: ClientType.commercial,
          jobCount: 9,
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(repo, filter: const ClientsFilterType(ClientType.commercial)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Alpha Co')).dy,
      lessThan(tester.getTopLeft(find.text('Zulu Co')).dy),
      reason: 'name order puts Alpha first',
    );

    await tester.pumpWidget(
      _wrap(
        repo,
        filter: const ClientsFilterType(ClientType.commercial),
        sort: ClientsSort.mostJobs,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Zulu Co')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha Co')).dy),
      reason: 'most jobs floats Zulu, which name order buried',
    );

    // Ordering is a view concern: re-sorting must not cost a second read.
    verify(() => repo.fetchClientsByType(ClientType.commercial)).called(1);
  });

  testWidgets('the archived filter reads its own bounded query', (
    tester,
  ) async {
    when(() => repo.fetchArchivedClients()).thenAnswer(
      (_) async => const [ClientRecord(id: 'a1', name: 'Retired Co')],
    );

    await tester.pumpWidget(_wrap(repo, filter: const ClientsFilterArchived()));
    await tester.pumpAndSettle();

    expect(find.text('Retired Co'), findsOneWidget);
    // Same shape as the type filter: a separate bounded read, never a Dart
    // filter over a server page.
    verifyNever(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the archived filter shows an empty state when none are', (
    tester,
  ) async {
    when(() => repo.fetchArchivedClients()).thenAnswer((_) async => const []);

    await tester.pumpWidget(_wrap(repo, filter: const ClientsFilterArchived()));
    await tester.pumpAndSettle();

    expect(find.text('No archived clients'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('searching within a type filters that type', (tester) async {
    when(() => repo.fetchClientsByType(ClientType.commercial)).thenAnswer(
      (_) async => const [
        ClientRecord(
          id: 'v1',
          name: 'Sophie Tremblay',
          type: ClientType.commercial,
        ),
        ClientRecord(
          id: 'v2',
          name: 'Marc Gagnon',
          type: ClientType.commercial,
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        repo,
        filter: const ClientsFilterType(ClientType.commercial),
        searchQuery: 'sophie',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Sophie'), findsOneWidget);
    expect(find.textContaining('Marc'), findsNothing);
    // Matched locally against the bounded list, not via a second server query.
    verifyNever(() => repo.searchClients(any()));
  });

  testWidgets('the search skeleton fits a keyboard-shortened body', (
    tester,
  ) async {
    // A search that never resolves, so the view sits on the loading skeleton.
    when(
      () => repo.searchClients(any()),
    ).thenAnswer((_) => Completer<List<ClientRecord>>().future);

    await tester.pumpWidget(_wrap(repo, height: 257.2));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie', height: 257.2));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // Four fixed rows are 280px and overflowed this box by 23px; the row count
    // has to follow the height, since the skeleton can't scroll itself.
    expect(find.byType(SkeletonListTile), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty type result shows the type empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(repo, filter: const ClientsFilterType(ClientType.commercial)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No Commercial clients'), findsOneWidget);
  });

  // The read-amplification fix: opening the tab must not touch the ~700-doc
  // building scan. It is the filter sheet's to watch now.
  testWidgets('never reads the building providers', (tester) async {
    var buildingReads = 0;
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const [_sophie]);

    await tester.pumpWidget(
      _wrap(
        repo,
        extraOverrides: [
          clientBuildingsProvider.overrideWith((ref) async {
            buildingReads += 1;
            return const <ClientBuilding>[];
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sophie Tremblay'), findsOneWidget);
    expect(buildingReads, 0);
  });

  testWidgets('passes the sort through to the repository', (tester) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const [_sophie]);

    await tester.pumpWidget(_wrap(repo, sort: ClientsSort.mostJobs));
    await tester.pumpAndSettle();

    verify(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: ClientsSort.mostJobs,
      ),
    ).called(greaterThan(0));
  });

  // Grouping is opt-in so a host that only wants rows — a picker dropped into
  // a sheet — keeps the flat list without passing anything.
  testWidgets('groups by initial under Name sort only when asked', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer(
      (_) async => const [
        ClientRecord(id: 'c1', name: 'Alice Brown'),
        ClientRecord(id: 'c2', name: 'Bob Carter'),
      ],
    );

    await tester.pumpWidget(_wrap(repo));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsNothing);

    await tester.pumpWidget(_wrap(repo, grouped: true));
    await tester.pumpAndSettle();

    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drops the letter headings under a sort that is not Name', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer(
      (_) async => const [
        ClientRecord(id: 'c1', name: 'Alice Brown', jobCount: 9),
        ClientRecord(id: 'c2', name: 'Bob Carter', jobCount: 2),
      ],
    );

    await tester.pumpWidget(
      _wrap(repo, grouped: true, sort: ClientsSort.mostJobs),
    );
    await tester.pumpAndSettle();

    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsNothing);
    expect(find.text('Alice Brown'), findsOneWidget);
  });

  testWidgets('a building filter heads its one group with the street', (
    tester,
  ) async {
    when(() => repo.fetchClientsByBuilding('k1')).thenAnswer(
      (_) async => const [
        ClientRecord(id: 'c1', name: 'Alice Brown'),
        ClientRecord(id: 'c2', name: 'Bob Carter'),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        repo,
        grouped: true,
        filter: const ClientsFilterBuilding('k1'),
        buildingLabel: '4450 Prom. Paton',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('4450 PROM. PATON'), findsOneWidget);
    expect(find.text('A'), findsNothing);
  });

  // Grouping is an O(N) pass per row — two regex passes through displayName
  // plus an accent fold — and PagingState.items hands back a freshly flattened
  // list on every access, so a memo can only hit against a cached instance.
  testWidgets('regroups nothing on a rebuild that changes none of its inputs', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer(
      (_) async => const [
        ClientRecord(id: 'c1', name: 'Alice Brown'),
        ClientRecord(id: 'c2', name: 'Bob Carter'),
      ],
    );

    List<ClientGroup> groupsNow() =>
        tester.widget<ClientsSliverList>(find.byType(ClientsSliverList)).groups;

    await tester.pumpWidget(_wrap(repo, grouped: true));
    await tester.pumpAndSettle();
    final grouped = groupsNow();

    await tester.pumpWidget(_wrap(repo, grouped: true));
    await tester.pumpAndSettle();

    expect(identical(groupsNow(), grouped), isTrue);
  });

  testWidgets('reports the loaded row count to its host', (tester) async {
    int? reported;
    when(
      () => repo.fetchClientsPage(
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const [_sophie]);

    await tester.pumpWidget(
      _wrap(repo, onCountChanged: (count) => reported = count),
    );
    await tester.pumpAndSettle();

    expect(reported, 1);
  });
}
