import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/feature_tour/application/tour_seen_store.dart';
import 'package:scheduling/features/feature_tour/domain/tour_definitions.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/features/presence/data/location_share_ask_store.dart';
import 'package:scheduling/features/presence/domain/location_share_ask_policy.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Pushes the "Be on the team map" page once the calendar and its tour allow.
class LocationShareAskGate extends ConsumerStatefulWidget {
  const LocationShareAskGate({
    required this.isAdmin,
    required this.child,
    super.key,
  });

  final bool isAdmin;
  final Widget child;

  @override
  ConsumerState<LocationShareAskGate> createState() =>
      _LocationShareAskGateState();
}

class _LocationShareAskGateState extends ConsumerState<LocationShareAskGate> {
  bool _checking = false;

  /// The uid whose answer is already known this session.
  String? _settledUid;

  @override
  Widget build(BuildContext context) {
    final visible = HubShellScope.currentOf(context) == HubTab.calendar;
    final me = ref.watch(myEmployeeRecordProvider);
    final seen = ref.watch(tourSeenProvider);
    if (visible &&
        !_checking &&
        me != null &&
        me.uid != _settledUid &&
        shouldAskToShareLocation(
          me: me,
          alreadyAsked: false,
          calendarTourPending: _calendarTourNotRun(seen),
        )) {
      _checking = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_maybeAsk(me)),
      );
    }
    return widget.child;
  }

  /// ANY step, not all: the collapse step never renders in split layout.
  bool _calendarTourNotRun(Set<TourStepId> seen) => !tourStepsFor(
    const DestinationTour(HubTab.calendar),
    isAdmin: widget.isAdmin,
  ).any(seen.contains);

  Future<void> _maybeAsk(EmployeeRecord me) async {
    final logger = ref.read(loggerProvider);
    final store = ref.read(locationShareAskStoreProvider);
    final tour = ref.read(tourSeenProvider.notifier);
    try {
      await tour.ready;
      if (!mounted || _calendarTourNotRun(tour.seen)) return;
      if (await store.hasAsked(me.uid)) {
        _settledUid = me.uid;
        return;
      }
      if (!mounted || HubShellScope.readCurrentOf(context) != HubTab.calendar) {
        return;
      }
      // Marked before the push, so a page killed mid-decision is still final.
      await store.markAsked(me.uid);
      _settledUid = me.uid;
      if (!mounted) return;
      Navigator.of(context).pushNamed(AppRoutes.shareLocationAsk);
    } catch (e, st) {
      logger.warn('PRESENCE location ask failed', e, st);
      _settledUid = me.uid;
    } finally {
      _checking = false;
    }
  }
}
