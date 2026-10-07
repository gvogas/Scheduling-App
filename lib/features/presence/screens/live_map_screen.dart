import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:scheduling/core/errors/error_cause.dart';
import 'package:scheduling/core/layout/breakpoints.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/feature_tour/domain/tour_steps.dart';
import 'package:scheduling/features/feature_tour/widgets/feature_tour_host.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/features/presence/application/live_map_providers.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/features/presence/domain/staff_marker_assembly.dart';
import 'package:scheduling/features/presence/widgets/live_map_overlays.dart';
import 'package:scheduling/features/presence/widgets/live_map_team_sheet.dart';
import 'package:scheduling/features/presence/widgets/staff_marker_icon.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/app_bars/app_header_pair.dart';
import 'package:scheduling/shared/widgets/app_bars/app_top_bar.dart';
import 'package:scheduling/shared/widgets/feedback/centered_error_text.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// Everything the map body needs, so a test can inject a stub via
/// [LiveMapScreen.mapBuilder] instead of the real platform-view [GoogleMap]
/// (which can't render in `flutter_test`).
class LiveMapConfig {
  const LiveMapConfig({
    required this.initialCameraPosition,
    required this.markers,
    required this.trafficEnabled,
    required this.mapType,
    required this.onMapCreated,
    required this.onTap,
  });

  final CameraPosition initialCameraPosition;
  final Set<Marker> markers;
  final bool trafficEnabled;
  final MapType mapType;
  final void Function(GoogleMapController controller) onMapCreated;
  final void Function(LatLng position) onTap;
}

/// Admin-only live staff-location map — a colored avatar marker per active
/// staff member, with a draggable team sheet underneath.
class LiveMapScreen extends ConsumerStatefulWidget {
  const LiveMapScreen({
    required this.isAdmin,
    required this.employeeId,
    super.key,
    @visibleForTesting this.mapBuilder,
  });

  final bool isAdmin;
  final String employeeId;

  /// Test seam mirroring `HubShell.screenBuilder`: replaces the real
  /// [GoogleMap] with a stub that records the [LiveMapConfig].
  final Widget Function(LiveMapConfig config)? mapBuilder;

  @override
  ConsumerState<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends ConsumerState<LiveMapScreen> {
  // Roughly Montréal — the business's home region — until the first fit.
  static const CameraPosition _initialCamera = CameraPosition(
    target: LatLng(45.5017, -73.5673),
    zoom: 9,
  );

  final StaffMarkerIconRenderer _renderer = StaffMarkerIconRenderer();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final ValueNotifier<double> _sheetExtent = ValueNotifier(kTeamSheetRestSize);
  ScrollController? _sheetScroll;

  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  LiveMapTeam _team = LiveMapTeam.empty;
  bool _hasTeam = false;
  DateTime _now = DateTime.now();
  String? _selectedDocId;
  bool _traffic = false;
  bool _satellite = false;
  bool _didInitialFit = false;

  // Guards the async marker assembly: only the newest run may commit its set.
  int _assembleToken = 0;
  String? _lastSignature;

  // True once the map body (which hosts the tour's targets) is rendered; gates
  // the tour so it isn't auto-marked-seen against a body with no targets yet.
  bool _mapTargetsRendered = false;

  late final _tour = TourSteps(
    const DestinationTour(HubTab.liveMap),
    isAdmin: widget.isAdmin,
  );

  @override
  void dispose() {
    _mapController?.dispose();
    _sheetController.dispose();
    _sheetExtent.dispose();
    super.dispose();
  }

  void _backToCalendar() => navigateToDestination(
    context,
    HubTab.calendar,
    isAdmin: widget.isAdmin,
    employeeId: widget.employeeId,
  );

  @override
  Widget build(BuildContext context) {
    // Mirrors the hub's TickerMode — false when the tab is hidden or an opaque
    // route covers the hub.
    final visible = TickerMode.valuesOf(context).enabled;

    // Paused (tab hidden) — render the kept-alive map with the last-known
    // team, and don't watch the data providers, so autoDispose can tear down
    // the presence listener and ticker.
    final Widget body;
    if (visible) {
      body = _liveBody(context);
    } else {
      _mapTargetsRendered = true;
      body = _mapStack(context, selectedPoint: null, paused: true);
    }

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: widget.isAdmin,
      ready: _mapTargetsRendered,
      stepKeys: _tour.keys,
      child: Scaffold(
        appBar: AppTopBar(
          title: context.l10n.liveMap_title,
          compact: context.isLandscape,
          onBack: _backToCalendar,
          actions: const [AppHeaderPair()],
        ),
        endDrawer: AppNavDrawer(
          isAdmin: widget.isAdmin,
          employeeId: widget.employeeId,
        ),
        body: body,
      ),
    );
  }

