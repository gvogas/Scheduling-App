/// The ONE owner of every analytics event name, parameter name and parameter
/// value this app sends.
///
/// A name spelled at a call site is a name that can drift, and a drifted event
/// name does not error — it silently becomes a second, near-identical row in
/// the Firebase console that nobody notices until a report is wrong. Every
/// literal lives here; `AnalyticsService` is the only file allowed to read it.
library;

/// Custom event names.
///
/// Firebase caps an event name at 40 chars, `[A-Za-z][A-Za-z0-9_]*`, and
/// reserves the `firebase_`/`google_`/`ga_` prefixes. `AnalyticsNames.isValidEvent`
/// pins those rules; the test suite walks [allEvents] through it.
abstract final class AnalyticsEvents {
  // Appointments / jobs.
  static const String appointmentCreated = 'appointment_created';
  static const String appointmentViewed = 'appointment_viewed';
  static const String appointmentEdited = 'appointment_edited';
  static const String appointmentDeleted = 'appointment_deleted';
  static const String appointmentCancelled = 'appointment_cancelled';
  static const String appointmentDelayed = 'appointment_delayed';
  static const String appointmentRestored = 'appointment_restored';
  static const String jobStarted = 'job_started';
  static const String jobCompleted = 'job_completed';
  static const String overdueReviewApplied = 'overdue_review_applied';

  // Calendar.
  static const String calendarDateChanged = 'calendar_date_changed';
  static const String calendarViewChanged = 'calendar_view_changed';

  // Clients.
  static const String clientCreated = 'client_created';
  static const String clientViewed = 'client_viewed';
  static const String clientEdited = 'client_edited';
  static const String clientArchived = 'client_archived';
  static const String clientDeleted = 'client_deleted';

  // Employees.
  static const String employeeInvited = 'employee_invited';
  static const String employeeViewed = 'employee_viewed';
  static const String employeeEdited = 'employee_edited';
  static const String employeeStatusChanged = 'employee_status_changed';

  // Cross-cutting.
  static const String searchUsed = 'search_used';
  static const String filterUsed = 'filter_used';
  static const String photoAdded = 'photo_added';
  static const String noteAdded = 'note_added';
  static const String settingsChanged = 'settings_changed';
  static const String contactAction = 'contact_action';
  static const String dashboardPeriodChanged = 'dashboard_period_changed';

  // Auth. `login` is a Firebase RESERVED-but-recommended name, not a custom
  // one — it feeds the console's built-in engagement reports, so it keeps the
  // canonical spelling rather than an `auth_` prefix of ours.
  static const String login = 'login';
  static const String signOut = 'sign_out';
  static const String accountSetupCompleted = 'account_setup_completed';

  static const Set<String> allEvents = {
    appointmentCreated,
    appointmentViewed,
    appointmentEdited,
    appointmentDeleted,
    appointmentCancelled,
    appointmentDelayed,
    appointmentRestored,
    jobStarted,
    jobCompleted,
    overdueReviewApplied,
    calendarDateChanged,
    calendarViewChanged,
    clientCreated,
    clientViewed,
    clientEdited,
    clientArchived,
    clientDeleted,
    employeeInvited,
    employeeViewed,
    employeeEdited,
    employeeStatusChanged,
    searchUsed,
    filterUsed,
    photoAdded,
    noteAdded,
    settingsChanged,
    contactAction,
    dashboardPeriodChanged,
    login,
    signOut,
    accountSetupCompleted,
  };
}

/// Parameter names.
///
/// This set doubles as the sanitizer's ALLOWLIST — a key absent from
/// [allParams] is dropped before it reaches Firebase. That is what makes a
/// PII leak through a careless call site structurally impossible rather than
/// merely discouraged: a new parameter has to be declared here first, which is
/// the moment someone decides whether it is safe to transmit.
abstract final class AnalyticsParams {
  /// Where in the app the action was taken (see [AnalyticsSources]).
  static const String source = 'source';

  /// The surface a cross-cutting event fired from (see [AnalyticsSurfaces]).
  static const String surface = 'surface';

  /// Appointment shape — never its content.
  static const String repeat = 'repeat';
  static const String assigneeCount = 'assignee_count';
  static const String hasPhotos = 'has_photos';
  static const String isPersonal = 'is_personal';
  static const String isAllDay = 'is_all_day';
  static const String isDayOff = 'is_day_off';
  static const String isMultiDay = 'is_multi_day';
  static const String status = 'status';
  static const String scope = 'scope';
  static const String delayMinutes = 'delay_minutes';

  /// Calendar.
  static const String viewMode = 'view_mode';
  static const String direction = 'direction';

  /// Search and filters. Deliberately NO query text — only its shape.
  static const String queryLength = 'query_length';
  static const String filterName = 'filter_name';
  static const String filterValue = 'filter_value';

  /// Media / notes.
  static const String photoCount = 'photo_count';

  /// Settings and account.
  static const String settingName = 'setting_name';
  static const String settingValue = 'setting_value';
  static const String method = 'method';
  static const String action = 'action';
  static const String period = 'period';
  static const String role = 'role';

