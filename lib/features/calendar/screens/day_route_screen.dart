import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/adaptive/adaptive_action_sheet.dart';
import 'package:scheduling/core/adaptive/adaptive_pickers.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/launchers/route_map_launcher.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/layout/primary_scroll_scope.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/appointment_status_values.dart';
import 'package:scheduling/features/calendar/domain/day_route.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/cards/appointment_card.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/maps/address_map_launcher.dart';
import 'package:scheduling/features/maps/domain/route_url_builder.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/feedback/app_empty_state.dart';
import 'package:scheduling/shared/widgets/feedback/skeleton_loader.dart';

/// True while a job still belongs in the driving route.
bool _isOpen(String status) => !isTerminalStatusRaw(status);

/// Shows a day's jobs as a numbered route timeline.
class DayRouteScreen extends ConsumerStatefulWidget {
  const DayRouteScreen({
    required this.isAdmin,
    required this.employeeId,
    super.key,
  });

  final bool isAdmin;
  final String employeeId;

  @override
  ConsumerState<DayRouteScreen> createState() => _DayRouteScreenState();
}

class _DayRouteScreenState extends ConsumerState<DayRouteScreen> {
  late DateTime _day;
  late String _selectedEmployeeId;
  late final _tour = TourSteps(
    const DestinationTour(PushedDestination.dayRoute),
    isAdmin: widget.isAdmin,
  );

  @override
  void initState() {
    super.initState();
    _day = DateTime.now().dateOnly;
    _selectedEmployeeId = widget.employeeId;
  }

  // Report only the first data-to-error transition.
  void _onAppointmentsAsyncChange(
    AsyncValue<List<AppointmentRecord>>? previous,
    AsyncValue<List<AppointmentRecord>> next,
  ) {
    if (!isFirstAsyncError(previous, next)) return;
    ref
        .read(loggerProvider)
        .warn('APPT-LOAD day route stream error', next.error, next.stackTrace);
    if (!mounted) return;
    ref
        .read(noticeServiceProvider)
        .error(
          composeErrorNotice(
            context,
            intro: context.l10n.error_introLoadAppointments,
            error: next.error ?? Exception('unknown'),
          ),
        );
  }

  void _launchRoute(List<String> stops) {
    if (stops.length > maxRouteStops) {
      ref
          .read(noticeServiceProvider)
          .info(context.l10n.calendar_dayRouteTruncated);
    }
    final uri = buildGoogleMapsRouteUrl(stops);
    if (uri != null) launchGoogleMapsRoute(context, ref, uri);
  }

