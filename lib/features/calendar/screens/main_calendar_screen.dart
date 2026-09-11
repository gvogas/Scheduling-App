import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/app/photo_upload_failure_listener.dart';
import 'package:scheduling/core/app/role_upgrade_listener.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/layout/primary_scroll_scope.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/utils/current_day_provider.dart';
import 'package:scheduling/core/utils/date_utils_helper.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/calendar_crew_filter_provider.dart';
import 'package:scheduling/features/calendar/domain/appointment_crew.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/calendar/domain/collapse_state.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/month_grid.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/calendar/widgets/fields/month_year_picker.dart';
import 'package:scheduling/features/calendar/widgets/views/agenda_sliver_list.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_header_block.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_month_grid.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_month_pager.dart';
import 'package:scheduling/features/calendar/widgets/views/calendar_week_strip.dart';
import 'package:scheduling/features/calendar/widgets/views/collapse_handle.dart';
import 'package:scheduling/features/calendar/widgets/views/crew_filter_button.dart';
import 'package:scheduling/features/calendar/widgets/views/event_list.dart';
import 'package:scheduling/features/calendar/widgets/views/today_pill.dart';
import 'package:scheduling/features/calendar/widgets/views/week_agenda_sliver_list.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Most of the portrait pane the month grid may take before it starts clipping.
const double _kMaxGridShare = 0.7;

/// What the agenda below the grid lists: the selected day, or its whole week.
enum _AgendaMode { day, week }

class MainCalendar extends ConsumerStatefulWidget {
  const MainCalendar({
    required this.isAdmin,
    required this.employeeId,
    super.key,
  });

  final bool isAdmin;
  final String employeeId;

  @override
  ConsumerState<MainCalendar> createState() => _MainCalendarState();
}

class _MainCalendarState extends ConsumerState<MainCalendar> {
  final _agendaController = ScrollController();
  final _collapse = CalendarCollapse();

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  late AppointmentDateRange _appointmentRange;
  _AgendaMode _agendaMode = _AgendaMode.day;

  /// Captured so dispose can clear without touching `ref`.
  OpenCalendarRange? _openRange;
  late DateFormat _monthLabelFormat;
  late DateFormat _monthShortLabelFormat;
  late DateFormat _yearLabelFormat;
  late DateFormat _dayMonthLabelFormat;
  late DateFormat _dayLabelFormat;
  String _lastLocale = '';

  late final _tour = TourSteps(
    const DestinationTour(HubTab.calendar),
    isAdmin: widget.isAdmin,
  );

