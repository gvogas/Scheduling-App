import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/utils/retry.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/utils/sheet_helpers.dart';
import 'package:scheduling/features/home_widget/application/widget_sync_service.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';
import 'package:scheduling/routes/hub_shell.dart';

/// Routes the two non-`app_links` external entry points — iOS home-widget taps
/// and notification taps — into the appointment detail sheet.
///
/// Pulled out of `main.dart` for the same reason `AccountExitListeners` was:
/// as private `State` methods on the app root none of this could be exercised,
/// and it is the code path a user hits when the app is not already running.
/// The `app_links` third of the same router already lives in
/// `core/deep_links/`; this is the other two thirds.
///
/// [start] belongs in `initState` and [dispose] in `dispose`, like any other
/// subscription owner.
class AppointmentLinkOpener {
  AppointmentLinkOpener({
    required this.ref,
    required this.navigatorKey,
    required this.isMounted,
    bool Function()? isSignedIn,
    AppointmentLinkHub? Function()? resolveHub,
    Future<void> Function(
      BuildContext context,
      AppointmentRecord record, {
      required bool showActions,
      required String analyticsSource,
    })?
    showDetails,
    Duration hubPollInterval = const Duration(milliseconds: 200),
  }) : isSignedIn = isSignedIn ?? _firebaseSignedIn,
       resolveHub = resolveHub ?? _liveHubShell,
       showDetails = showDetails ?? showEventDetails,
       _hubPollInterval = hubPollInterval;

  static bool _firebaseSignedIn() => FirebaseAuth.instance.currentUser != null;

  static AppointmentLinkHub? _liveHubShell() {
    final shell = HubShell.liveState;
    if (shell == null || !shell.mounted) return null;
    return shell;
  }

  final WidgetRef ref;
  final GlobalKey<NavigatorState> navigatorKey;

  /// The host `State`'s mounted flag — every leg of this router awaits, and
  /// must not act on a torn-down tree.
  final bool Function() isMounted;

  /// Injectable so the signed-out early return can be tested; production
  /// passes nothing and gets the real singleton.
  final bool Function() isSignedIn;

  final AppointmentLinkHub? Function() resolveHub;

  final Future<void> Function(
    BuildContext context,
    AppointmentRecord record, {
    required bool showActions,
    required String analyticsSource,
  })
  showDetails;

  final Duration _hubPollInterval;

  StreamSubscription<Uri?>? _widgetTapSubscription;
  StreamSubscription<RemoteMessage>? _pushTapSubscription;

  /// Number of [_hubPollInterval] ticks spent waiting for the hub — ~10s.
  static const int _hubPollAttempts = 50;

  /// The `kind` the month-end overdue review push carries.
  static const String _overdueReviewKind = 'overdueReview';

  void start() {
    _startPushTaps();
    _startWidgetTaps();
  }

  void dispose() {
    unawaited(_widgetTapSubscription?.cancel());
    _widgetTapSubscription = null;
    unawaited(_pushTapSubscription?.cancel());
    _pushTapSubscription = null;
  }

  /// iOS home-widget taps deep-link to appointment detail via URI scheme.
  void _startWidgetTaps() {
    if (!Platform.isIOS) return;
    final logger = ref.read(loggerProvider);
    unawaited(() async {
      try {
        await HomeWidget.setAppGroupId(widgetAppGroupId);
        if (!isMounted()) return;
        _widgetTapSubscription = HomeWidget.widgetClicked.listen(
          handleWidgetTap,
          onError: (Object e, StackTrace st) =>
              logger.warn('WIDGET-TAP stream error', e, st),
        );
        final launchUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
        await handleWidgetTap(launchUri);
      } catch (e, st) {
        logger.warn('WIDGET-TAP setup failed', e, st);
      }
    }());
  }

  @visibleForTesting
  Future<void> handleWidgetTap(Uri? uri) async {
    if (uri == null) return;
    final appointmentId = uri.queryParameters['id']?.trim() ?? '';
    final logger = ref.read(loggerProvider);
    // Swallow errors to prevent leaking into zone handlers as FATAL crashes.
    try {
      await openAppointment(appointmentId);
    } catch (e, st) {
      logger.warn('WIDGET-TAP open failed', e, st);
    }
  }

