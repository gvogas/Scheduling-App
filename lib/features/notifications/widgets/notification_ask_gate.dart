import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/features/employees/domain/models/employee_record.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/notifications/data/notification_ask_store.dart';
import 'package:scheduling/features/notifications/domain/notification_ask_policy.dart';
import 'package:scheduling/features/settings/application/my_details_providers.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Pushes the notifications page once per device and uid while iOS has never
/// been asked; `holdsTour` stays true until the page is decided.
class NotificationAskGate extends ConsumerStatefulWidget {
  const NotificationAskGate({required this.builder, super.key});

  final Widget Function(BuildContext context, {required bool holdsTour})
  builder;

  @override
  ConsumerState<NotificationAskGate> createState() =>
      _NotificationAskGateState();
}

class _NotificationAskGateState extends ConsumerState<NotificationAskGate> {
  bool _checking = false;
  String? _settledUid;

  /// Captured each build, so the post-await recheck registers no dependency.
  ModalRoute<Object?>? _route;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(myEmployeeRecordProvider);
    final due =
        me != null && me.uid != _settledUid && isNotificationAskDue(me: me);
    _route = ModalRoute.of(context);
    final onTop =
        HubShellScope.currentOf(context) == HubTab.calendar &&
        (_route?.isCurrent ?? true);
    if (due && onTop && !_checking) {
      _checking = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_maybeAsk(me)),
      );
    }
    return widget.builder(context, holdsTour: due);
  }

  Future<void> _maybeAsk(EmployeeRecord me) async {
    final logger = ref.read(loggerProvider);
    final store = ref.read(notificationAskStoreProvider);
    final service = ref.read(pushNotificationServiceProvider);
    var settled = true;
    try {
      if (!await store.hasSeen(me.uid)) {
        final status = await service.authorizationStatus();
        if (status == AuthorizationStatus.notDetermined) {
          if (!mounted || !_calendarOnTop()) {
            settled = false;
            return;
          }
          // Marked before the push: Not now and a killed page are both final.
          await store.markSeen(me.uid);
          if (!mounted) return;
          // Awaited so the team-map page waits for this one to pop.
          await Navigator.of(context).pushNamed(AppRoutes.notificationAsk);
        }
      }
    } catch (e, st) {
      logger.warn('PUSH notification ask failed', e, st);
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
