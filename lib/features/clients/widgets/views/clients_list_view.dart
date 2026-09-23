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
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
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

  late final PagingController<int, ClientRecord> _pagingController =
      PagingController<int, ClientRecord>(
        getNextPageKey: (state) {
          final pages = state.pages;
          if (pages == null) return 1;

          if (pages.isNotEmpty && pages.last.length < _pageSize) return null;
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
    try {
      final items = _pagingController.value.items;
      final after = (pageKey == 1 || items == null || items.isEmpty)
          ? null
          : items.last;
      return await repository.fetchClientsPage(
        after: after,
        limit: _pageSize,
        sort: widget.sort,
        filter: widget.filter,
      );
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
      _pagingController.refresh();
    }
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

  // An archived client leaves this list and a deleted one is gone, so both are
  // the same refresh here.
  @override
  void onClientArchived(ClientRecord client, {required bool archived}) =>
      _pagingController.refresh();

  @override
  void onClientDeleted(ClientRecord client) => _pagingController.refresh();

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
    return AppEmptyState(
      icon: query.isEmpty ? Icons.people_outline : Icons.search_off_outlined,
      title: query.isEmpty
          ? context.l10n.clients_noClientsYet
          : '${context.l10n.clients_noClientsMatch} "$query"',
      body: query.isEmpty
          ? context.l10n.clients_tapToAddYourFirstClient
          : context.l10n.common_tryADifferentSearchTerm,
      actionLabel: query.isEmpty && widget.isAdmin
          ? context.l10n.clients_addClient
          : null,
      onAction: query.isEmpty && widget.isAdmin
          ? () => runAddClientFlow(context)
          : null,
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
  // server search resolves, matching the full field set via the shared policy.
  List<ClientRecord> _localFilter(String query) {
    final q = ClientSearchPolicy.normalize(query);
    final qDigits = ClientSearchPolicy.digitsOnly(query);
    if (q.isEmpty && qDigits.isEmpty) return const [];
    return [
      for (final entry in _loadedSearchIndex())
        if (ClientSearchPolicy.entryMatches(
          entry,
          queryText: q,
          queryDigits: qDigits,
        ))
          entry.client,
    ];
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
        .watch(
          widget.filter is ClientsFilterAll
              ? clientSearchProvider(query)
              : clientFilteredSearchProvider((query, widget.filter)),
        )
        .when(
          data: (results) => results.isEmpty
              ? _emptyState(query: query)
              : _resultsList(results),
          loading: () =>
              local.isEmpty ? _fittedSkeleton() : _resultsList(local),
          // A failed search must not look like "no such client" — show an error
          // when the instant local fallback is also empty, not the empty state.
          error: (e, _) =>
              local.isEmpty ? _searchError(e, query) : _resultsList(local),
        );
  }

  Widget _typeEmptyState({required ClientType type, required String query}) =>
      AppEmptyState(
        icon: Icons.filter_list_off_outlined,
        title: query.isEmpty
            ? context.l10n.clients_noClientsOfType(
                clientTypeLabel(context.l10n, type),
              )
            : '${context.l10n.clients_noClientsMatch} "$query"',
        body: query.isEmpty
            ? context.l10n.clients_typeFilterHint
            : context.l10n.common_tryADifferentSearchTerm,
      );

  Widget _archivedEmptyState(String query) => AppEmptyState(
    icon: Icons.inventory_2_outlined,
    title: query.isEmpty
        ? context.l10n.clients_noArchivedClients
        : '${context.l10n.clients_noClientsMatch} "$query"',
    body: query.isEmpty
        ? context.l10n.clients_archivedFilterHint
        : context.l10n.common_tryADifferentSearchTerm,
  );

  // Retry re-runs the failed search by invalidating its provider instance; this
  // rebuild is already watching it, so it refetches immediately.
  Widget _searchError(Object error, String query) => _errorState(
    error,
    onRetry: () {
      if (widget.filter is ClientsFilterAll) {
        ref.invalidate(clientSearchProvider(query));
      } else {
        ref.invalidate(clientFilteredSearchProvider((query, widget.filter)));
      }
    },
  );

  Widget _errorState(Object error, {required VoidCallback onRetry}) =>
      AppEmptyState(
        icon: Icons.error_outline,
        title: context.l10n.error_somethingWentWrong,
        body: composeErrorNotice(
          context,
          intro: context.l10n.error_introLoadClients,
          error: error,
        ),
        actionLabel: context.l10n.common_retry,
        onAction: onRetry,
      );

  Widget _buildingEmptyState({required String query}) => AppEmptyState(
    icon: Icons.apartment_outlined,
    title: query.isEmpty
        ? context.l10n.clients_noClientsAtAddress
        : '${context.l10n.clients_noClientsMatch} "$query"',
    body: query.isEmpty
        ? context.l10n.clients_typeFilterHint
        : context.l10n.common_tryADifferentSearchTerm,
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
    ref.listen(clientsRefreshProvider, (_, _) => _pagingController.refresh());

    final query = widget.searchQuery.trim();
    if (query.isNotEmpty) return _buildSearchResults(query);

    return RefreshIndicator.adaptive(
      onRefresh: () async => _pagingController.refresh(),
      child: widget.grouped ? _groupedPagedList() : _pagedList(),
    );
  }

  Widget _filteredEmptyState() => switch (widget.filter) {
    ClientsFilterArchived() => _archivedEmptyState(''),
    ClientsFilterType(:final type) => _typeEmptyState(type: type, query: ''),
    ClientsFilterBuilding() => _buildingEmptyState(query: ''),
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
            onRetry: _pagingController.refresh,
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
            onRetry: _pagingController.refresh,
          ),
          noItemsFoundIndicatorBuilder: (_) => _filteredEmptyState(),
        ),
      );
    },
  );
}
