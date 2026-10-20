import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/features/calendar/domain/assignee_resolver.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/policies/history_search_policy.dart';
import 'package:scheduling/features/clients/application/appointment_history_providers.dart';
import 'package:scheduling/features/clients/domain/history_grouping.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';
import 'package:scheduling/features/clients/widgets/lists/history_sliver_list.dart';
import 'package:scheduling/features/clients/widgets/lists/paged_sliver_driver.dart';
import 'package:scheduling/features/clients/widgets/sections/history_filter_bar.dart';
import 'package:scheduling/features/clients/widgets/views/debounced_paged_search.dart';
import 'package:scheduling/features/clients/widgets/views/row_cache.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/feedback/app_empty_state.dart';
import 'package:scheduling/shared/widgets/feedback/skeleton_loader.dart';

/// Pre-normalized row text for cheap local filtering, paired with its row.
typedef _HistoryRow = ({
  AppointmentRecord appointment,
  HistorySearchEntry entry,
});

/// Paginated history list, newest first.
class AppointmentHistoryView extends ConsumerStatefulWidget {
  const AppointmentHistoryView({
    required this.searchQuery,
    super.key,
    this.isAdmin = false,
    this.filterTourWrap,
    this.firstRowTourWrap,
    this.onFirstPageSettled,
  });

  final String searchQuery;

  /// Caller role gate passed to appointment details.
  final bool isAdmin;

  /// Optional feature-tour wrapper for the filter bar.
  final Widget Function(Widget child)? filterTourWrap;

  /// Optional feature-tour wrapper for the first row.
  final Widget Function(Widget child)? firstRowTourWrap;

  /// Fires once the first page replaces the skeleton.
  final VoidCallback? onFirstPageSettled;

  @override
  ConsumerState<AppointmentHistoryView> createState() =>
      _AppointmentHistoryViewState();
}

