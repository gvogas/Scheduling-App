import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_privacy.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/logging/app_logger.dart';

/// The only importer of `firebase_analytics`; every method is `void` and
/// never throws.
class AnalyticsService {
  AnalyticsService({FirebaseAnalytics? analytics, AppLogger? logger})
    : _override = analytics,
      _logger = logger ?? AppLogger();

  /// Null in production; a fake in tests.
  final FirebaseAnalytics? _override;
  final AppLogger _logger;

  /// Resolved lazily; null when Firebase is uninitialized (widget tests).
  FirebaseAnalytics? get _analytics {
    if (_override != null) return _override;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseAnalytics.instance;
  }

  /// Builds the navigation observer, typed as the framework supertype so the
  /// caller never needs to import `firebase_analytics` itself.
  NavigatorObserver navigationObserver({
    required String? Function(RouteSettings settings) nameExtractor,
    required void Function(Object error) onError,
  }) => FirebaseAnalyticsObserver(
    analytics: _override ?? FirebaseAnalytics.instance,
    nameExtractor: nameExtractor,
    onError: onError,
  );

  // ---------------------------------------------------------------------------
  // Collection control and user properties
  // ---------------------------------------------------------------------------

  /// Turns collection on or off for the whole app.
  void setCollectionEnabled({required bool enabled}) => _guard(
    'setAnalyticsCollectionEnabled',
    (analytics) => analytics.setAnalyticsCollectionEnabled(enabled),
  );

  /// `admin` / `employee`, or null to clear it — never the uid.
  void setUserRole(String? role) =>
      _setUserProperty(AnalyticsUserProperties.userRole, role);

  void setAppLocale(String? locale) =>
      _setUserProperty(AnalyticsUserProperties.appLocale, locale);

  void setBuildEnv(String env) =>
      _setUserProperty(AnalyticsUserProperties.buildEnv, env);

