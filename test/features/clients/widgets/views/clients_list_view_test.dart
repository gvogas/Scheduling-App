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
import 'package:scheduling/features/clients/domain/models/client_search_results.dart';
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
  bool isAdmin = true,
  VoidCallback? onClearFilter,
}) {
  final view = ClientsListView(
    searchQuery: searchQuery,
    isAdmin: isAdmin,
    filter: filter,
    sort: sort,
    onCountChanged: onCountChanged,
    grouped: grouped,
    buildingLabel: buildingLabel,
    onClearFilter: onClearFilter,
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

  // mocktail needs a concrete instance before any(<T>) is usable.
  setUpAll(() {
    registerFallbackValue(ClientsSort.name);
    registerFallbackValue(const ClientsFilterAll());
  });

  setUp(() {
    repo = _MockClientsRepo();
    when(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => const []);
  });

  testWidgets('a limited search shows how many matches are omitted', (
    tester,
  ) async {
    when(() => repo.searchClients(any())).thenAnswer(
      (_) async => ClientSearchResults(
        [_sophie],
        examinedCount: 201,
        matchedCount: 30,
        truncated: true,
      ),
    );
    await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('Showing 1 of 30 matches.'), findsOneWidget);
    expect(find.text('Sophie Tremblay'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a read-capped search shows a lower-bound N+ count', (
    tester,
  ) async {
    when(() => repo.searchClients(any())).thenAnswer(
      (_) async => ClientSearchResults(
        [_sophie],
        examinedCount: 200,
        matchedCount: 1,
        truncated: true,
        matchedCountIsLowerBound: true,
      ),
    );
    await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.textContaining('1+ matches.'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('type pages pass the filter and refresh when the sort changes', (
    tester,
  ) async {
    const filter = ClientsFilterType(ClientType.commercial);
    when(
      () => repo.fetchClientsPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
        sort: any(named: 'sort'),
        filter: filter,
      ),
    ).thenAnswer(
      (invocation) async =>
          invocation.namedArguments[#sort] == ClientsSort.mostJobs
          ? const [
              ClientRecord(id: 'b', name: 'Beta'),
              ClientRecord(id: 'a', name: 'Alpha'),
            ]
          : const [
              ClientRecord(id: 'a', name: 'Alpha'),
              ClientRecord(id: 'b', name: 'Beta'),
            ],
    );
    await tester.pumpWidget(_wrap(repo, filter: filter));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Alpha')).dy,
      lessThan(tester.getTopLeft(find.text('Beta')).dy),
    );
    await tester.pumpWidget(
      _wrap(repo, filter: filter, sort: ClientsSort.mostJobs),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Beta')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    verify(
      () => repo.fetchClientsPage(
        limit: 50,
        sort: ClientsSort.mostJobs,
        filter: filter,
      ),
    ).called(1);
  });

  testWidgets('archived pages retain their empty state', (tester) async {
    await tester.pumpWidget(_wrap(repo, filter: const ClientsFilterArchived()));
    await tester.pumpAndSettle();
    expect(find.text('No archived clients'), findsOneWidget);
    verify(
      () => repo.fetchClientsPage(
        limit: 50,
        filter: const ClientsFilterArchived(),
      ),
    ).called(1);
  });

  testWidgets('typing in a filter calls scoped search', (tester) async {
    const filter = ClientsFilterType(ClientType.commercial);
    when(
      () => repo.searchClients('sophie', filter: filter),
    ).thenAnswer((_) async => const [_sophie]);
    await tester.pumpWidget(_wrap(repo, filter: filter));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_wrap(repo, filter: filter, searchQuery: 'sophie'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sophie'), findsOneWidget);
    verify(() => repo.searchClients('sophie', filter: filter)).called(1);
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
        filter: any(named: 'filter'),
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
        filter: any(named: 'filter'),
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => const [_sophie]);

    await tester.pumpWidget(_wrap(repo, sort: ClientsSort.mostJobs));
    await tester.pumpAndSettle();

    verify(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: ClientsSort.mostJobs,
      ),
    ).called(greaterThan(0));
  });

  // Grouping is opt-in so a host that only wants rows — a picker dropped into
  // a sheet — keeps the flat list without passing anything.
  // The paged list is server-ordered by the STORED name — a person's phone —
  // so letters over it would head runs that are not runs.
  testWidgets('keeps the unfiltered paged list in one card, even grouped', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
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

    await tester.pumpWidget(_wrap(repo, grouped: true));
    await tester.pumpAndSettle();

    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsNothing);
    expect(find.text('Alice Brown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps server ordered type pages in one group', (tester) async {
    when(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
        after: any(named: 'after'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => const [
        ClientRecord(id: 'c1', name: 'Zoe Tremblay'),
        ClientRecord(id: 'c2', name: 'Émile Roy'),
        ClientRecord(id: 'c3', name: 'Alice Brown'),
        ClientRecord(id: 'c4', name: 'Eric Gagnon'),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        repo,
        grouped: true,
        filter: const ClientsFilterType(ClientType.commercial),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A'), findsNothing);
    expect(find.text('E'), findsNothing);
    expect(find.text('Z'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drops the letter headings under a sort that is not Name', (
    tester,
  ) async {
    when(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
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
    when(
      () => repo.fetchClientsPage(
        limit: any(named: 'limit'),
        after: any(named: 'after'),
        filter: const ClientsFilterBuilding('k1'),
      ),
    ).thenAnswer(
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
        filter: any(named: 'filter'),
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

  group('writes patch the loaded pages in place', () {
    const bob = ClientRecord(id: 'c2', name: 'Bob Carter');

    void servePage(List<ClientRecord> page) => when(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).thenAnswer((_) async => page);

    int pageFetches() => verify(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
        after: any(named: 'after'),
        limit: any(named: 'limit'),
        sort: any(named: 'sort'),
      ),
    ).callCount;

    ClientsRefresh refresh(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(ClientsListView)),
    ).read(clientsRefreshProvider.notifier);

    testWidgets('an edit replaces its row without refetching page one', (
      tester,
    ) async {
      // Fixing a typo on client #180 used to drop the admin to the top of the
      // roster behind a skeleton, at ~60-260 reads a save.
      servePage(const [_sophie, bob]);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      refresh(
        tester,
      ).bump(ClientsWriteUpdated(_sophie.copyWith(name: 'Sophia Tremblay')));
      await tester.pumpAndSettle();

      expect(find.text('Sophia Tremblay'), findsOneWidget);
      expect(find.text('Sophie Tremblay'), findsNothing);
      expect(find.text('Bob Carter'), findsOneWidget);
      expect(pageFetches(), 1);
    });

    testWidgets('an edit that leaves the type filter drops the row', (
      tester,
    ) async {
      const filter = ClientsFilterType(ClientType.commercial);
      servePage(const [
        ClientRecord(id: 'c1', name: 'Acme', type: ClientType.commercial),
      ]);
      await tester.pumpWidget(_wrap(repo, filter: filter));
      await tester.pumpAndSettle();

      refresh(tester).bump(
        ClientsWriteUpdated(
          const ClientRecord(
            id: 'c1',
            name: 'Acme',
            type: ClientType.residential,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Acme'), findsNothing);
      expect(pageFetches(), 1);
    });

    testWidgets('an archive removes the row, and its undo puts it back where '
        'it was', (tester) async {
      servePage(const [_sophie, bob]);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      refresh(tester).bump(ClientsWriteArchived('c1', archived: true));
      await tester.pumpAndSettle();
      expect(find.text('Sophie Tremblay'), findsNothing);
      expect(find.text('Bob Carter'), findsOneWidget);

      refresh(tester).bump(ClientsWriteArchived('c1', archived: false));
      await tester.pumpAndSettle();
      expect(find.text('Sophie Tremblay'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Sophie Tremblay')).dy,
        lessThan(tester.getTopLeft(find.text('Bob Carter')).dy),
      );
      expect(pageFetches(), 1);
    });

    testWidgets('an add still refreshes from page one', (tester) async {
      servePage(const [_sophie]);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      refresh(tester).bump(ClientsWriteAdded(bob));
      await tester.pumpAndSettle();

      expect(pageFetches(), 2);
    });

    testWidgets('a row removed from a full page does not end the list', (
      tester,
    ) async {
      // getNextPageKey used to read the STORED page length, so 49 rows after an
      // in-place removal looked like a short last page and paging stopped.
      final full = [
        for (var i = 0; i < 50; i++)
          ClientRecord(
            id: 'p$i',
            name: 'Client ${i.toString().padLeft(2, '0')}',
          ),
      ];
      when(
        () => repo.fetchClientsPage(
          filter: any(named: 'filter'),
          after: any(named: 'after'),
          limit: any(named: 'limit'),
          sort: any(named: 'sort'),
        ),
      ).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#after] == null ? full : const [bob],
      );
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      refresh(tester).bump(ClientsWriteArchived('p0', archived: true));
      await tester.pumpAndSettle();
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await tester.pumpAndSettle();
      }

      expect(find.text('Bob Carter'), findsOneWidget);
      expect(pageFetches(), 2);
    });
  });

  group('local search fallback', () {
    const prefixHit = ClientRecord(id: 'c2', name: 'Sophie Tremblay');
    const containsHit = ClientRecord(id: 'c1', name: 'Tremblay Sophie');

    setUp(() {
      // Page order is the server's name order: the contains-hit first.
      when(
        () => repo.fetchClientsPage(
          filter: any(named: 'filter'),
          after: any(named: 'after'),
          limit: any(named: 'limit'),
          sort: any(named: 'sort'),
        ),
      ).thenAnswer((_) async => const [containsHit, prefixHit]);
    });

    testWidgets('is ranked like the server answer, so the commit does not '
        'reorder', (tester) async {
      when(
        () => repo.searchClients(any()),
      ).thenAnswer((_) => Completer<List<ClientRecord>>().future);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie'));
      await tester.pump();

      expect(
        tester.getTopLeft(find.text('Sophie Tremblay')).dy,
        lessThan(tester.getTopLeft(find.text('Tremblay Sophie')).dy),
      );
      // Lets the search debounce fire so no timer outlives the test.
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('outlives an empty server answer', (tester) async {
      // The index can lag a write the loaded page already shows.
      when(() => repo.searchClients(any())).thenAnswer((_) async => const []);
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_wrap(repo, searchQuery: 'sophie'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('Sophie Tremblay'), findsOneWidget);
      expect(find.textContaining('No clients match'), findsNothing);
    });
  });

  group('empty and error copy', () {
    testWidgets('a first-page error titles the intro over the cause', (
      tester,
    ) async {
      when(
        () => repo.fetchClientsPage(
          filter: any(named: 'filter'),
          after: any(named: 'after'),
          limit: any(named: 'limit'),
          sort: any(named: 'sort'),
        ),
      ).thenThrow(Exception('boom'));
      await tester.pumpWidget(_wrap(repo));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load clients"), findsOneWidget);
      expect(find.text('Please try again in a moment.'), findsOneWidget);
      expect(find.text('Something went wrong'), findsNothing);
    });

    testWidgets('a technician is not told to tap a + they do not have', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(repo, isAdmin: false));
      await tester.pumpAndSettle();

      expect(find.textContaining('Tap +'), findsNothing);
      expect(
        find.text('Clients added by an administrator will appear here.'),
        findsOneWidget,
      );
    });

    testWidgets('the shared-address empty state has its own hint', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(repo, filter: const ClientsFilterBuilding('k1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('No clients at this address.'), findsOneWidget);
      expect(find.textContaining('edit sheet'), findsNothing);
      expect(find.textContaining('two or more clients'), findsOneWidget);
    });

    testWidgets('a search inside a filter names the filter and offers to '
        'clear it', (tester) async {
      const filter = ClientsFilterType(ClientType.commercial);
      var cleared = false;
      when(
        () => repo.searchClients(any(), filter: filter),
      ).thenAnswer((_) async => const []);
      await tester.pumpWidget(
        _wrap(repo, filter: filter, onClearFilter: () => cleared = true),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        _wrap(
          repo,
          filter: filter,
          searchQuery: 'zzz',
          onClearFilter: () => cleared = true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // Typographic quotes come from the ARB, so French can use « » instead.
      expect(find.text('No clients match \u201czzz\u201d'), findsOneWidget);
      expect(find.textContaining('within Commercial'), findsOneWidget);
      await tester.tap(find.text('Clear filter'));
      expect(cleared, isTrue);
    });
  });

  testWidgets('reports the loaded row count to its host', (tester) async {
    int? reported;
    when(
      () => repo.fetchClientsPage(
        filter: any(named: 'filter'),
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
