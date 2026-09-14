import 'package:scheduling/routes/app_routes.dart';

/// Anything the end drawer can navigate to.
sealed class AppDestination implements Enum {}

/// The four persistent hub tabs.
enum HubTab implements AppDestination { calendar, clients, employees, liveMap }

/// Destinations that push a plain route above the hub.
enum PushedDestination implements AppDestination {
  dayRoute,
  history,
  overdueReview,
  dashboard,
  settings,
}

/// Every destination, in tab-then-pushed order.
const List<AppDestination> allDestinations = [
  ...HubTab.values,
  ...PushedDestination.values,
];

/// Maps each destination to its route and typed args.
({String route, Object arguments}) destinationRoute(
  AppDestination destination, {
  required bool isAdmin,
  required String employeeId,
  String userName = '',
  String userEmail = '',
}) => switch (destination) {
  HubTab.calendar => (
    route: AppRoutes.mainCalendar,
    arguments: MainCalendarArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  HubTab.clients => (
    route: AppRoutes.clients,
    arguments: ClientsListArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  HubTab.employees => (
    route: AppRoutes.employees,
    arguments: MainCalendarArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  HubTab.liveMap => (
    route: AppRoutes.liveMap,
    arguments: MainCalendarArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.dayRoute => (
    route: AppRoutes.dayRoute,
    arguments: DayRouteArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.history => (
    route: AppRoutes.history,
    arguments: HistoryArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.overdueReview => (
    route: AppRoutes.overdueReview,
    arguments: OverdueReviewArgs(isAdmin: isAdmin, employeeId: employeeId),
  ),
  PushedDestination.dashboard => (
    route: AppRoutes.dashboard,
    arguments: DashboardArgs(
      isAdmin: isAdmin,
      employeeId: employeeId,
      userName: _blankToNull(userName),
      email: _blankToNull(userEmail),
    ),
  ),
  PushedDestination.settings => (
    route: AppRoutes.settings,
    arguments: SettingsArgs(
      name: userName,
      email: userEmail,
      role: isAdmin ? 'admin' : 'employee',
      employeeId: employeeId,
    ),
  ),
};

String? _blankToNull(String value) => value.isEmpty ? null : value;
