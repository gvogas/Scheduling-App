import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:scheduling/core/analytics/analytics_events.dart';
import 'package:scheduling/core/analytics/analytics_privacy.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/logging/app_logger.dart';

/// The ONE place this app talks to Firebase Analytics.
///
/// Nothing else may import `firebase_analytics`. Scattered `logEvent` calls are
/// how an event name drifts into two spellings and how a client's phone number
/// ends up on a wire, and neither failure reports itself — a malformed event is
/// dropped SILENTLY by Firebase, and a leaked parameter looks like a working
/// dashboard. Routing everything through here means the event vocabulary
/// (`analytics_events.dart`) and the PII sanitizer (`analytics_privacy.dart`)
/// are unavoidable rather than optional.
///
/// **No method here can throw, and every one returns `void`.** Each send is
/// wrapped and a failure is a `logger.warn` and nothing more: analytics is
/// instrumentation, and must never be the reason a save fails or a sheet
/// crashes. `void` rather than `Future<void>` is deliberate — a future would
/// make every one of the ~25 call sites, most of them inside an `async` widget
/// handler, either `await` a network round trip in the middle of a user action
/// or wrap it in `unawaited(...)`. Neither is ceremony worth paying for a call
/// that cannot fail and that nothing waits on.
class AnalyticsService {
  AnalyticsService({FirebaseAnalytics? analytics, AppLogger? logger})
    : _override = analytics,
      _logger = logger ?? AppLogger();

  /// Null in production; a fake in tests.
  final FirebaseAnalytics? _override;
  final AppLogger _logger;

  /// Resolved LAZILY, and null when there is nothing to talk to.
  ///
  /// `FirebaseAnalytics.instance` requires an initialized Firebase, which is
  /// the normal state of production and NOT the normal state of a widget test.
  /// Resolving in the constructor would make merely READING
  /// `analyticsServiceProvider` throw, so every one of the ~20 instrumented
  /// widgets would need a provider override to stay testable — and the first
  /// suite that forgot one would fail with a Firebase error pointing nowhere
  /// near the analytics call that caused it.
  ///
  /// Returning null instead of throwing is deliberate: an uninitialized
  /// Firebase is not a failure worth reporting, it is a harness with no
  /// analytics in it. Throwing-and-catching would work too, but it would print
  /// a `logger.warn` from every instrumented widget in the suite, which is the
  /// kind of noise that trains people to ignore the log.
  FirebaseAnalytics? get _analytics {
    if (_override != null) return _override;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseAnalytics.instance;
  }

  /// Exposed only so `main()` can hand the same instance to
  /// `FirebaseAnalyticsObserver`, which takes the plugin type directly.
  FirebaseAnalytics get rawAnalytics =>
      _override ?? FirebaseAnalytics.instance;

  // ---------------------------------------------------------------------------
  // Collection control and user properties
  // ---------------------------------------------------------------------------

  /// Turns collection on or off for the whole app.
  ///
  /// Debug builds pass `false` unless `--dart-define=ANALYTICS_DEBUG=true`, so
  /// day-to-day `flutter run` never reaches the production property.
  void setCollectionEnabled({required bool enabled}) => _guard(
    'setAnalyticsCollectionEnabled',
    (analytics) => analytics.setAnalyticsCollectionEnabled(enabled),
  );

  /// `admin` / `employee`, or null to clear it on sign-out.
  ///
  /// Passing the ROLE and never the uid is the whole point: it answers "how do
  /// admins and employees differ?" without Firebase ever holding a value that
  /// points at a person.
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

  /// Records a screen view.
  ///
  /// Firebase's automatic `user_engagement` event attributes its
  /// `engagement_time_msec` to whichever screen was last reported, which is
  /// what makes "how long do users spend in the calendar?" answerable without
  /// any timing code of ours.
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

  /// No `hasNotes`: the parent `fieldNotes` string is the LEGACY write path
  /// (crew notes live in a subcollection), so reading it would under-report to
  /// near zero. `note_added` already answers how often notes are written.
  void logJobCompleted({required bool hasPhotos}) =>
      _log(AnalyticsEvents.jobCompleted, {AnalyticsParams.hasPhotos: hasPhotos});

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

  void logClientEdited() =>
      _log(AnalyticsEvents.clientEdited, const {});

  /// [action] is `archive` / `unarchive` — one toggle, one event.
  void logClientArchived({required String action}) =>
      _log(AnalyticsEvents.clientArchived, {AnalyticsParams.action: action});

  void logClientDeleted() =>
      _log(AnalyticsEvents.clientDeleted, const {});

  // ---------------------------------------------------------------------------
  // Employees
  // ---------------------------------------------------------------------------

  void logEmployeeInvited() =>
      _log(AnalyticsEvents.employeeInvited, const {});

  void logEmployeeViewed() =>
      _log(AnalyticsEvents.employeeViewed, const {});

  void logEmployeeEdited() =>
      _log(AnalyticsEvents.employeeEdited, const {});

  /// [status] is the new account status (`active` / `disabled`), never a name.
  void logEmployeeStatusChanged({required String status}) => _log(
    AnalyticsEvents.employeeStatusChanged,
    {AnalyticsParams.status: status},
  );

  // ---------------------------------------------------------------------------
  // Cross-cutting
  // ---------------------------------------------------------------------------

  /// Records that a search RAN — never what was typed.
  ///
  /// A client search in this app is somebody's surname or phone number by
  /// definition, so only the query's bucketed length and result count go out.
  /// Fires once per SETTLED search, never per keystroke.
  ///
  /// No result count: the one place that knows a search actually ran is the
  /// debounce commit, and the results have not been fetched yet there. A
  /// count reported later would be a second event for one search.
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

  /// [action] is `call` / `email` / `directions` / `link` — never the number,
  /// the address or the URL.
  ///
  /// No `source`: this fires from the shared launch helpers, which are the one
  /// place all twelve call sites pass through and which by construction do not
  /// know which screen called them. Threading a surface down through them to
  /// satisfy a parameter would put a display concern in a launcher.
  void logContactAction({required String action}) =>
      _log(AnalyticsEvents.contactAction, {AnalyticsParams.action: action});

  void logDashboardPeriodChanged({required String period}) => _log(
    AnalyticsEvents.dashboardPeriodChanged,
    {AnalyticsParams.period: period},
  );

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

  /// Swallows every failure so instrumentation can never break a user flow.
  ///
  /// The `warn` still files it, so a permanently broken channel shows up in
  /// Crashlytics instead of presenting as "the dashboard is just empty" —
  /// which is the failure mode a bare `catch (_) {}` would produce.
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
