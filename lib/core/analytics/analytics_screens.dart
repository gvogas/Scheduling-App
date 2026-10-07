import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/routes/app_routes.dart';

/// Canonical screen names.
///
/// A route path (`/settings/my-details`) is a poor console label and it ties a
/// report to a URL shape that can change, so every surface reports one stable
/// snake_case name from here instead.
abstract final class AnalyticsScreens {
  // Hub tabs — reported by `HubShellState`, never by the route observer.
  static const String calendar = 'calendar';
  static const String clients = 'clients';
  static const String employees = 'employees';
  static const String liveMap = 'live_map';

  // Pushed routes.
  static const String dashboard = 'dashboard';
  static const String history = 'history';
  static const String dayRoute = 'day_route';
  static const String overdueReview = 'overdue_review';
  static const String settings = 'settings';
  static const String myDetails = 'my_details';
  static const String login = 'login';
  static const String forgotPassword = 'forgot_password';
  static const String accountSetup = 'account_setup';

  // Sheets and sub-screens that own no named route — reported manually.
  static const String addAppointment = 'add_appointment';
  static const String appointmentDetails = 'appointment_details';
  static const String addClient = 'add_client';
  static const String editClient = 'edit_client';
  static const String clientDetail = 'client_detail';
  static const String invitePerson = 'invite_person';
  static const String editPerson = 'edit_person';
  static const String onboarding = 'onboarding';

  static const Set<String> allScreens = {
    calendar,
    clients,
    employees,
    liveMap,
    dashboard,
    history,
    dayRoute,
    overdueReview,
    settings,
    myDetails,
    login,
    forgotPassword,
    accountSetup,
    addAppointment,
    appointmentDetails,
    addClient,
    editClient,
    clientDetail,
    invitePerson,
    editPerson,
    onboarding,
  };
}

/// The four routes the observer must IGNORE.
///
/// Each hub tab is reachable two ways that both end in `HubShellState.select`:
/// a fresh shell, or `HubTabRedirectRoute`, which pushes a NAMED route and then
/// hands off to the live shell. Letting the observer see those names would
/// count the redirect push and the tab switch as two screen views of the same
/// tab — and only on the redirect path, so the four tabs would look busier
/// than they are by an amount that depends on the user's back stack. The shell
/// owns these; the observer stays out.
const Set<String> kShellOwnedRoutes = {
  AppRoutes.mainCalendar,
  AppRoutes.clients,
  AppRoutes.employees,
  AppRoutes.liveMap,
};

/// Maps a named route to its canonical screen name.
///
/// Returns null for a route the observer must not report: an unnamed modal
/// sheet, a route owned by the hub shell, or anything unrecognised. A null tells
/// `FirebaseAnalyticsObserver` to skip the push entirely.
String? analyticsScreenForRoute(String? routeName) {
  if (routeName == null || routeName.isEmpty) return null;
  if (kShellOwnedRoutes.contains(routeName)) return null;
  return switch (routeName) {
    AppRoutes.dashboard => AnalyticsScreens.dashboard,
    AppRoutes.history => AnalyticsScreens.history,
    AppRoutes.dayRoute => AnalyticsScreens.dayRoute,
    AppRoutes.overdueReview => AnalyticsScreens.overdueReview,
    AppRoutes.settings => AnalyticsScreens.settings,
    AppRoutes.myDetails => AnalyticsScreens.myDetails,
    AppRoutes.login => AnalyticsScreens.login,
    AppRoutes.forgotPassword => AnalyticsScreens.forgotPassword,
    AppRoutes.accountSetup => AnalyticsScreens.accountSetup,
    _ => null,
  };
}

/// The canonical screen name for a hub tab.
String analyticsScreenForTab(HubTab tab) => switch (tab) {
  HubTab.calendar => AnalyticsScreens.calendar,
  HubTab.clients => AnalyticsScreens.clients,
  HubTab.employees => AnalyticsScreens.employees,
  HubTab.liveMap => AnalyticsScreens.liveMap,
};