  /// Uses the "Split" layout (month grid | day agenda) when the nav rail shows.
  bool get _splitCalendar => context.isSplitLayout;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    _appointmentRange = _rangeFor(_focusedDay, _focusedDay);
    if (widget.isAdmin) {
      _openRange = ref.read(openCalendarRangeProvider.notifier);
    }
    // Publish after build so Riverpod accepts the provider write.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishRange();
    });
  }

  @override
  void dispose() {
    _agendaController.dispose();
    // Clear only the range this screen still owns.
    _openRange?.clearIfHolding(this);
    super.dispose();
  }

  /// Publishes the open calendar range for admin child surfaces.
  void _publishRange() => _openRange?.publish(this, _appointmentRange);

  void _onCollapseDrag(double dy) {
    if (_collapse.onDragDelta(dy)) setState(() {});
  }

  void _toggleCollapse() {
    _collapse.toggle();
    setState(() {});
  }

  // Show Today when either the selected day or focused month differs.
  bool _showTodayButton(DateTime today) =>
      !isSameDate(_selectedDay ?? _focusedDay, today) ||
      !isInMonth(today, _focusedDay);

  /// One event per date move, with WHICH gesture moved it.
  ///
  /// `_onDaySelected` is the single funnel every path ends in, so the direction
  /// is passed down rather than logged at each entry point — logging at both
  /// would count a week page or a Today tap twice.
  void _logDateChange(String direction) {
    ref
        .read(analyticsServiceProvider)
        .logCalendarDateChanged(
          viewMode: _agendaMode.name,
          direction: direction,
        );
  }

  void _goToToday(DateTime today) {
    _logDateChange(AnalyticsDirections.today);
    setState(() {
      _focusedDay = today;
      _selectedDay = today;
      _appointmentRange = _rangeFor(today, today);
    });
    _publishRange();
  }

  /// The fetch window for a focus/selection pair.
  AppointmentDateRange _rangeFor(DateTime focusedDay, DateTime selectedDay) {
    final range = AppointmentDateRange.forCalendar(
      focusedDay: focusedDay,
      selectedDay: selectedDay,
    );
    if (_agendaMode != _AgendaMode.week) return range;
    final weekStart = _weekOf(selectedDay).first;
    return range.union(
      AppointmentDateRange(
        start: weekStart,
        end: addCalendarDays(weekStart, 7),
      ),
    );
  }

  /// The seven days around [day], in the locale's week order.
  List<DateTime> _weekOf(DateTime day) =>
      weekOf(day, weekStart: CalendarMonthGrid.weekStartOf(context));

  void _setAgendaMode(_AgendaMode mode) {
    if (mode == _agendaMode) return;
    ref
        .read(analyticsServiceProvider)
        .logCalendarViewChanged(viewMode: mode.name);
    final day = _selectedDay ?? _focusedDay;
    setState(() {
      _agendaMode = mode;
      final newRange = _rangeFor(_focusedDay, day);
      if (newRange != _appointmentRange) _appointmentRange = newRange;
    });
    _publishRange();
  }

  /// A tap on a week bar: that day, in day mode.
  void _onWeekDaySelected(DateTime day) {
    setState(() => _agendaMode = _AgendaMode.day);
    _onDaySelected(day, direction: AnalyticsDirections.weekStrip);
  }

  /// Moves focus and selection to the given month/day.
  ///
  /// The direction is a parameter because the two callers are different
  /// gestures — the date-picker dialog and a month swipe — and reporting both
  /// as `picked` made them indistinguishable in the console.
  void _setFocusedDay(
    DateTime day, {
    String direction = AnalyticsDirections.picked,
  }) {
    _logDateChange(direction);
    final newRange = _rangeFor(day, day);
    setState(() {
      _focusedDay = day;
      _selectedDay = day;
      if (newRange != _appointmentRange) _appointmentRange = newRange;
    });
    _publishRange();
  }

  /// Pages the collapsed week strip by one week.
  void _pageWeek(int direction) {
    final from = _selectedDay ?? _focusedDay;
    final weekStart = CalendarMonthGrid.weekStartOf(context);
    final target = DateTime(from.year, from.month, from.day + 7 * direction);
    _onDaySelected(
      weekOf(target, weekStart: weekStart).first,
      direction: direction > 0
          ? AnalyticsDirections.next
          : AnalyticsDirections.previous,
    );
  }

  Map<DateTime, List<AppointmentDaySlice>>? _dayIndex;
  // Tracks the source list used for _dayIndex.
  List<AppointmentRecord>? _indexedAppointments;

  // Memo for the crew filter, keyed on source identity and the filtered id.
  List<AppointmentRecord>? _filterSource;
  String? _filterId;
  List<AppointmentRecord> _filtered = const [];

  /// [source] narrowed to [employeeId]'s jobs, applied BEFORE the day index so
  /// the dots, the counts, the agenda and the job label all agree.
  List<AppointmentRecord> _applyCrewFilter(
    List<AppointmentRecord> source,
    String? employeeId,
  ) {
    if (employeeId == null) return source;
    if (identical(source, _filterSource) && employeeId == _filterId) {
      return _filtered;
    }
    _filterSource = source;
    _filterId = employeeId;
    return _filtered = [
      for (final a in source)
        if (a.employeeIds.contains(employeeId)) a,
    ];
  }

  /// Rebuilds [_dayIndex] only for a new source list.
  void _refreshDayIndex(List<AppointmentRecord> source) {
    if (identical(source, _indexedAppointments)) return;
    _indexedAppointments = source;
    _dayIndex = expandToDays(
      source,
      _appointmentRange,
      onSpanClamped: (appointment, actualDays) => ref
          .read(loggerProvider)
          .warn(
            'APPT-RANGE appointment ${appointment.id} spans $actualDays days, '
            'past the $maxAppointmentSpanDays-day cap - showing the first '
            '$maxAppointmentSpanDays',
          ),
    );
  }

  List<AppointmentDaySlice> _getEventsForDay(DateTime day) =>
      _dayIndex?[day.dateOnly] ?? const <AppointmentDaySlice>[];

  /// Records running on [day], used for crew dots.
  Iterable<AppointmentRecord> _appointmentsOn(DateTime day) =>
      _getEventsForDay(day).map((slice) => slice.appointment);

  void _onDaySelected(DateTime selectedDay, {String direction = 'day'}) {
    // The early return is what keeps a re-tap of the selected day from
    // reporting a move that did not happen.
    if (isSameDate(_selectedDay ?? _focusedDay, selectedDay)) return;
    _logDateChange(direction);
    final newRange = _rangeFor(selectedDay, selectedDay);
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = selectedDay;
      if (newRange != _appointmentRange) _appointmentRange = newRange;
    });
    _publishRange();
  }

  // Report only the first data-to-error transition.
  void _onAppointmentsAsyncChange(
    AsyncValue<List<AppointmentRecord>>? previous,
    AsyncValue<List<AppointmentRecord>> next,
  ) {
    if (!isFirstAsyncError(previous, next)) return;
    ref
        .read(loggerProvider)
        .warn(
          'APPT-LOAD appointments stream error',
          next.error,
          next.stackTrace,
        );
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

  Future<void> _pickMonth() async {
    final picked = await MonthYearPicker.show(context, _focusedDay);
    if (picked != null && mounted) _setFocusedDay(picked);
  }

  /// Appointments stream for the current user scope.
  StreamProvider<List<AppointmentRecord>> get _appointmentsProvider =>
      widget.isAdmin
      ? appointmentsInRangeProvider(_appointmentRange)
      : myAppointmentsProvider((
          employeeId: widget.employeeId,
          range: _appointmentRange,
        ));

  /// Prepares the provider values build renders.
  ({
    String userName,
    Map<String, Color> colorMap,
    Map<String, String> nameMap,
    bool isLoading,
    String monthLabel,
    String monthLabelShort,
    String yearLabel,
    String dayTitle,
    String jobLabel,
    DateTime today,
    List<DateTime> weekDays,
  })
  _prepareBuild(BuildContext context) {
    final appointmentsAsync = ref.watch(_appointmentsProvider);
    final userName = ref.watch(currentUserNameProvider);
    final colorMap = ref.watch(employeeColorMapProvider);
    final nameMap = ref.watch(employeeNameMapProvider);
    // Watch currentDayProvider so midnight updates the UI.
    final today = ref.watch(currentDayProvider);
    // A technician already streams only their own jobs; only the admin filters.
    final crewFilter = widget.isAdmin
        ? ref.watch(calendarCrewFilterProvider)
        : null;

    // Error logging is owned by the onAsyncChange listener in build.
    final visibleAppointments = _applyCrewFilter(
      appointmentsAsync.value ?? const <AppointmentRecord>[],
      crewFilter,
    );

    _refreshDayIndex(visibleAppointments);

    final selectedDay = _selectedDay ?? _focusedDay;
    final weekDays = _weekOf(selectedDay);
    final agendaEvents = _agendaMode == _AgendaMode.week
        ? [for (final day in weekDays) ..._getEventsForDay(day)]
        : _getEventsForDay(selectedDay);

    final locale = Localizations.localeOf(context).toString();
    if (locale != _lastLocale) {
      _monthLabelFormat = DateFormat.MMMM(locale);
      _monthShortLabelFormat = DateFormat.MMM(locale);
      _yearLabelFormat = DateFormat.y(locale);
      _dayMonthLabelFormat = DateFormat.MMMd(locale);
      _dayLabelFormat = DateFormat.d(locale);
      _lastLocale = locale;
    }

    return (
      userName: userName,
      colorMap: colorMap,
      nameMap: nameMap,
      isLoading: appointmentsAsync.isLoading,
      // Header decides which month label fits.
      monthLabel: _monthLabelFormat.format(_focusedDay),
      monthLabelShort: _monthShortLabelFormat.format(_focusedDay),
      yearLabel: _yearLabelFormat.format(_focusedDay),
      dayTitle: _agendaMode == _AgendaMode.week
          ? _weekLabel(weekDays)
          : DateUtilsHelper.formatDayHeader(selectedDay),
      jobLabel: _jobLabel(context, agendaEvents),
      today: today,
      weekDays: weekDays,
    );
  }

  /// "Sep 1 – 7", or "Aug 31 – Sep 6" across a month boundary.
  String _weekLabel(List<DateTime> days) {
    final first = days.first;
    final last = days.last;
    final end = first.month == last.month
        ? _dayLabelFormat.format(last)
        : _dayMonthLabelFormat.format(last);
    return '${_dayMonthLabelFormat.format(first)} – $end';
  }

  /// Agenda count label for work and done totals.
  static String _jobLabel(
    BuildContext context,
    List<AppointmentDaySlice> events,
  ) {
    final l10n = context.l10n;
    final jobs = events
        .where((slice) => countsAsWork(slice.appointment))
        .toList();
    final total = l10n.calendar_jobsCount(jobs.length);
    final done = jobs.where((slice) => slice.appointment.isClosed).length;
    return done == 0 ? total : '$total · ${l10n.calendar_jobsDoneCount(done)}';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(_appointmentsProvider, _onAppointmentsAsyncChange);

    final data = _prepareBuild(context);

    // Session listeners are hosted at the calendar shell.
    return RoleUpgradeListener(
      employeeId: widget.employeeId,
      isAdmin: widget.isAdmin,
      child: PhotoUploadFailureListener(
        showActions: widget.isAdmin,
        child: FeatureTourHost(
          scope: _tour.scope,
          isAdmin: widget.isAdmin,
          ready: !data.isLoading,
          stepKeys: _tour.keys,
          child: Scaffold(
            floatingActionButton: _addAppointmentFab(context),
            endDrawer: AppNavDrawer(
              isAdmin: widget.isAdmin,
              employeeId: widget.employeeId,
              userName: data.userName,
            ),
            body: Column(
              children: [
                CalendarHeaderBlock(
                  monthLabel: data.monthLabel,
                  monthLabelShort: data.monthLabelShort,
                  yearLabel: data.yearLabel,
                  onPickMonth: _pickMonth,
                  crewFilterButton: widget.isAdmin
                      ? _tour.stepIf(
                          TourStepId.calendarCrewFilter,
                          const CrewFilterButton(),
                        )
                      : null,
                  routeButton: _dayRouteButton(context),
                  weekStrip: _weekStrip(data.today, data.colorMap),
                ),
                Expanded(
                  // The header block reserves the status bar itself.
                  child: SafeArea(
                    top: false,
                    child: Stack(
                      children: [
                        _content(
                          isLoading: data.isLoading,
                          colorMap: data.colorMap,
                          nameMap: data.nameMap,
                          today: data.today,
                          dayTitle: data.dayTitle,
                          jobLabel: data.jobLabel,
                          weekDays: data.weekDays,
                        ),
                        Positioned(
                          bottom: AppSpacing.sp16,
                          left: AppSpacing.sp16,
                          child: TodayPill(
                            visible: _showTodayButton(data.today),
                            onPressed: () => _goToToday(data.today),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Collapsed week strip, hidden in split layout.
  Widget? _weekStrip(DateTime today, Map<String, Color> colorMap) {
    if (_splitCalendar || !_collapse.isCollapsed) return null;
    final selectedDay = _selectedDay ?? _focusedDay;
    // Horizontal swipes page weeks.
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity == 0) return;
        _pageWeek(velocity < 0 ? 1 : -1);
      },
      child: CalendarWeekStrip(
        weekDays: weekOf(
          selectedDay,
          weekStart: CalendarMonthGrid.weekStartOf(context),
        ),
        selectedDay: selectedDay,
        today: today,
        onDaySelected: _onDaySelected,
        dotColorsFor: (day) =>
            dayJobDotColors(_appointmentsOn(day), colorMap, max: 1),
      ),
    );
  }

  /// Day-route control owned by this screen's tour.
  Widget _dayRouteButton(BuildContext context) {
    final theme = Theme.of(context);
    return _tour.step(
      TourStepId.calendarDayRoute,
      targetBorderRadius: BorderRadius.circular(AppRadius.rIcon),
      child: Tooltip(
        message: context.l10n.calendar_dayRouteTitle,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Material(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.rIcon),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.dayRoute,
                  arguments: DayRouteArgs(
                    isAdmin: widget.isAdmin,
                    employeeId: widget.employeeId,
                  ),
                ),
                highlightColor: theme.palette.blueTintPressed,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(
                    Icons.alt_route_rounded,
                    size: 19,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _addAppointmentFab(BuildContext context) {
    if (!widget.isAdmin) return null;
    return _tour.step(
      TourStepId.calendarAddAppointment,
      targetBorderRadius: BorderRadius.circular(AppRadius.rFab),
      child: SizedBox(
        width: 58,
        height: 58,
        child: FloatingActionButton(
          heroTag: 'addFab',
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.rFab),
          ),
          tooltip: context.l10n.calendar_newAppointment,
          onPressed: () async {
            await showAddEventPopup(
              context,
              initialDate: _selectedDay ?? _focusedDay,
            );
          },
          child: const Icon(Icons.add, size: 26),
        ),
      ),
    );
  }

  Widget _buildCalendar(Map<String, Color> colorMap, DateTime today) =>
      _tour.step(
        TourStepId.calendarGrid,
        child: CalendarMonthPager(
          month: _focusedDay,
          selectedDay: _selectedDay ?? _focusedDay,
          today: today,
          onDaySelected: _onDaySelected,
          onMonthChanged: (day) =>
              _setFocusedDay(day, direction: AnalyticsDirections.month),
          dotColorsFor: (day) =>
              dayJobDotColors(_appointmentsOn(day), colorMap),
          // Semantics count the same jobs as the dots.
          countFor: (day) => dottedJobsOn(_appointmentsOn(day)).length,
        ),
      );

  Widget _content({
    required bool isLoading,
    required Map<String, Color> colorMap,
    required Map<String, String> nameMap,
    required DateTime today,
    required String dayTitle,
    required String jobLabel,
    required List<DateTime> weekDays,
  }) {
    final agendaDay = _selectedDay ?? _focusedDay;
    final events = _getEventsForDay(agendaDay);
    // The header is the stable tour target; the banner sits above it so the
    // narrowed schedule is never mistaken for a quiet day.
    final agendaHeader = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.isAdmin) const CrewFilterBanner(),
        _tour.step(
          TourStepId.calendarDayList,
          child: AgendaHeader(
            dayTitle: dayTitle,
            jobLabel: jobLabel,
            trailing: _tour.stepIf(
              TourStepId.calendarWeekToggle,
              _agendaModeToggle(context),
            ),
          ),
        ),
      ],
    );
    // The FAB and the Today pill float over the list, so the last job needs
    // somewhere to scroll clear of them.
    final agenda = _agendaMode == _AgendaMode.week
        ? weekAgendaSlivers(
            context,
            days: weekDays,
            eventsFor: _getEventsForDay,
            today: today,
            onDaySelected: _onWeekDaySelected,
            nameMap: nameMap,
            colorMap: colorMap,
            isAdmin: widget.isAdmin,
            isLoading: isLoading,
            bottomClearance: kAgendaFloatingControlsClearance,
          )
        : [
            AgendaSliverList(
              events: events,
              nameMap: nameMap,
              colorMap: colorMap,
              isLoading: isLoading,
              isAdmin: widget.isAdmin,
              day: agendaDay,
              bottomClearance: kAgendaFloatingControlsClearance,
            ),
          ];

    if (_splitCalendar) {
      return _splitContent(
        agenda: agenda,
        agendaHeader: agendaHeader,
        colorMap: colorMap,
        today: today,
      );
    }

    return _portraitContent(
      agenda: agenda,
      agendaHeader: agendaHeader,
      colorMap: colorMap,
      today: today,
    );
  }

  /// Icon-only day/week toggle.
  Widget _agendaModeToggle(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: 32,
      child: SegmentedButton<_AgendaMode>(
        segments: [
          ButtonSegment(
            value: _AgendaMode.day,
            icon: const Icon(Icons.view_day_outlined, size: 18),
            tooltip: l10n.calendar_agendaDayView,
          ),
          ButtonSegment(
            value: _AgendaMode.week,
            icon: const Icon(Icons.view_week_outlined, size: 18),
            tooltip: l10n.calendar_agendaWeekView,
          ),
        ],
        selected: {_agendaMode},
        onSelectionChanged: (modes) => _setAgendaMode(modes.single),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: AppSpacing.sp8),
          ),
        ),
      ),
    );
  }

  /// Landscape phones and tablets: month grid | agenda, side by side.
  Widget _splitContent({
    required List<Widget> agenda,
    required Widget agendaHeader,
    required Map<String, Color> colorMap,
    required DateTime today,
  }) {
    // Give each split pane its own primary scroll controller.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 11,
          // Let the grid scroll instead of clipping at large text sizes.
          child: PrimaryScrollScope(
            child: SingleChildScrollView(
              child: _buildCalendar(colorMap, today),
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        // EventList already returns an Expanded, so wrap it in a Flex.
        Expanded(
          flex: 9,
          child: PrimaryScrollScope(
            child: Column(
              children: [
                agendaHeader,
                EventList.slivers(slivers: agenda),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Portrait layout with fixed grid and scrolling agenda.
  Widget _portraitContent({
    required List<Widget> agenda,
    required Widget agendaHeader,
    required Map<String, Color> colorMap,
    required DateTime today,
  }) {
    // The agenda scrolls independently from the fixed grid, and the grid is
    // measured against the pane rather than handed a flex share of it.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The grid takes the height its month needs, capped at
          // [_kMaxGridShare] of the pane.
          if (!_collapse.isCollapsed)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * _kMaxGridShare,
              ),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: _buildCalendar(colorMap, today),
              ),
            ),
          // The section divider is also the collapse control.
          _tour.step(
            TourStepId.calendarCollapse,
            child: CollapseHandle(
              isCollapsed: _collapse.isCollapsed,
              onDrag: _onCollapseDrag,
              onDragEnd: _collapse.endDrag,
              onToggle: _toggleCollapse,
            ),
          ),
          agendaHeader,
          Expanded(
            child: CustomScrollView(
              controller: _agendaController,
              // Use a private controller because the grid is another
              // scrollable.
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: agenda,
            ),
          ),
        ],
      ),
    );
  }
}
