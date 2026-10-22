import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/employees/application/employees_providers.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/notifications/widgets/notification_ask_gate.dart';
import 'package:scheduling/features/presence/data/location_share_ask_store.dart';
import 'package:scheduling/features/presence/domain/location_share_ask_policy.dart';
import 'package:scheduling/features/settings/application/app_info_provider.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Hosts both ask pages over the calendar, ahead of its tour: the one-time
/// notifications page first, then "Be on the team map" once per app build.
class LocationShareAskGate extends StatelessWidget {
  const LocationShareAskGate({required this.builder, super.key});

  /// Builds the calendar; `holdsTour` stays true until both pages are decided.
  final Widget Function(BuildContext context, {required bool holdsTour})
  builder;

  @override
  Widget build(BuildContext context) => NotificationAskGate(
    builder: (context, {required holdsTour}) => _LocationShareAskHost(
      ready: !holdsTour,
      builder: (context, {required holdsLocation}) =>
          builder(context, holdsTour: holdsTour || holdsLocation),
    ),
  );
}

class _LocationShareAskHost extends ConsumerStatefulWidget {
  const _LocationShareAskHost({required this.ready, required this.builder});

  /// False while the notifications page is still pending or on top.
  final bool ready;
  final Widget Function(BuildContext context, {required bool holdsLocation})
  builder;

  @override
  ConsumerState<_LocationShareAskHost> createState() =>
      _LocationShareAskHostState();
}

class _LocationShareAskHostState extends ConsumerState<_LocationShareAskHost> {
  bool _checking = false;

  /// The uid whose page is already decided this session.
  String? _settledUid;

  /// Captured each build, so the post-await recheck registers no dependency.
  ModalRoute<Object?>? _route;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myEmployeeRecordProvider);
    final loadingMe =
        me == null &&
        (ref.watch(activeUserIdentityProvider).isLoading ||
            ref.watch(allUsersStreamProvider).isLoading);
    final due =
        me != null && me.uid != _settledUid && isLocationShareAskDue(me: me);
    _route = ModalRoute.of(context);
    final onTop =
        HubShellScope.currentOf(context) == HubTab.calendar &&
        (_route?.isCurrent ?? true);
    if (due && onTop && widget.ready && !_checking) {
      _checking = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_maybeAsk(me)),
      );
    }
    return widget.builder(context, holdsLocation: loadingMe || due);
  }

  Future<void> _maybeAsk(EmployeeRecord me) async {
    final logger = ref.read(loggerProvider);
    final store = ref.read(locationShareAskStoreProvider);
    var settled = true;
    try {
      final info = await ref.read(appInfoProvider.future);
      final build = '${info.version}+${info.buildNumber}';
      if (!await store.hasAsked(me.uid, build: build)) {
        if (!mounted || !_calendarOnTop()) {
          settled = false;
          return;
        }
        // Marked before the push, so a page killed mid-decision is still final.
        await store.markAsked(me.uid, build: build);
        if (mounted) {
          Navigator.of(context).pushNamed(AppRoutes.shareLocationAsk);
        }
      }
    } catch (e, st) {
      logger.warn('PRESENCE location ask failed', e, st);
    } finally {
      _checking = false;
      if (mounted) {
        setState(() {
          if (settled) _settledUid = me.uid;
        });
      }
    }
  }

  bool _calendarOnTop() =>
      HubShellScope.readCurrentOf(context) == HubTab.calendar &&
      (_route?.isCurrent ?? true);
}