  /// How many jobs one bulk action touched.
  static const String count = 'count';

  static const Set<String> allParams = {
    source,
    surface,
    repeat,
    assigneeCount,
    hasPhotos,
    isPersonal,
    isAllDay,
    isDayOff,
    isMultiDay,
    status,
    scope,
    delayMinutes,
    viewMode,
    direction,
    queryLength,
    filterName,
    filterValue,
    photoCount,
    settingName,
    settingValue,
    method,
    action,
    period,
    role,
    count,
  };
}

/// User property names. Firebase allows 25 per project.
///
/// App version, device model and OS version are NOT here on purpose: Firebase
/// reports all three as automatic dimensions, so declaring them would spend a
/// property slot on data the console already has.
abstract final class AnalyticsUserProperties {
  static const String userRole = 'user_role';
  static const String appLocale = 'app_locale';
  static const String buildEnv = 'build_env';

  static const Set<String> allProperties = {userRole, appLocale, buildEnv};
}

/// Canonical `source` values — where an entity was created from.
abstract final class AnalyticsSources {
  static const String calendar = 'calendar';
  static const String clientsTab = 'clients_tab';
  static const String clientDetail = 'client_detail';
  static const String inlineAddClient = 'inline_add_client';
  static const String dashboard = 'dashboard';
  static const String history = 'history';
  static const String dayRoute = 'day_route';
  static const String employees = 'employees';
  static const String notification = 'notification';
  static const String overdueReview = 'overdue_review';
  /// An in-app notice's action — distinct from a push tap.
  static const String notice = 'notice';
}

/// Canonical `action` values for [AnalyticsEvents.contactAction].
abstract final class AnalyticsContactActions {
  static const String call = 'call';
  static const String email = 'email';
  static const String directions = 'directions';

  /// An external web page (the legal links).
  static const String link = 'link';
}

/// Canonical `action` values for [AnalyticsEvents.overdueReviewApplied].
abstract final class AnalyticsOverdueReviewActions {
  static const String complete = 'complete';
  static const String notDone = 'not_done';
}

/// Canonical `surface` values for the cross-cutting events.
abstract final class AnalyticsSurfaces {
  static const String clients = 'clients';
  static const String history = 'history';
  static const String appointmentForm = 'appointment_form';
  static const String fieldRecord = 'field_record';
}

/// Canonical `filter_name` values for [AnalyticsEvents.filterUsed].
abstract final class AnalyticsFilters {
  static const String none = 'none';
  static const String type = 'type';
  static const String building = 'building';
  static const String archived = 'archived';
  static const String sort = 'sort';
  static const String year = 'year';
  static const String employee = 'employee';
  static const String status = 'status';
}

/// Canonical `setting_name` values for [AnalyticsEvents.settingsChanged].
abstract final class AnalyticsSettings {
  static const String theme = 'theme';
  static const String textScale = 'text_scale';
  static const String language = 'language';
  static const String appLock = 'app_lock';
  static const String liveActivity = 'live_activity';
}

/// Canonical `direction` values for [AnalyticsEvents.calendarDateChanged].
abstract final class AnalyticsDirections {
  static const String today = 'today';
  static const String picked = 'picked';
  static const String weekStrip = 'week_strip';
  static const String month = 'month';
  static const String next = 'next';
  static const String previous = 'previous';
  static const String day = 'day';
}

/// Canonical `action` values for [AnalyticsEvents.clientArchived].
abstract final class AnalyticsArchiveActions {
  static const String archive = 'archive';
  static const String unarchive = 'unarchive';
}

/// Canonical `scope` values for an edit or delete that can span a series.
abstract final class AnalyticsScopes {
  static const String single = 'single';
  static const String series = 'series';
}

/// Canonical `build_env` values.
abstract final class AnalyticsBuildEnvs {
  static const String release = 'release';
  static const String debug = 'debug';
}

/// Shared validity rules for the names above.
///
/// Firebase rejects a malformed name SILENTLY — the event simply never appears
/// in the console — so these are pinned by tests rather than discovered in
/// production.
abstract final class AnalyticsNames {
  static const int maxEventNameLength = 40;
  static const int maxParamNameLength = 40;
  static const int maxUserPropertyNameLength = 24;

  static const Set<String> _reservedPrefixes = {'firebase_', 'google_', 'ga_'};

  static final RegExp _nameShape = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

  static bool _isWellFormed(String name, int maxLength) {
    if (name.isEmpty || name.length > maxLength) return false;
    if (!_nameShape.hasMatch(name)) return false;
    return !_reservedPrefixes.any(name.startsWith);
  }

  static bool isValidEvent(String name) =>
      _isWellFormed(name, maxEventNameLength);

  static bool isValidParam(String name) =>
      _isWellFormed(name, maxParamNameLength);

  static bool isValidUserProperty(String name) =>
      _isWellFormed(name, maxUserPropertyNameLength);
}