  @override
  Widget build(BuildContext context) {
    // The route argument is a SNAPSHOT; this is the same question asked of
    // Firestore. Resolved ONCE so the picker, the stream, the day filter and
    // `showActions` cannot disagree about who is looking.
    final isAdmin = widget.isAdmin && ref.watch(isActiveAdminProvider);

    // Use a week bucket so day switching reuses the same range listener.
    final range = AppointmentDateRange.forWeekBucketOf(_day);

    // Admins need the whole day for the employee picker.
    final provider = isAdmin
        ? appointmentsInRangeProvider(range)
        : myAppointmentsProvider((employeeId: widget.employeeId, range: range));
    final async = ref.watch(provider);
    ref.listen(provider, _onAppointmentsAsyncChange);

    final data = _prepareBuild(
      async.value ?? const <AppointmentRecord>[],
      ref.watch(employeeNameMapProvider),
      isAdmin: isAdmin,
    );

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: widget.isAdmin,
      stepKeys: _tour.keys,
      // Wait for real rows before starting the tour.
      ready: async is AsyncData<List<AppointmentRecord>>,
      child: _buildScaffold(async, data, isAdmin: isAdmin),
    );
  }

  Widget _buildScaffold(
    AsyncValue<List<AppointmentRecord>> async,
    DayRoute data, {
    required bool isAdmin,
  }) {
    return Scaffold(
      appBar: AppTopBar(
        title: context.l10n.calendar_dayRouteTitle,
        onBack: () => Navigator.pop(context),
        compact: context.isLandscape,
        actions: const [AppHeaderPair()],
      ),
      endDrawer: AppNavDrawer(
        isAdmin: widget.isAdmin,
        employeeId: widget.employeeId,
      ),
      bottomNavigationBar: _tour.stepIf(
        TourStepId.dayRouteNavigate,
        _routeButton(data.stops),
      ),
      // Pushed routes need their own primary scroll scope.
      body: PrimaryScrollScope(
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _tour.stepIf(TourStepId.dayRouteDaySwitcher, _daySwitcher()),
              // Missing steps are skipped by the tour host.
              if (isAdmin && data.assigneeEntries.isNotEmpty)
                _tour.stepIf(
                  TourStepId.dayRouteEmployee,
                  _employeePicker(data.assigneeEntries, data.employeeId),
                ),
              Expanded(
                child: _tour.stepIf(
                  TourStepId.dayRouteStops,
                  _timeline(
                    async,
                    data.jobs,
                    data.employeeId,
                    isAdmin: isAdmin,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  DayRoute? _preparedData;
  // Inputs used to derive _preparedData.
  List<AppointmentRecord>? _preparedSource;
  Map<String, String>? _preparedNameMap;
  DateTime? _preparedDay;
  String? _preparedEmployeeId;
  bool? _preparedIsAdmin;

  // Memoizes `buildDayRoute` on the inputs it was derived from. The identity
  // memo stays here rather than in `domain/`: it keys on `State` fields the
  // pure function does not have.
  DayRoute _prepareBuild(
    List<AppointmentRecord> source,
    Map<String, String> nameMap, {
    required bool isAdmin,
  }) {
    final cached = _preparedData;
    if (cached != null &&
        identical(source, _preparedSource) &&
        identical(nameMap, _preparedNameMap) &&
        _preparedDay == _day &&
        _preparedEmployeeId == _selectedEmployeeId &&
        _preparedIsAdmin == isAdmin) {
      return cached;
    }

    _preparedSource = source;
    _preparedNameMap = nameMap;
    _preparedDay = _day;
    _preparedEmployeeId = _selectedEmployeeId;
    _preparedIsAdmin = isAdmin;
    return _preparedData = buildDayRoute(
      source: source,
      nameMap: nameMap,
      day: _day,
      isAdmin: isAdmin,
      ownEmployeeId: widget.employeeId,
      selectedEmployeeId: _selectedEmployeeId,
    );
  }

  Future<void> _pickDay() async {
    final now = DateTime.now().dateOnly;
    final picked = await showAdaptiveDatePicker(
      context,
      initialDate: _day,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _day = picked.dateOnly);
    }
  }

  Widget _daySwitcher() {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // Shared day-header formatter.
    final label = DateUtilsHelper.formatDayHeader(_day);
    // Watch currentDayProvider so midnight updates the button.
    final isToday = _day == ref.watch(currentDayProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sp8,
        vertical: AppSpacing.sp8,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: l10n.calendar_dayRoutePreviousDay,
            onPressed: () => setState(() => _day = addCalendarDays(_day, -1)),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.r8),
              onTap: _pickDay,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sp8),
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (!isToday)
            IconButton(
              icon: const Icon(Icons.today_outlined),
              tooltip: l10n.calendar_today,
              onPressed: () =>
                  setState(() => _day = ref.read(currentDayProvider)),
            ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: l10n.calendar_dayRouteNextDay,
            onPressed: () => setState(() => _day = addCalendarDays(_day, 1)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEmployee(List<MapEntry<String, String>> assignees) async {
    final picked = await showAdaptiveActionSheet<String>(
      context,
      title: context.l10n.calendar_dayRouteEmployeeLabel,
      actions: [
        for (final e in assignees)
          AdaptiveSheetAction(value: e.key, label: e.value),
      ],
    );
    if (picked != null && mounted) {
      setState(() => _selectedEmployeeId = picked);
    }
  }

  Widget _employeePicker(
    List<MapEntry<String, String>> assignees,
    String value,
  ) {
    final theme = Theme.of(context);
    final currentName = assignees
        .firstWhere((e) => e.key == value, orElse: () => assignees.first)
        .value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        0,
        AppSpacing.sp16,
        AppSpacing.sp8,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.r12),
        onTap: () => _pickEmployee(assignees),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: context.l10n.calendar_dayRouteEmployeeLabel,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sp16,
              vertical: AppSpacing.sp12,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(currentName, overflow: TextOverflow.ellipsis),
              ),
              Icon(
                Icons.arrow_drop_down,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _routeButton(List<String> stops) {
    final launchCount = stops.length > maxRouteStops
        ? maxRouteStops
        : stops.length;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        0,
        AppSpacing.sp16,
        AppSpacing.sp16,
      ),
      child: FilledButton.icon(
        icon: const Icon(Icons.alt_route_rounded),
        label: Text(context.l10n.calendar_dayRouteOpenInMaps(launchCount)),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.r16),
          ),
        ),
        onPressed: stops.isEmpty ? null : () => _launchRoute(stops),
      ),
    );
  }

  Widget _timeline(
    AsyncValue<List<AppointmentRecord>> async,
    List<AppointmentDaySlice> jobs,
    String employeeId, {
    required bool isAdmin,
  }) {
    final l10n = context.l10n;
    if (async.isLoading && !async.hasValue) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.sp16),
        children: const [
          SkeletonAppointmentRow(),
          SizedBox(height: AppSpacing.sp8),
          SkeletonAppointmentRow(),
          SizedBox(height: AppSpacing.sp8),
          SkeletonAppointmentRow(),
        ],
      );
    }
    if (jobs.isEmpty) {
      return AppEmptyState(
        icon: Icons.alt_route_rounded,
        title: l10n.calendar_dayRouteEmptyTitle,
        body: l10n.calendar_dayRouteEmptyBody,
      );
    }

    // Number only open stops.
    final numbers = <int?>[];
    var open = 0;
    for (final j in jobs) {
      numbers.add(_isOpen(j.appointment.status) ? ++open : null);
    }
    final colorMap = ref.watch(employeeColorMapProvider);
    final nameMap = ref.watch(employeeNameMapProvider);
    final empColor =
        colorMap[employeeId] ?? Theme.of(context).colorScheme.primary;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp8,
        AppSpacing.sp16,
        AppSpacing.sp16,
      ),
      itemCount: jobs.length,
      itemBuilder: (context, i) => _StopTile(
        slice: jobs[i],
        number: numbers[i],
        employeeColor: empColor,
        crew: crewFor(
          jobs[i].appointment,
          colorMap: colorMap,
          nameMap: nameMap,
        ),
        showConnector: i < jobs.length - 1,
        navigateLabel: l10n.calendar_dayRouteNavigate,
        isAdmin: isAdmin,
      ),
    );
  }
}