  Widget _liveBody(BuildContext context) {
    final teamAsync = ref.watch(liveMapTeamProvider);
    ref.listen<AsyncValue<LiveMapTeam>>(liveMapTeamProvider, _onTeamChanged);
    _now = ref.watch(liveMapClockProvider)();

    if (teamAsync.value case final team?) {
      _team = team;
      _hasTeam = true;
    }
    final points = _team.onMap;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final selected = _effectiveSelected(points);

    _scheduleMarkerAssembly(context, points, selected, dpr);
    _maybeFitCamera(points);

    if (teamAsync.hasError && !_hasTeam) {
      _mapTargetsRendered = false;
      return CenteredErrorText(
        message: context.l10n.error_introLoadLiveMap,
        onRetry: _retryTeam,
      );
    }
    if (teamAsync.isLoading && !_hasTeam) {
      _mapTargetsRendered = false;
      return const LiveMapLoadingBody();
    }

    _mapTargetsRendered = true;
    final selectedPoint = selected == null
        ? null
        : points.where((p) => p.userDocId == selected).firstOrNull;
    return _mapStack(context, selectedPoint: selectedPoint, paused: false);
  }

  void _onTeamChanged(
    AsyncValue<LiveMapTeam>? previous,
    AsyncValue<LiveMapTeam> next,
  ) {
    if (!isFirstAsyncError(previous, next)) return;
    ref
        .read(loggerProvider)
        .warn('LIVEMAP-LOAD live map failed', next.error, next.stackTrace);
    ref
        .read(noticeServiceProvider)
        .error(
          composeErrorNotice(
            context,
            intro: context.l10n.error_introLoadLiveMap,
            error: next.error!,
          ),
        );
  }

