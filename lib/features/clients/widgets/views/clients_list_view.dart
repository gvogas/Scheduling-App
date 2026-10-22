import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/floating_controls.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/client_grouping.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_results.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/domain/policies/client_delete_policy.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/clients/widgets/cards/client_tile.dart';
import 'package:scheduling/features/clients/widgets/lists/clients_sliver_list.dart';
import 'package:scheduling/features/clients/widgets/lists/paged_sliver_driver.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_flow.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';
import 'package:scheduling/features/clients/widgets/views/client_actions_host.dart';
import 'package:scheduling/features/clients/widgets/views/debounced_paged_search.dart';
import 'package:scheduling/features/clients/widgets/views/row_cache.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/app_empty_state.dart';
import 'package:scheduling/shared/widgets/feedback/skeleton_loader.dart';
import 'package:scheduling/shared/widgets/feedback/warning_note.dart';
import 'package:scheduling/shared/widgets/primitives/fade_in_item.dart';

class ClientsListView extends ConsumerStatefulWidget {
  const ClientsListView({
    required this.searchQuery,
    required this.isAdmin,
    super.key,
    this.filter = const ClientsFilterAll(),
    this.onClientTap,
    this.selectedClientId,
    this.firstRowTourWrap,
    this.onFirstPageSettled,
    this.sort = ClientsSort.name,
    this.onCountChanged,
    this.grouped = false,
    this.buildingLabel,
    this.onClearFilter,
  });

  final String searchQuery;
  final bool isAdmin;

  /// Which slice of the roster to show.
  final ClientsFilter filter;
  final void Function(ClientRecord client)? onClientTap;
  final String? selectedClientId;

  /// Wraps the FIRST row only, as that row's feature-tour step.
  final Widget Function(Widget child)? firstRowTourWrap;

  /// Fires after the first page has settled and been laid out — success or
  /// failure, since either way the skeleton is gone and no further row will
  /// appear on its own.
  final VoidCallback? onFirstPageSettled;

  /// Server order for the paginated list, including filters. Search ignores it:
  /// results are relevance-ranked, and re-sorting them destroys that ranking.
  final ClientsSort sort;

  /// Fires with the rendered row count, so the screen's header can show a
  /// count without this view owning chrome.
  final void Function(int count)? onCountChanged;

  /// Opt-in letter headings and one card per run; off by default so a host
  /// that wants bare rows gets the flat list.
  final bool grouped;

  /// Street of the active [ClientsFilterBuilding], which heads that filter's
  /// single group. Passed in because this view must never watch the building
  /// scan itself.
  final String? buildingLabel;

  /// Drops the active filter; the empty state of a search run inside one
  /// offers it, since the filter is what is narrowing the answer.
  final VoidCallback? onClearFilter;

  @override
  ConsumerState<ClientsListView> createState() => _ClientsListViewState();
}

