import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/layout/master_detail_scaffold.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_filter_bar.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_list_header.dart';
import 'package:scheduling/features/clients/widgets/sheets/add_client_flow.dart';
import 'package:scheduling/features/clients/widgets/sheets/client_detail_sheet.dart';
import 'package:scheduling/features/clients/widgets/sheets/clients_filter_sheet.dart';
import 'package:scheduling/features/clients/widgets/views/client_detail_view.dart';
import 'package:scheduling/features/clients/widgets/views/clients_list_view.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/feedback/app_empty_state.dart';
import 'package:scheduling/shared/widgets/fields/app_search_bar.dart';
import 'package:scheduling/shared/widgets/primitives/scroll_to_top_button.dart';

class ListInformation extends ConsumerStatefulWidget {
  const ListInformation({
    required this.isAdmin,
    required this.employeeId,
    super.key,
  });

  final bool isAdmin;
  final String employeeId;

  @override
  ConsumerState<ListInformation> createState() => _ListInformationState();
}

class _ListInformationState extends ConsumerState<ListInformation> {
  final TextEditingController _searchController = TextEditingController();
  ClientRecord? _selectedClient;
  ClientsFilter _filter = const ClientsFilterAll();
  ClientsSort _sort = ClientsSort.name;
  int? _visibleCount;

  /// Street of the active building filter, remembered when it is picked so the
  /// chip can name it without this screen watching the scan.
  String? _activeBuildingLabel;

  /// Whether the list's first page has settled — gates the feature tour.
  bool _listSettled = false;

  late final _tour = TourSteps(
    const DestinationTour(HubTab.clients),
    isAdmin: widget.isAdmin,
  );

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openFilterSheet() async {
    final picked = await showClientsFilterSheet(context, selected: _filter);
    if (picked == null || !mounted) return;
    _logFilter(picked.filter);
    setState(() {
      _filter = picked.filter;
      _activeBuildingLabel = picked.buildingLabel;
    });
  }

  /// A chip picks one of the fixed filters, so it never carries an address —
  /// any of them clears the label the sheet left behind.
  void _applyFilter(ClientsFilter filter) {
    _logFilter(filter);
    setState(() {
      _filter = filter;
      _activeBuildingLabel = null;
    });
  }

  void _logFilter(ClientsFilter filter) {
    // The building KEY is a street address — reported as the filter KIND only,
    // never its value.
    // One switch, so a fifth variant cannot report a value under a name the
    // other half got right — a `_ =>` default on either defeats exhaustiveness.
    final (filterName, filterValue) = switch (filter) {
      ClientsFilterAll() => (AnalyticsFilters.none, null),
      ClientsFilterType(:final type) => (AnalyticsFilters.type, type.name),
      ClientsFilterBuilding() => (AnalyticsFilters.building, null),
      ClientsFilterArchived() => (AnalyticsFilters.archived, null),
    };
    ref
        .read(analyticsServiceProvider)
        .logFilterUsed(
          surface: AnalyticsSurfaces.clients,
          filterName: filterName,
          filterValue: filterValue,
        );
  }

  void _onListSettled() {
    if (_listSettled) return;
    setState(() => _listSettled = true);
  }

  Future<void> _onClientTap(ClientRecord client) async {
    if (context.isTwoPane) {
      setState(() => _selectedClient = client);
      return;
    }

    await showClientDetailSheet(context, client);
  }

  void _backToCalendar() => navigateToDestination(
    context,
    HubTab.calendar,
    isAdmin: widget.isAdmin,
    employeeId: widget.employeeId,
  );

  Widget _buildDetailPlaceholder() => DetailPlaceholder(
    icon: Icons.people_outline_rounded,
    message: context.l10n.clients_selectAClientToViewDetails,
  );