class _StopTile extends ConsumerWidget {
  const _StopTile({
    required this.slice,
    required this.number,
    required this.employeeColor,
    required this.crew,
    required this.showConnector,
    required this.navigateLabel,
    required this.isAdmin,
  });

  /// This stop as it runs on the selected day.
  final AppointmentDaySlice slice;
  final int? number;

  /// The route employee color for the rail badge.
  final Color employeeColor;
  final List<AppointmentCrew> crew;
  final bool showConnector;
  final String navigateLabel;

  /// Gates the admin-only actions on the sheet this stop's card opens.
  final bool isAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusColors = Theme.of(context).statusColors;
    final isOpen = number != null;
    final job = slice.appointment;
    final hasAddress = job.address.trim().isNotEmpty;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StopRail(
            number: number,
            badgeColor: isOpen ? employeeColor : statusColors.successContainer,
            foreground: isOpen
                ? contrastingForegroundFor(employeeColor)
                : statusColors.onSuccessContainer,
            showConnector: showConnector,
          ),
          const SizedBox(width: AppSpacing.sp12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sp12),
              child: Opacity(
                opacity: isOpen ? 1 : 0.62,
                child: AppointmentCard(
                  appointment: job,
                  crew: crew,
                  slice: slice,
                  onTap: () => showEventDetails(
                    context,
                    job,
                    analyticsSource: AnalyticsSources.dayRoute,
                    showActions: isAdmin,
                  ),
                  footer: (isOpen && hasAddress)
                      ? _NavigatePill(
                          label: navigateLabel,
                          onTap: () => AddressMapLauncher.showMapChoices(
                            context,
                            ref,
                            address: job.address,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StopRail extends StatelessWidget {
  const _StopRail({
    required this.number,
    required this.badgeColor,
    required this.foreground,
    required this.showConnector,
  });

  final int? number;
  final Color badgeColor;
  final Color foreground;
  final bool showConnector;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
          child: number != null
              ? FittedBox(
                  child: Text(
                    '$number',
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                )
              : Icon(Icons.check, size: 16, color: foreground),
        ),
        if (showConnector)
          Expanded(child: Container(width: 2, color: scheme.outlineVariant)),
      ],
    );
  }
}

class _NavigatePill extends StatelessWidget {
  const _NavigatePill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.rFull),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.rFull),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sp12,
              vertical: AppSpacing.sp8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.directions_outlined,
                  size: 16,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(width: AppSpacing.sp4),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