class _AppointmentHistoryViewState extends ConsumerState<AppointmentHistoryView>
    with
        DebouncedPagedSearch<AppointmentHistoryView>,
        PagedSliverPrefetch<AppointmentHistoryView> {
  static const int _pageSize = 25;

  /// Pages fetched on the user's behalf while a chip filter matches nothing
  /// loaded, before the empty state is shown: 20 × 25 rows.
  static const int _emptyFilterFetchCap = 20;

  @override
  String searchQueryOf(AppointmentHistoryView widget) => widget.searchQuery;

  @override
  VoidCallback? get onFirstPageSettled => widget.onFirstPageSettled;

  @override
  String get searchDebounceTag => 'HIST-SEARCH debounced search failed';

  @override
  String get analyticsSurface => AnalyticsSurfaces.history;

  void _logFilter(String name, {String? value}) {
    ref
        .read(analyticsServiceProvider)
        .logFilterUsed(
          surface: analyticsSurface,
          filterName: name,
          filterValue: value,
        );
  }

  int? _year;
  String? _employeeId;
  HistoryStatusFilter? _status;

  // Recompute filter/search indexes only when pages change.
  List<List<AppointmentRecord>>? _filterOptionsPages;
  int? _cachedCurrentYear;
  List<int> _cachedYears = const [];
  List<HistoryEmployeeOption> _cachedEmployees = const [];
  List<_HistoryRow> _searchIndex = const [];

  /// Memoized tally for the current row list.
  List<AppointmentRecord>? _talliedRows;
  HistoryTally _tally = (total: 0, cancelled: 0);

  HistoryTally _tallyFor(List<AppointmentRecord> rows) {
    if (!identical(rows, _talliedRows)) {
      _talliedRows = rows;
      _tally = tallyOf(rows);
    }
    return _tally;
  }

  /// Cached row lists for loaded, filtered, and searched states.
  final RowCache<AppointmentRecord> _loadedRows = RowCache();
  final RowCache<AppointmentRecord> _filteredRows = RowCache();
  final RowCache<AppointmentRecord> _searchRows = RowCache();

  late final PagingController<int, AppointmentRecord> _pagingController =
      PagingController<int, AppointmentRecord>(
        getNextPageKey: (state) {
          final pages = state.pages;
          if (pages == null) return 1;
          if (pages.isNotEmpty && pages.last.length < _pageSize) return null;
          return (state.keys?.last ?? 0) + 1;
        },
        fetchPage: _fetchPage,
      );

  @override
  void initState() {
    super.initState();
    // Load the first page after the widget mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pagingController.fetchNextPage();
    });
  }

  Future<List<AppointmentRecord>> _fetchPage(int pageKey) async {
    // Read providers before await; the page can settle after dispose.
    final logger = ref.read(loggerProvider);
    try {
      final items = _pagingController.value.items;
      final after = (pageKey == 1 || items == null || items.isEmpty)
          ? null
          : items.last;
      return await ref
          .read(historyPagerProvider)
          .fetchPage(after: after, limit: _pageSize);
    } catch (e, st) {
      logger.warn('HIST-LOAD history page fetch error', e, st);
      rethrow;
    } finally {
      if (pageKey == 1) notifyFirstPageSettled();
    }
  }

  @override
  void dispose() {
    _pagingController.dispose();
    super.dispose();
  }

  void _clearFilters() => setState(() {
    _year = null;
    _employeeId = null;
    _status = null;
  });

  // Every year from the oldest loaded one up to today's, newest first — a gap
  // year is pickable too; the pager then runs until it is reached or passed.
  List<int> _yearsOf(List<AppointmentRecord> appointments, int currentYear) {
    if (appointments.isEmpty) return const [];
    var oldest = currentYear;
    for (final a in appointments) {
      if (a.startTime.year < oldest) oldest = a.startTime.year;
    }
    return [for (var y = currentYear; y >= oldest; y--) y];
  }

  List<HistoryEmployeeOption> _employeesOf(
    List<AppointmentRecord> appointments,
  ) {
    final names = <String, String>{};
    for (final a in appointments) {
      for (var i = 0; i < a.employeeIds.length; i++) {
        final id = a.employeeIds[i];
        if (id.isEmpty) continue;
        final name = assigneeNameAt(a.employeeNames, i) ?? '';
        final existing = names[id];
        if (existing == null || (existing.isEmpty && name.isNotEmpty)) {
          names[id] = name;
        }
      }
    }
    final options = [
      for (final e in names.entries)
        (id: e.key, name: e.value.isEmpty ? e.key : e.value),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return options;
  }

  bool get _hasChipFilter =>
      _year != null || _employeeId != null || _status != null;

  /// Pages auto-fetched for the current chips while nothing loaded matched.
  (int?, String?, HistoryStatusFilter?)? _emptyFetchChips;
  int _emptyFetches = 0;

  // Newest-first pages: once the last loaded row predates the chosen year, no
  // later page can hold it.
  bool _yearPassed(List<AppointmentRecord> loaded) =>
      _year != null && loaded.isNotEmpty && loaded.last.startTime.year < _year!;

  bool _mayAutoFetch(
    PagingState<int, AppointmentRecord> state,
    List<AppointmentRecord> loaded,
  ) {
    final chips = (_year, _employeeId, _status);
    if (chips != _emptyFetchChips) {
      _emptyFetchChips = chips;
      _emptyFetches = 0;
    }
    return state.hasNextPage &&
        state.error == null &&
        !_yearPassed(loaded) &&
        _emptyFetches < _emptyFilterFetchCap;
  }

  bool get _hasActiveFilter =>
      widget.searchQuery.trim().isNotEmpty || _hasChipFilter;

  // Applies chip filters without text search.
  List<AppointmentRecord> _applyChips(List<AppointmentRecord> appointments) =>
      appointments.where(_matchesChips).toList();

  bool _matchesChips(AppointmentRecord a) {
    if (_year != null && a.startTime.year != _year) return false;
    if (_employeeId != null && !a.employeeIds.contains(_employeeId)) {
      return false;
    }
    if (_status != null && !_status!.matches(a)) return false;
    return true;
  }

  // Local text search uses the memoized row index.
  List<AppointmentRecord> _filterLoaded() {
    final hasQuery = widget.searchQuery.trim().isNotEmpty;
    // Match folded text and digits-only phone numbers.
    final qText = ClientSearchPolicy.normalize(widget.searchQuery);
    final qDigits = ClientSearchPolicy.digitsOnly(widget.searchQuery);
    return [
      for (final row in _searchIndex)
        if (_matchesChips(row.appointment) &&
            (!hasQuery ||
                historyEntryMatches(
                  row.entry,
                  queryText: qText,
                  queryDigits: qDigits,
                )))
          row.appointment,
    ];
  }

  /// Filter row for the loaded history.
  Widget _filterBar(List<int> years, List<HistoryEmployeeOption> employees) {
    final bar = Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.sp8,
        bottom: AppSpacing.sp4,
      ),
      child: HistoryFilterBar(
        years: years,
        selectedYear: _year,
        // Never the chosen year, employee id or client — only WHICH control
        // was used, and for status the fixed enum value.
        onYearChanged: (v) {
          _logFilter(AnalyticsFilters.year);
          setState(() => _year = v);
        },
        employees: employees,
        selectedEmployeeId: _employeeId,
        onEmployeeChanged: (v) {
          _logFilter(AnalyticsFilters.employee);
          setState(() => _employeeId = v);
        },
        selectedStatus: _status,
        onStatusChanged: (v) {
          _logFilter(AnalyticsFilters.status, value: v?.name);
          setState(() => _status = v);
        },
      ),
    );
    return widget.filterTourWrap?.call(bar) ?? bar;
  }

  @override
  Widget build(BuildContext context) {
    final colorMap = ref.watch(employeeColorMapProvider);
    // Watch currentYear so New Year updates the rail.
    final currentYear = ref.watch(currentDayProvider).year;

    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: PagingListener<int, AppointmentRecord>(
        controller: _pagingController,
        builder: (context, state, fetchNextPage) {
          // Cache flattened pages so identity-based memos can hit.
          final loaded = _loadedRows.of((
            state.pages,
          ), () => state.items ?? const <AppointmentRecord>[]);
          // Filter options and search index share page identity.
          if (!identical(state.pages, _filterOptionsPages) ||
              _cachedCurrentYear != currentYear) {
            _filterOptionsPages = state.pages;
            _cachedCurrentYear = currentYear;
            _cachedYears = _yearsOf(loaded, currentYear);
            _cachedEmployees = _employeesOf(loaded);
            _searchIndex = [
              for (final a in loaded)
                (appointment: a, entry: historyEntryOf(a)),
            ];
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (loaded.isNotEmpty) _filterBar(_cachedYears, _cachedEmployees),
              Expanded(
                child: _hasActiveFilter
                    ? _buildFiltered(
                        state,
                        loaded,
                        fetchNextPage,
                        colorMap,
                        currentYear,
                      )
                    : _buildPaged(
                        state,
                        loaded,
                        fetchNextPage,
                        colorMap,
                        currentYear,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPaged(
    PagingState<int, AppointmentRecord> state,
    // Hoist flattened items out of itemBuilder.
    List<AppointmentRecord> loaded,
    void Function() fetchNextPage,
    Map<String, Color> colorMap,
    int currentYear,
  ) {
    if (loaded.isEmpty) {
      if (state.status == PagingStatus.loadingFirstPage) {
        requestFirstPage(state, fetchNextPage);
      }
      // AppEmptyState owns its own scrollable.
      return switch (state.status) {
        PagingStatus.loadingFirstPage => _skeleton(),
        PagingStatus.firstPageError => _errorState(
          state.error ?? Exception('history page load failed'),
          onRetry: _pagingController.refresh,
        ),
        _ => AppEmptyState(
          icon: Icons.history_outlined,
          title: context.l10n.common_noAppointmentsFound,
          body: context.l10n.common_tapToScheduleAnAppointment,
        ),
      };
    }

    return RefreshIndicator.adaptive(
      onRefresh: () async => _pagingController.refresh(),
      child: _countedList(
        rows: loaded,
        colorMap: colorMap,
        currentYear: currentYear,
        inSearch: false,
        footer: PagedListFooter<int, AppointmentRecord>(
          state: state,
          onRetry: fetchNextPage,
        ),
        onRowBuilt: (index) =>
            maybeFetchNext(state, fetchNextPage, index, loaded.length),
      ),
    );
  }

  Widget _buildFiltered(
    PagingState<int, AppointmentRecord> state,
    List<AppointmentRecord> loaded,
    void Function() fetchNextPage,
    Map<String, Color> colorMap,
    int currentYear,
  ) {
    final query = widget.searchQuery.trim();

    Widget list(List<AppointmentRecord> rows, {required bool inSearch}) {
      if (rows.isEmpty) return _buildEmptyState(context);
      return _countedList(
        rows: rows,
        colorMap: colorMap,
        currentYear: currentYear,
        inSearch: inSearch,
      );
    }

    // Cache allocated filter results on their inputs.
    final filterKey = (_searchIndex, query, _year, _employeeId, _status);
    List<AppointmentRecord> filteredLoaded() =>
        _filteredRows.of(filterKey, _filterLoaded);

    // Chip-only filtering is a filter over the PAGER, not over page one: the
    // footer and prefetch stay wired, and a page with no match fetches the next.
    if (query.isEmpty) {
      final rows = filteredLoaded();
      if (rows.isEmpty) {
        if (state.isLoading) return _skeleton();
        if (state.error != null) {
          return _errorState(state.error!, onRetry: fetchNextPage);
        }
        if (!_mayAutoFetch(state, loaded)) return _buildEmptyState(context);
        _emptyFetches++;
        requestFirstPage(state, fetchNextPage);
        return _skeleton();
      }
      return _countedList(
        rows: rows,
        colorMap: colorMap,
        currentYear: currentYear,
        inSearch: false,
        footer: PagedListFooter<int, AppointmentRecord>(
          state: state,
          onRetry: fetchNextPage,
        ),
        onRowBuilt: (index) =>
            maybeFetchNext(state, fetchNextPage, index, rows.length),
      );
    }

    // Local filtering fills the debounce gap.
    Widget localOr(Widget Function() onEmpty) {
      final local = filteredLoaded();
      return local.isEmpty ? onEmpty() : list(local, inSearch: true);
    }

    if (committedQuery != query) {
      return localOr(_skeleton);
    }

    return ref
        .watch(historySearchProvider(query))
        .when(
          data: (results) => list(
            // Provider identity holds until it refetches.
            _searchRows.of((
              results,
              _year,
              _employeeId,
              _status,
            ), () => _applyChips(results)),
            inSearch: true,
          ),
          loading: () => localOr(_skeleton),
          // Show search errors only when local fallback is empty.
          error: (e, _) => localOr(() => _searchError(e, query)),
        );
  }

  // Retry invalidates the watched search provider.
  Widget _searchError(Object error, String query) => _errorState(
    error,
    onRetry: () => ref.invalidate(historySearchProvider(query)),
  );

  Widget _errorState(Object error, {required VoidCallback onRetry}) =>
      AppEmptyState(
        icon: Icons.error_outline,
        title: context.l10n.error_introLoadHistory,
        body: errorCauseFor(context.l10n, error),
        actionLabel: context.l10n.common_retry,
        onAction: onRetry,
      );

  /// Count line and the rows it describes.
  Widget _countedList({
    required List<AppointmentRecord> rows,
    required Map<String, Color> colorMap,
    required int currentYear,
    required bool inSearch,
    Widget? footer,
    void Function(int index)? onRowBuilt,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _HistoryCountLine(tally: _tallyFor(rows), inSearch: inSearch),
      Expanded(
        child: HistorySliverList(
          rows: rows,
          colorMap: colorMap,
          currentYear: currentYear,
          inSearch: inSearch,
          isAdmin: widget.isAdmin,
          footer: footer,
          onRowBuilt: onRowBuilt,
          firstRowTourWrap: widget.firstRowTourWrap,
        ),
      ),
    ],
  );

  Widget _skeleton() =>
      const SkeletonList(padding: EdgeInsets.all(AppSpacing.sp12));

  Widget _buildEmptyState(BuildContext context) {
    final l10n = context.l10n;
    final query = widget.searchQuery.trim();

    if (query.isNotEmpty && !_hasChipFilter) {
      return AppEmptyState(
        icon: Icons.search_off_outlined,
        title: l10n.clients_noAppointmentsMatchQuery(query),
        body: l10n.common_tryADifferentSearchTerm,
      );
    }
    return AppEmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: l10n.clients_noAppointmentsMatchFilters,
      body: l10n.common_tryADifferentSearchTerm,
      actionLabel: _hasChipFilter ? l10n.clients_clearFilters : null,
      onAction: _hasChipFilter ? _clearFilters : null,
    );
  }
}

/// Count label for jobs/results and cancelled subset.
class _HistoryCountLine extends StatelessWidget {
  const _HistoryCountLine({required this.tally, required this.inSearch});

  final HistoryTally tally;
  final bool inSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final head = inSearch
        ? l10n.clients_historyResultsCount(tally.total)
        : l10n.clients_historyJobsCount(tally.total);
    final label = tally.cancelled == 0
        ? head
        : '$head · ${l10n.clients_historyCancelledCount(tally.cancelled)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp12,
        AppSpacing.sp8,
        AppSpacing.sp12,
        AppSpacing.sp8,
      ),
      child: Text(label, style: Theme.of(context).monoType.label),
    );
  }
}