  /// The stored selection, or null once that person has left the map.
  String? _effectiveSelected(List<StaffMapPoint> points) {
    final id = _selectedDocId;
    if (id == null) return null;
    if (points.any((p) => p.userDocId == id)) return id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_selectedDocId == id && !_team.onMap.any((p) => p.userDocId == id)) {
        setState(() => _selectedDocId = null);
      }
    });
    return null;
  }

  /// Re-subscribes the errored sources; invalidating the derived team alone re-reads their error.
  void _retryTeam() {
    ref.invalidate(allPresenceStreamProvider);
    if (ref.read(allUsersStreamProvider).hasError) {
      ref.invalidate(allUsersStreamProvider);
    }
  }

  void _scheduleMarkerAssembly(
    BuildContext context,
    List<StaffMapPoint> points,
    String? selected,
    double dpr,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final params = (
      points: points,
      selectedDocId: selected,
      devicePixelRatio: dpr,
      ringColor: scheme.surface,
      haloColor: scheme.primary,
    );
    final signature = staffMarkerSignature(params);
    if (signature == _lastSignature) return;

    final token = ++_assembleToken;
    unawaited(_assembleMarkers(params, signature, token));
  }

  Future<void> _assembleMarkers(
    StaffMarkerParams params,
    String signature,
    int token,
  ) async {
    final logger = ref.read(loggerProvider);
    try {
      final markers = await assembleStaffMarkers(
        params: params,
        renderer: _renderer,
        onMarkerTap: _selectMarker,
      );
      if (!mounted || token != _assembleToken) return;
      // Commit the signature only now, so a failed render leaves the previous
      // markers + signature in place and the next data/theme change retries.
      _lastSignature = signature;
      setState(() => _markers = markers);
    } catch (e, st) {
      logger.warn('LIVEMAP-MARKERS assemble failed', e, st);
    }
  }

  void _selectMarker(String docId) {
    final point = _team.onMap.where((p) => p.userDocId == docId).firstOrNull;
    if (point != null) _focusOn(point);
  }

  /// A pin tap and a row tap: focus the person and ease the camera to them.
  void _focusOn(StaffMapPoint point) {
    if (_selectedDocId != point.userDocId) {
      setState(() => _selectedDocId = point.userDocId);
    }
    _animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(point.lat, point.lng), 15),
    );
    final scroll = _sheetScroll;
    if (scroll != null && scroll.hasClients) scroll.jumpTo(0);
    if (_sheetController.isAttached &&
        _sheetController.size < kTeamSheetRestSize) {
      _moveSheetToRest();
    }
  }

  void _clearSelection() {
    if (_selectedDocId == null) return;
    setState(() => _selectedDocId = null);
  }

  void _closeSelection() {
    _clearSelection();
    if (_sheetController.isAttached) _moveSheetToRest();
  }

  void _moveSheetToRest() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _sheetController.jumpTo(kTeamSheetRestSize);
      return;
    }
    _sheetController.animateTo(
      kTeamSheetRestSize,
      duration: AppDuration.normal,
      curve: Curves.easeOut,
    );
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    _maybeFitCamera(_team.onMap);
  }

  void _maybeFitCamera(List<StaffMapPoint> points) {
    if (_didInitialFit || _mapController == null || points.isEmpty) return;
    _didInitialFit = true;
    _applyFit(points);
  }

  void _applyFit(List<StaffMapPoint> points) {
    if (_mapController == null || points.isEmpty) return;
    if (points.length == 1) {
      _animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(points.first.lat, points.first.lng),
          14,
        ),
      );
      return;
    }
    _animateCamera(CameraUpdate.newLatLngBounds(_boundsOf(points), 48));
  }

  /// The map controller can outlive its platform view — a shell swap recreates
  /// the GoogleMap subtree — so `animateCamera` can throw "used after disposed"
  /// on a stale controller.
  void _animateCamera(CameraUpdate update) {
    final controller = _mapController;
    if (controller == null) return;
    try {
      controller.animateCamera(update);
      // google_maps_flutter throws a bare StateError from a disposed
      // controller; there is no public API to test for that first, so the catch
      // is intentional.
      // ignore: avoid_catching_errors
    } on StateError {
      _mapController = null;
      _didInitialFit = false;
    }
  }

  LatLngBounds _boundsOf(List<StaffMapPoint> points) {
    var minLat = points.first.lat;
    var maxLat = points.first.lat;
    var minLng = points.first.lng;
    var maxLng = points.first.lng;
    for (final p in points) {
      minLat = min(minLat, p.lat);
      maxLat = max(maxLat, p.lat);
      minLng = min(minLng, p.lng);
      maxLng = max(maxLng, p.lng);
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  Widget _mapStack(
    BuildContext context, {
    required StaffMapPoint? selectedPoint,
    required bool paused,
  }) {
    final builder = widget.mapBuilder ?? _defaultMap;
    final config = LiveMapConfig(
      initialCameraPosition: _initialCamera,
      markers: _markers,
      trafficEnabled: _traffic,
      mapType: _satellite ? MapType.hybrid : MapType.normal,
      onMapCreated: _onMapCreated,
      onTap: (_) => _clearSelection(),
    );
    final recenter = _tour.stepIf(
      TourStepId.liveMapRecenter,
      MapGhostIcon(
        icon: Icons.my_location,
        tooltip: context.l10n.liveMap_recenter,
        onTap: () => _applyFit(_team.onMap),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Positioned.fill(child: builder(config)),
          Positioned(
            top: AppSpacing.sp12,
            right: AppSpacing.sp12,
            child: SafeArea(
              child: MapToggles(
                traffic: _traffic,
                satellite: _satellite,
                onTrafficToggle: () => setState(() => _traffic = !_traffic),
                onSatelliteToggle: () =>
                    setState(() => _satellite = !_satellite),
              ),
            ),
          ),
          if (!paused && _team.onMap.isEmpty)
            const Positioned(
              left: AppSpacing.sp24,
              // Clear of the toggle column on the right.
              right: AppSpacing.sp24 + kGhostTapTarget,
              top: AppSpacing.sp16,
              child: EmptyMapCard(),
            ),
          // Keyed: the conditional card above must not re-slot the sheet.
          Positioned.fill(
            key: const ValueKey('liveMapTeamSheet'),
            child: NotificationListener<DraggableScrollableNotification>(
              onNotification: (notification) {
                _sheetExtent.value = notification.extent;
                return false;
              },
              child: DraggableScrollableSheet(
                controller: _sheetController,
                initialChildSize: kTeamSheetRestSize,
                minChildSize: kTeamSheetMinSize,
                maxChildSize: kTeamSheetMaxSize,
                snap: true,
                snapSizes: const [kTeamSheetRestSize],
                builder: (context, scrollController) {
                  _sheetScroll = scrollController;
                  return LiveMapTeamSheet(
                    team: _team,
                    now: _now,
                    selfDocId: widget.employeeId,
                    selected: selectedPoint,
                    scrollController: scrollController,
                    onSelect: _focusOn,
                    onCloseSelection: _closeSelection,
                    tourWrap: (id, child) => _tour.stepIf(
                      id,
                      child,
                      targetBorderRadius: BorderRadius.circular(AppRadius.r12),
                    ),
                  );
                },
              ),
            ),
          ),
          ValueListenableBuilder<double>(
            valueListenable: _sheetExtent,
            builder: (context, extent, child) => Positioned(
              right: AppSpacing.sp12,
              bottom: extent * constraints.maxHeight + AppSpacing.sp4,
              child: child!,
            ),
            child: recenter,
          ),
        ],
      ),
    );
  }

  Widget _defaultMap(LiveMapConfig config) => GoogleMap(
    initialCameraPosition: config.initialCameraPosition,
    markers: config.markers,
    trafficEnabled: config.trafficEnabled,
    mapType: config.mapType,
    myLocationButtonEnabled: false,
    onMapCreated: config.onMapCreated,
    onTap: config.onTap,
    // The map is a platform view nested inside a Stack/shell; without an eager
    // recognizer the Flutter gesture arena swallows pan/zoom drags (taps still
    // reach the map), so the map appears frozen on iOS.
    gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
      Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
    },
  );
}