  void _setUserProperty(String name, String? value) {
    if (!isKnownUserProperty(name)) {
      assert(false, 'Undeclared analytics user property "$name".');
      return;
    }
    _guard(
      'setUserProperty($name)',
      (analytics) => analytics.setUserProperty(
        name: name,
        value: sanitizeUserPropertyValue(value),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Screens
  // ---------------------------------------------------------------------------

  /// Records a screen view; engagement time accrues to the last one reported.
  void logScreenView(String screenName) {
    assert(
      AnalyticsScreens.allScreens.contains(screenName) &&
          AnalyticsNames.isValidParam(screenName),
      'Analytics screen "$screenName" is not declared in '
      'AnalyticsScreens.allScreens.',
    );
    _guard(
      'logScreenView($screenName)',
      (analytics) => analytics.logScreenView(screenName: screenName),
    );
  }

  // ---------------------------------------------------------------------------
  // Appointments and jobs
  // ---------------------------------------------------------------------------

  void logAppointmentCreated({
    required String source,
    required String repeat,
    required int assigneeCount,
    required bool hasPhotos,
    required bool isPersonal,
    required bool isAllDay,
    required bool isDayOff,
    required bool isMultiDay,
  }) => _log(AnalyticsEvents.appointmentCreated, {
    AnalyticsParams.source: source,
    AnalyticsParams.repeat: repeat,
    AnalyticsParams.assigneeCount: bucketCount(assigneeCount),
    AnalyticsParams.hasPhotos: hasPhotos,
    AnalyticsParams.isPersonal: isPersonal,
    AnalyticsParams.isAllDay: isAllDay,
    AnalyticsParams.isDayOff: isDayOff,
    AnalyticsParams.isMultiDay: isMultiDay,
  });

  void logAppointmentViewed({
    required String source,
    required String status,
    required bool isPersonal,
    required bool hasPhotos,
  }) => _log(AnalyticsEvents.appointmentViewed, {
    AnalyticsParams.source: source,
    AnalyticsParams.status: status,
    AnalyticsParams.isPersonal: isPersonal,
    AnalyticsParams.hasPhotos: hasPhotos,
  });

  void logAppointmentEdited({
    required String scope,
    required int assigneeCount,
  }) => _log(AnalyticsEvents.appointmentEdited, {
    AnalyticsParams.scope: scope,
    AnalyticsParams.assigneeCount: bucketCount(assigneeCount),
  });

  void logAppointmentDeleted({required String scope}) =>
      _log(AnalyticsEvents.appointmentDeleted, {AnalyticsParams.scope: scope});

  void logJobStarted() => _log(AnalyticsEvents.jobStarted, const {});

  /// No `hasNotes`: `fieldNotes` is the legacy path and would under-report.
  void logJobCompleted({required bool hasPhotos}) => _log(
    AnalyticsEvents.jobCompleted,
    {AnalyticsParams.hasPhotos: hasPhotos},
  );

  void logAppointmentCancelled() =>
      _log(AnalyticsEvents.appointmentCancelled, const {});

  void logAppointmentDelayed({required int minutes}) => _log(
    AnalyticsEvents.appointmentDelayed,
    {AnalyticsParams.delayMinutes: minutes},
  );

  /// The mark-complete notice's Undo.
  void logAppointmentRestored() =>
      _log(AnalyticsEvents.appointmentRestored, const {});

  // ---------------------------------------------------------------------------
  // Calendar
  // ---------------------------------------------------------------------------

  /// [direction] is `next` / `previous` / `today` / `picked`.
  void logCalendarDateChanged({
    required String viewMode,
    required String direction,
  }) => _log(AnalyticsEvents.calendarDateChanged, {
    AnalyticsParams.viewMode: viewMode,
    AnalyticsParams.direction: direction,
  });

  void logCalendarViewChanged({required String viewMode}) => _log(
    AnalyticsEvents.calendarViewChanged,
    {AnalyticsParams.viewMode: viewMode},
  );

  // ---------------------------------------------------------------------------
  // Clients
  // ---------------------------------------------------------------------------

  void logClientCreated({required String source}) =>
      _log(AnalyticsEvents.clientCreated, {AnalyticsParams.source: source});

  void logClientViewed({required String source}) =>
      _log(AnalyticsEvents.clientViewed, {AnalyticsParams.source: source});

  void logClientEdited() => _log(AnalyticsEvents.clientEdited, const {});

  /// [action] is `archive` / `unarchive` — one toggle, one event.
  void logClientArchived({required String action}) =>
      _log(AnalyticsEvents.clientArchived, {AnalyticsParams.action: action});

  void logClientDeleted() => _log(AnalyticsEvents.clientDeleted, const {});

  // ---------------------------------------------------------------------------
  // Employees
  // ---------------------------------------------------------------------------

  void logEmployeeInvited() => _log(AnalyticsEvents.employeeInvited, const {});

  void logEmployeeViewed() => _log(AnalyticsEvents.employeeViewed, const {});

  void logEmployeeEdited() => _log(AnalyticsEvents.employeeEdited, const {});

  /// [status] is the new account status (`active` / `disabled`), never a name.
  void logEmployeeStatusChanged({required String status}) => _log(
    AnalyticsEvents.employeeStatusChanged,
    {AnalyticsParams.status: status},
  );

  // ---------------------------------------------------------------------------
  // Cross-cutting
  // ---------------------------------------------------------------------------

  /// Records that a search RAN — never what was typed, and no result count.
  void logSearchUsed({required String surface, required int queryLength}) =>
      _log(AnalyticsEvents.searchUsed, {
        AnalyticsParams.surface: surface,
        AnalyticsParams.queryLength: bucketQueryLength(queryLength),
      });

  void logFilterUsed({
    required String surface,
    required String filterName,
    String? filterValue,
  }) => _log(AnalyticsEvents.filterUsed, {
    AnalyticsParams.surface: surface,
    AnalyticsParams.filterName: filterName,
    AnalyticsParams.filterValue: filterValue,
  });

  void logPhotoAdded({required String surface, required int count}) =>
      _log(AnalyticsEvents.photoAdded, {
        AnalyticsParams.surface: surface,
        AnalyticsParams.photoCount: bucketCount(count),
      });

  /// The note's TEXT never leaves the device — only that one was posted.
  void logNoteAdded({required String surface}) =>
      _log(AnalyticsEvents.noteAdded, {AnalyticsParams.surface: surface});

  /// [settingValue] must be a slug or a bool-as-`on`/`off`, never a free value.
  void logSettingsChanged({
    required String settingName,
    String? settingValue,
  }) => _log(AnalyticsEvents.settingsChanged, {
    AnalyticsParams.settingName: settingName,
    AnalyticsParams.settingValue: settingValue,
  });

  /// [action] is `call` / `email` / `directions` / `link`, never the value.
  void logContactAction({required String action}) =>
      _log(AnalyticsEvents.contactAction, {AnalyticsParams.action: action});

  void logDashboardPeriodChanged({required String period}) => _log(
    AnalyticsEvents.dashboardPeriodChanged,
    {AnalyticsParams.period: period},
  );

  /// A bulk close from the overdue review — the action and a bucketed count,
  /// nothing that identifies a job.
  void logOverdueReviewApplied({required String action, required int count}) =>
      _log(AnalyticsEvents.overdueReviewApplied, {
        AnalyticsParams.action: action,
        AnalyticsParams.count: bucketCount(count),
      });

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  void logLogin({required String role}) => _log(AnalyticsEvents.login, {
    AnalyticsParams.method: 'password',
    AnalyticsParams.role: role,
  });

  void logSignOut() => _log(AnalyticsEvents.signOut, const {});

  void logAccountSetupCompleted() =>
      _log(AnalyticsEvents.accountSetupCompleted, const {});

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _log(String name, Map<String, Object?> params) {
    assert(isKnownEvent(name), 'Undeclared analytics event "$name".');
    final sanitized = sanitizeAnalyticsParams(params);
    _guard(
      'logEvent($name)',
      (analytics) => analytics.logEvent(
        name: name,
        parameters: sanitized.isEmpty ? null : sanitized,
      ),
    );
  }

  /// Logs and swallows every failure so instrumentation never breaks a flow.
  Future<void> _guard(
    String label,
    Future<void> Function(FirebaseAnalytics analytics) send,
  ) async {
    try {
      final analytics = _analytics;
      if (analytics == null) return;
      await send(analytics);
    } catch (error, stack) {
      _logger.warn('ANALYTICS $label failed', error, stack);
    }
  }
}