class _ClientsListViewState extends ConsumerState<ClientsListView>
    with
        ClientActionsHost<ClientsListView>,
        DebouncedPagedSearch<ClientsListView>,
        PagedSliverPrefetch<ClientsListView> {
  // Every page, under every sort, is the same size (owner call 2026-09-11).
  static const int _pageSize = 50;

  // PagingState.items re-flattens on every access, so the grouping memo can
  // only hit against a list instance cached here at the source.
  final RowCache<ClientRecord> _loadedRows = RowCache();

  @override
  String searchQueryOf(ClientsListView widget) => widget.searchQuery;

  @override
  VoidCallback? get onFirstPageSettled => widget.onFirstPageSettled;

  @override
  String get searchDebounceTag => 'CLI-SEARCH debounced search failed';

  @override
  String get analyticsSurface => AnalyticsSurfaces.clients;

  /// Whether the last page came back full AS FETCHED — an in-place removal
  /// shortens the stored page, which must not read as the end of the list.
  bool _lastPageFull = false;

  /// The last row as FETCHED: the repository caches the stored sort value only
  /// for that doc, so an in-place removal or edit must not move the cursor.
  ClientRecord? _cursor;

  /// Bumped by [_refresh], so a fetch the refresh superseded can't set [_cursor].
  int _fetchGeneration = 0;

  /// Rows this list dropped on archive, by id, with where they sat, so an Undo
  /// puts each back in place instead of refreshing to page one.
  final Map<String, (int page, int row, ClientRecord client)> _removedRows = {};

  late final PagingController<int, ClientRecord> _pagingController =
      PagingController<int, ClientRecord>(
        getNextPageKey: (state) {
          final pages = state.pages;
          if (pages == null) return 1;

          if (pages.isNotEmpty && !_lastPageFull) return null;
          return (state.keys?.last ?? 0) + 1;
        },
        fetchPage: _fetchPage,
      );

  Future<List<ClientRecord>> _fetchPage(int pageKey) async {
    // Read before the await — switching tabs mid-fetch unmounts this consumer,
    // and a `ref.read` in the catch would then throw a StateError over the top
    // of the real failure, losing the CLI-LIST breadcrumb entirely.
    final repository = ref.read(clientsRepositoryProvider);
    final logger = ref.read(loggerProvider);
    final generation = _fetchGeneration;
    try {
      final page = await repository.fetchClientsPage(
        after: pageKey == 1 ? null : _cursor,
        limit: _pageSize,
        sort: widget.sort,
        filter: widget.filter,
      );
      if (generation == _fetchGeneration) {
        _lastPageFull = page.length >= _pageSize;
        if (page.isNotEmpty) _cursor = page.last;
      }
      return page;
    } catch (e, st) {
      logger.warn('CLI-LIST clients page fetch error', e, st);
      rethrow;
    } finally {
      if (pageKey == 1) notifyFirstPageSettled();
    }
  }

  @override
  void didUpdateWidget(ClientsListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sort != widget.sort || oldWidget.filter != widget.filter) {
      _refresh();
    }
  }

  void _refresh() {
    _fetchGeneration++;
    _cursor = null;
    _removedRows.clear();
    _pagingController.refresh();
  }

  // A write patches the loaded pages in place where it can — an edit or an
  // archive — so fixing a typo on row 180 does not drop the admin back to page
  // one; add and delete still refresh, since only the server knows the page.
  void _applyWrite(ClientsWrite? write) {
    switch (write) {
      case ClientsWriteUpdated(:final client):
        _patchRow(client);
      case ClientsWriteArchived(:final clientId, :final archived):
        _patchArchived(clientId, archived: archived);
      case ClientsWriteAdded() ||
          ClientsWriteDeleted() ||
          ClientsWriteRefresh() ||
          null:
        _refresh();
    }
  }

  bool _matchesFilter(ClientRecord client) => switch (widget.filter) {
    ClientsFilterAll() => !client.archived,
    ClientsFilterArchived() => client.archived,
    ClientsFilterType(:final type) => !client.archived && client.type == type,
    // Derived from the edited address, as the server's `buildingFor` will be.
    ClientsFilterBuilding(:final key) =>
      !client.archived && buildingKeyFor(client) == key,
  };

  void _setPages(List<List<ClientRecord>> pages) {
    _pagingController.value = _pagingController.value.copyWith(pages: pages);
  }

  void _patchRow(ClientRecord client) {
    final pages = _pagingController.value.pages;
    if (pages == null || _locate(pages, client.id) == null) return;
    final keep = _matchesFilter(client);
    _setPages([
      for (final page in pages)
        [
          for (final row in page)
            if (row.id != client.id) row else if (keep) client,
        ],
    ]);
  }

  (int, int)? _locate(List<List<ClientRecord>> pages, String id) {
    for (var p = 0; p < pages.length; p++) {
      final r = pages[p].indexWhere((row) => row.id == id);
      if (r != -1) return (p, r);
    }
    return null;
  }

  void _patchArchived(String id, {required bool archived}) {
    final pages = _pagingController.value.pages;
    if (pages == null) return;
    final belongs = archived == (widget.filter is ClientsFilterArchived);
    final at = _locate(pages, id);
    if (!belongs) {
      if (at == null) return;
      final (p, r) = at;
      _removedRows[id] = (p, r, pages[p][r]);
      _setPages([
        for (var i = 0; i < pages.length; i++)
          if (i == p) [...pages[i]]..removeAt(r) else pages[i],
      ]);
      return;
    }
    if (at != null) return;
    final removed = _removedRows.remove(id);
    // A row this list never held — un-archived from another surface, say.
    if (removed == null || removed.$1 >= pages.length) {
      _refresh();
      return;
    }
    final (p, r, client) = removed;
    _setPages([
      for (var i = 0; i < pages.length; i++)
        if (i == p)
          [...pages[i]]..insert(
            r.clamp(0, pages[i].length),
            client.copyWith(archived: archived),
          )
        else
          pages[i],
    ]);
  }

  @override
  void dispose() {
    _pagingController.dispose();
    super.dispose();
  }

  // Post-frame: this runs during build, and the header it feeds is a sibling
  // in the same tree.
  void _reportCount(int count) {
    final report = widget.onCountChanged;
    if (report == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) report(count);
    });
  }

  Future<void> _openClient(ClientRecord client) async {
    if (widget.onClientTap != null) {
      widget.onClientTap!(client);
      return;
    }

    await showClientDetailSheet(context, client);
  }

  // Both already reached the list through clientsRefreshProvider (_applyWrite).
  @override
  void onClientArchived(ClientRecord client, {required bool archived}) {}

  @override
  void onClientDeleted(ClientRecord client) {}

  // The Slidable wraps the tile HERE so ClientTile itself can never archive.
  Widget _clientTile(ClientRecord client, int index) {
    final tile = _slidableTile(client, index);
    final wrap = widget.firstRowTourWrap;
    return index == 0 && wrap != null ? wrap(tile) : tile;
  }

  Widget _slidableTile(ClientRecord client, int index) {
    final tile = ClientTile(
      client: client,
      selected: widget.selectedClientId == client.id,
      onOpen: () => _openClient(client),
    );
    // The swipe offers what only an admin may do, so a technician gets the
    // bare tile rather than actions the rules would refuse.
    if (!widget.isAdmin) {
      return FadeInItem(key: ValueKey(client.id), index: index, child: tile);
    }
    return FadeInItem(
      key: ValueKey(client.id),
      index: index,
      child: Slidable(
        key: ValueKey('slide-${client.id}'),
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: canDeleteClient(client) ? 0.5 : 0.28,
          // Full swipe commits Archive ONLY.
          dismissible: DismissiblePane(
            confirmDismiss: () => archiveClient(client),
            onDismissed: () {},
          ),
          children: [
            // Advisory: the callable re-checks with a live count(), so this
            // only keeps the swipe from offering what the server would refuse.
            if (canDeleteClient(client))
              SlidableAction(
                onPressed: (_) => confirmDeleteClient(client),
                backgroundColor: Theme.of(context).palette.dangerFill,
                foregroundColor: Theme.of(context).palette.onDangerFill,
                icon: Icons.delete_outline,
                label: context.l10n.common_delete,
              ),
            SlidableAction(
              onPressed: (_) => archiveClient(client),
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              foregroundColor: Theme.of(
                context,
              ).colorScheme.onSecondaryContainer,
              icon: client.archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              label: client.archived
                  ? context.l10n.clients_unarchive
                  : context.l10n.clients_archive,
            ),
          ],
        ),
        child: tile,
      ),
    );
  }

  Widget _emptyState({required String query}) {
    if (query.isNotEmpty) return _noMatchState(query);
    // Only an admin has the + this copy points at.
    return AppEmptyState(
      icon: Icons.people_outline,
      title: context.l10n.clients_noClientsYet,
      body: widget.isAdmin
          ? context.l10n.clients_tapToAddYourFirstClient
          : context.l10n.clients_noClientsYetHint,
      actionLabel: widget.isAdmin ? context.l10n.clients_addClient : null,
      onAction: widget.isAdmin ? () => runAddClientFlow(context) : null,
    );
  }

  /// A search that found nothing — within the active filter, when there is
  /// one, which is then offered for clearing.
  Widget _noMatchState(String query) {
    final l10n = context.l10n;
    final filterLabel = switch (widget.filter) {
      ClientsFilterAll() => null,
      ClientsFilterArchived() => l10n.clients_filterArchived,
      ClientsFilterType(:final type) => clientTypeLabel(l10n, type),
      ClientsFilterBuilding() =>
        widget.buildingLabel ?? l10n.clients_filterSectionAddress,
    };
    final clear = widget.onClearFilter;
    return AppEmptyState(
      icon: Icons.search_off_outlined,
      title: l10n.clients_noClientsMatchQuery(query),
      body: filterLabel == null
          ? l10n.common_tryADifferentSearchTerm
          : l10n.clients_noMatchWithinFilter(filterLabel),
      actionLabel: filterLabel != null && clear != null
          ? l10n.clients_clearFilter
          : null,
      onAction: filterLabel != null && clear != null ? clear : null,
    );
  }

  // A skeleton row is fixed-height whatever the text scale — SkeletonListTile
  // is all fixed boxes — so how many fit is arithmetic: a 56px tile plus its
  // own 8px bottom margin, with another sp8 between rows.
  static const double _skeletonRowExtent = 64;
  static const int _skeletonMaxRows = 4;

  // The first-page indicator lands inside ISP's SliverFillRemaining, which asks
  // its child for intrinsic dimensions — so this one can neither scroll (a
  // nested ListView throws) nor measure (LayoutBuilder can't report intrinsics
  // either).
  Widget _skeleton() => _carded(const SkeletonList(rows: _skeletonMaxRows));

  // The skeleton sits in a card too, or the list jumps when the page lands.
  Widget _carded(Widget child) {
    if (!widget.grouped) return child;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sp12),
      child: DecoratedBox(
        decoration: appCardDecoration(theme, color: theme.colorScheme.surface),
        child: child,
      ),
    );
  }

  // The search and type paths instead hand the skeleton the whole body of a
  // tight Expanded, which the keyboard shortens well below four rows' worth —
  // no sliver above it here, so the row count can follow the height.
  Widget _fittedSkeleton() => LayoutBuilder(
    builder: (context, constraints) => ClipRect(
      child: _carded(
        SkeletonList(
          rows: constraints.maxHeight.isFinite
              ? ((constraints.maxHeight -
                            AppSpacing.sp16 * 2 +
                            AppSpacing.sp8) /
                        (_skeletonRowExtent + AppSpacing.sp8))
                    .floor()
                    .clamp(1, _skeletonMaxRows)
              : _skeletonMaxRows,
        ),
      ),
    ),
  );

  // Pre-normalized search index over the loaded pages, memoized on the pages
  // identity so normalization reruns only when a page loads, not on every
  // keystroke (mirrors _employeeSearchIndexProvider and the history view's
  // _filterOptionsPages memo).
  List<List<ClientRecord>>? _searchIndexPages;
  List<ClientSearchEntry> _searchIndex = const [];

  List<ClientSearchEntry> _loadedSearchIndex() {
    final state = _pagingController.value;
    if (!identical(state.pages, _searchIndexPages)) {
      _searchIndexPages = state.pages;
      _searchIndex = [
        for (final client in state.items ?? const <ClientRecord>[])
          ClientSearchPolicy.index(client),
      ];
    }
    return _searchIndex;
  }

  // Instant fallback over the already-loaded pages while the comprehensive
  // server search resolves, matching the full field set via the shared policy
  // and ranked the way the repository ranks the server answer, so the debounce
  // commit rarely reorders what is on screen.
  List<ClientRecord> _localFilter(String query) {
    final q = ClientSearchPolicy.normalize(query);
    final qDigits = ClientSearchPolicy.digitsOnly(query);
    if (q.isEmpty && qDigits.isEmpty) return const [];
    final ranked =
        [
          for (final entry in _loadedSearchIndex())
            if (ClientSearchPolicy.entryMatches(
              entry,
              queryText: q,
              queryDigits: qDigits,
            ))
              (
                score: ClientSearchPolicy.scoreRecord(
                  entry.client,
                  queryText: q,
                  queryDigits: qDigits,
                ),
                sortKey: entry.client.displayName.toLowerCase(),
                client: entry.client,
              ),
        ]..sort((a, b) {
          final byScore = a.score.compareTo(b.score);
          return byScore != 0 ? byScore : a.sortKey.compareTo(b.sortKey);
        });
    return [for (final entry in ranked) entry.client];
  }

  // The full search runs on the debounced, committed query across all fields
  // and pages.
  Widget _buildSearchResults(String query) {
    final local = _localFilter(query);

    if (committedQuery != query) {
      // Still typing — show instant local results (skeleton if none yet).
      return local.isEmpty ? _fittedSkeleton() : _resultsList(local);
    }

    return ref
        .watch(clientSearchProvider((query, widget.filter)))
        .when(
          // Local hits outrank an empty server answer: the index can lag a
          // write the loaded page already shows.
          data: (results) => results.isNotEmpty
              ? _searchResults(results)
              : local.isEmpty
              ? _emptyState(query: query)
              : _resultsList(local),
          loading: () =>
              local.isEmpty ? _fittedSkeleton() : _resultsList(local),
          // A failed search must not look like "no such client" — show an error
          // when the instant local fallback is also empty, not the empty state.
          error: (e, _) =>
              local.isEmpty ? _searchError(e, query) : _resultsList(local),
        );
  }

  Widget _searchResults(List<ClientRecord> results) {
    final list = _resultsList(results);
    if (results is! ClientSearchResults || !results.truncated) return list;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sp12),
          child: WarningNote(
            message: results.matchedCountIsLowerBound
                ? context.l10n.clients_searchTruncatedAtLeast(results.length)
                : context.l10n.clients_searchTruncated(
                    results.length,
                    results.matchedCount,
                  ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  Widget _typeEmptyState(ClientType type) => AppEmptyState(
    icon: Icons.filter_list_off_outlined,
    title: context.l10n.clients_noClientsOfType(
      clientTypeLabel(context.l10n, type),
    ),
    body: context.l10n.clients_typeFilterHint,
  );

  Widget _archivedEmptyState() => AppEmptyState(
    icon: Icons.inventory_2_outlined,
    title: context.l10n.clients_noArchivedClients,
    body: context.l10n.clients_archivedFilterHint,
  );

  // Retry re-runs the failed search by invalidating its provider instance; this
  // rebuild is already watching it, so it refetches immediately.
  Widget _searchError(Object error, String query) => _errorState(
    error,
    onRetry: () => ref.invalidate(clientSearchProvider((query, widget.filter))),
  );

  Widget _errorState(Object error, {required VoidCallback onRetry}) =>
      AppEmptyState(
        icon: Icons.error_outline,
        title: context.l10n.error_introLoadClients,
        body: errorCauseFor(context.l10n, error),
        actionLabel: context.l10n.common_retry,
        onAction: onRetry,
      );

  Widget _buildingEmptyState() => AppEmptyState(
    icon: Icons.apartment_outlined,
    title: context.l10n.clients_noClientsAtAddress,
    body: context.l10n.clients_buildingFilterHint,
  );

  List<ClientRecord>? _groupedSource;
  String? _groupedHeading;
  List<ClientGroup> _groups = const [];

  List<ClientGroup> _groupsFor(List<ClientRecord> items) {
    final heading = widget.filter is ClientsFilterBuilding
        ? widget.buildingLabel
        : null;
    if (identical(items, _groupedSource) && heading == _groupedHeading) {
      return _groups;
    }
    _groupedSource = items;
    _groupedHeading = heading;
    // Stored-name order can differ from display-name order (phone identities),
    // so letter headings would split or repeat as server pages arrive.
    return _groups = singleGroupOf(items, heading: heading);
  }

  Widget _resultsList(List<ClientRecord> items) {
    _reportCount(items.length);
    if (widget.grouped) {
      return ClientsSliverList(
        groups: _groupsFor(items),
        itemBuilder: (context, index) => _clientTile(items[index], index),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: kFloatingControlsClearance),
      itemCount: items.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, indent: 64),
      itemBuilder: (context, index) => _clientTile(items[index], index),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(clientsRefreshProvider, (_, write) => _applyWrite(write));

    final query = widget.searchQuery.trim();
    if (query.isNotEmpty) return _buildSearchResults(query);

    return RefreshIndicator.adaptive(
      onRefresh: () async => _refresh(),
      child: widget.grouped ? _groupedPagedList() : _pagedList(),
    );
  }

  Widget _filteredEmptyState() => switch (widget.filter) {
    ClientsFilterArchived() => _archivedEmptyState(),
    ClientsFilterType(:final type) => _typeEmptyState(type),
    ClientsFilterBuilding() => _buildingEmptyState(),
    ClientsFilterAll() => _emptyState(query: ''),
  };

  // Cards and headings are slivers, which PagedListView cannot host.
  Widget _groupedPagedList() => PagingListener<int, ClientRecord>(
    controller: _pagingController,
    builder: (context, state, fetchNextPage) {
      final loaded = _loadedRows.of(
        state.pages,
        () => state.items ?? const <ClientRecord>[],
      );
      _reportCount(loaded.length);
      if (loaded.isEmpty) {
        if (state.status == PagingStatus.loadingFirstPage) {
          requestFirstPage(state, fetchNextPage);
        }
        return switch (state.status) {
          PagingStatus.loadingFirstPage => _skeleton(),
          PagingStatus.firstPageError => _errorState(
            state.error ?? Exception('clients page load failed'),
            onRetry: _refresh,
          ),
          _ => _filteredEmptyState(),
        };
      }
      return ClientsSliverList(
        groups: _groupsFor(loaded),
        itemBuilder: (context, index) => _clientTile(loaded[index], index),
        footer: PagedListFooter<int, ClientRecord>(
          state: state,
          onRetry: fetchNextPage,
        ),
        onRowBuilt: (index) =>
            maybeFetchNext(state, fetchNextPage, index, loaded.length),
      );
    },
  );

  Widget _pagedList() => PagingListener<int, ClientRecord>(
    controller: _pagingController,
    builder: (context, state, fetchNextPage) {
      _reportCount(state.items?.length ?? 0);
      return PagedListView<int, ClientRecord>.separated(
        state: state,
        fetchNextPage: fetchNextPage,
        padding: const EdgeInsets.only(bottom: kFloatingControlsClearance),
        separatorBuilder: (context, index) =>
            const Divider(height: 1, indent: 64),
        builderDelegate: PagedChildBuilderDelegate<ClientRecord>(
          itemBuilder: (context, client, index) => _clientTile(client, index),
          firstPageProgressIndicatorBuilder: (_) => _skeleton(),
          firstPageErrorIndicatorBuilder: (_) => _errorState(
            state.error ?? Exception('clients page load failed'),
            onRetry: _refresh,
          ),
          noItemsFoundIndicatorBuilder: (_) => _filteredEmptyState(),
        ),
      );
    },
  );
}