  @override
  Widget build(BuildContext context) {
    final searchBar = AppSearchBar(
      textScaler: MediaQuery.textScalerOf(context),
      controller: _searchController,
      hintText: context.l10n.clients_searchAllFields,
    );
    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: widget.isAdmin,
      stepKeys: _tour.keys,
      // The client-row step has no target while the list is still its
      // skeleton, so an ungated tour would open on nothing.
      ready: _listSettled,
      child: Scaffold(
        appBar: AppTopBar(
          title: context.l10n.common_clients,
          compact: context.isLandscape,
          onBack: _backToCalendar,
          actions: const [AppHeaderPair()],
          bottom: _tour.stepBarIf(TourStepId.clientsSearch, searchBar),
        ),
        endDrawer: AppNavDrawer(
          isAdmin: widget.isAdmin,
          employeeId: widget.employeeId,
        ),
        floatingActionButton: widget.isAdmin
            ? _tour.step(
                TourStepId.clientsAdd,
                targetBorderRadius: BorderRadius.circular(AppRadius.r16),
                child: FloatingActionButton(
                  // Needs to be unique across tabs, since IndexedStack keeps every tab's FAB mounted at the same time.
                  heroTag: 'clientsAddFab',
                  onPressed: () => runAddClientFlow(context),
                  tooltip: context.l10n.clients_addClient,
                  child: const Icon(Icons.add),
                ),
              )
            : null,
        // Only the master list listens to the search controller, so typing rebuilds just the list.
        body: MasterDetailScaffold(
          master: Column(
            children: [
              // One row: Filter, what the list is showing, and the order.
              ClientsListHeader(
                leading: _tour.stepIf(
                  TourStepId.clientsFilter,
                  ClientsFilterBar(selected: _filter, onOpen: _openFilterSheet),
                ),
                sortWrap: (child) =>
                    _tour.stepIf(TourStepId.clientsSort, child),
                onClearFilter: () => _applyFilter(const ClientsFilterAll()),
                count: _visibleCount,
                // Only the unfiltered list pages; every filtered slice loads
                // whole, so its shown count IS its total.
                total: _filter is ClientsFilterAll
                    ? ref.watch(clientsTotalCountProvider).value
                    : null,
                filter: _filter,
                sort: _sort,
                onSortChanged: (next) {
                  ref
                      .read(analyticsServiceProvider)
                      .logFilterUsed(
                        surface: AnalyticsSurfaces.clients,
                        filterName: AnalyticsFilters.sort,
                        filterValue: next.name,
                      );
                  setState(() => _sort = next);
                },
              ),
              Expanded(
                // The floating controls and the list's bottom clearance are
                // both measured from here, so this has to end ABOVE the home
                // indicator — the same wrap the calendar's agenda uses.
                child: SafeArea(
                  top: false,
                  child: Stack(
                    children: [
                      ListenableBuilder(
                        listenable: _searchController,
                        builder: (context, _) => ClientsListView(
                          searchQuery: _searchController.text,
                          isAdmin: widget.isAdmin,
                          filter: _filter,
                          grouped: true,
                          buildingLabel: _activeBuildingLabel,
                          // Only highlight the selected row when the detail pane is shown (two-pane).
                          selectedClientId: context.isTwoPane
                              ? _selectedClient?.id
                              : null,
                          onClientTap: _onClientTap,
                          firstRowTourWrap: (child) =>
                              _tour.stepIf(TourStepId.clientsRow, child),
                          onFirstPageSettled: _onListSettled,
                          sort: _sort,
                          onCountChanged: (count) {
                            if (_visibleCount == count) return;
                            setState(() => _visibleCount = count);
                          },
                        ),
                      ),
                      // Bottom LEFT: the add FAB owns the right corner, the same
                      // split the calendar's Today pill keeps.
                      const Positioned(
                        left: AppSpacing.sp16,
                        bottom: AppSpacing.sp16,
                        child: ScrollToTopButton(),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          detail: _selectedClient != null
              ? ClientDetailView(
                  key: ValueKey(_selectedClient!.id),
                  client: _selectedClient!,
                  onDeleted: () => setState(() => _selectedClient = null),
                )
              : null,
          placeholder: _buildDetailPlaceholder(),
        ),
      ),
    );
  }
}