  /// Notification taps open appointment detail on calendar hub.
  void _startPushTaps() {
    final service = ref.read(pushNotificationServiceProvider);
    // Hoisted like the widget-tap sibling above: neither the `initialMessage`
    // chain nor the stream's `onError` is cancelled by dispose, so a failure
    // after teardown would `ref.read` on an unmounted consumer and throw out
    // of the very call that exists to report it.
    final logger = ref.read(loggerProvider);
    unawaited(
      service
          .initialMessage()
          .then(handlePushTap)
          .catchError(
            (Object e, StackTrace st) =>
                logger.warn('PUSH-TAP initial message failed', e, st),
          ),
    );
    _pushTapSubscription = service.onMessageOpenedApp.listen(
      handlePushTap,
      onError: (Object e, StackTrace st) =>
          logger.warn('PUSH-TAP stream error', e, st),
    );
  }

  @visibleForTesting
  Future<void> handlePushTap(RemoteMessage? message) async {
    if (message == null) return;
    final logger = ref.read(loggerProvider);
    // Swallow errors to prevent leaking into zone handlers as FATAL crashes.
    try {
      // Kind BEFORE the id: the month-end review push carries no appointmentId.
      if (message.data['kind'] == _overdueReviewKind) {
        await openOverdueReview();
        return;
      }
      final appointmentId =
          (message.data['appointmentId'] as String?)?.trim() ?? '';
      await openAppointment(appointmentId);
    } catch (e, st) {
      logger.warn('PUSH-TAP open failed', e, st);
    }
  }

  /// The month-end push: lands on the calendar, then opens the overdue review
  /// over it for an admin.
  Future<void> openOverdueReview() async {
    if (!isSignedIn()) return;
    final shell = await _landOnCalendar(ref.read(loggerProvider));
    if (shell == null) return;
    final navContext = navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    shell.goHome();
    if (!shell.isAdmin) return;
    Navigator.of(navContext).pushNamed(
      AppRoutes.overdueReview,
      arguments: OverdueReviewArgs(isAdmin: true, employeeId: shell.employeeId),
    );
  }

  /// Shared deep-link handler — shows the calendar, then opens the
  /// appointment if it's valid. Also the `app_links` dispatcher's callback.
  Future<void> openAppointment(String appointmentId) async {
    if (!isSignedIn()) return;

    final logger = ref.read(loggerProvider);
    // Read every provider up front: `ref.read` on an unmounted consumer throws
    // under Riverpod 3, and the notice below sits behind two awaits.
    final notices = ref.read(noticeServiceProvider);
    final repository = ref.read(appointmentsRepositoryProvider);
    // Fetch this concurrently with hub startup, on the shared retry ladder —
    // a cold start right after sign-in can lose the auth-token race.
    final recordFuture = appointmentId.isEmpty || !_isDocId(appointmentId)
        ? Future<AppointmentRecord?>.value()
        : retryAsync<AppointmentRecord?>(
            () => repository.getAppointmentById(appointmentId),
          ).catchError((Object e, StackTrace st) {
            logger.warn('PUSH-TAP load appointment failed', e, st);
            return null;
          });

    final shell = await _landOnCalendar(logger);
    if (shell == null) return;

    final record = await recordFuture;
    if (!isMounted()) return;

    final navContext = navigatorKey.currentContext;
    if (navContext == null || !navContext.mounted) return;
    // Collapse stacked routes to open the appointment over the shell.
    // Not popUntil(isFirst): on _hubRoute's fallback branch the shell is not
    // route #1, so that predicate pops the shell itself.
    shell.goHome();

    if (appointmentId.isEmpty) return;
    if (record == null) {
      notices.info(
        AppLocalizations.of(navContext).calendar_appointmentUnavailable,
      );
      return;
    }
    // This opener serves BOTH external entry points — an `esproschedule://`
    // deep link and a push/widget tap — so it reports the one they share.
    await showDetails(
      navContext,
      record,
      showActions: shell.isAdmin,
      analyticsSource: AnalyticsSources.notification,
    );
  }

  /// Shows the calendar once the hub is live; null (logged) if it never is.
  Future<AppointmentLinkHub?> _landOnCalendar(AppLogger logger) async {
    final shell = await _awaitLiveHub();
    if (!isMounted()) return null;
    if (shell == null) {
      logger.warn('PUSH-TAP hub never appeared');
      return null;
    }
    shell.showCalendar();
    return shell;
  }

  /// Polls for up to ~10s waiting for the live hub to appear. Returns null
  /// if it never shows up.
  Future<AppointmentLinkHub?> _awaitLiveHub() async {
    for (var i = 0; i < _hubPollAttempts; i++) {
      final shell = resolveHub();
      if (shell != null) return shell;
      if (!isMounted()) return null;
      await Future<void>.delayed(_hubPollInterval);
    }
    return null;
  }
}

/// Mirrors `isValidDocIdField` in `firestore.rules`: no path separator, ≤ 128.
bool _isDocId(String id) => id.length <= 128 && !id.contains('/');
