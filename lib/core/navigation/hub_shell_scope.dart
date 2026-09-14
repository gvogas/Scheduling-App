import 'package:flutter/material.dart';
import 'package:scheduling/core/navigation/app_destination.dart';

/// Tab-switch contract, so core can drive navigation without importing the
/// routes layer's widgets.
abstract interface class HubTabSelector {
  /// Switches the visible hub tab, refreshing the identity args the hub
  /// screens are built from.
  void select(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName,
    String userEmail,
  });

  /// [select] plus a pop of everything stacked above the shell, so the
  /// chosen tab is actually revealed. No-op pop when nothing is stacked.
  void selectAndReveal(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName,
    String userEmail,
  });

  /// Calendar pill / go-home: [selectAndReveal] on the calendar tab using
  /// the shell's own sticky identity.
  void goHome();
}

/// The slice of the live hub shell an inbound appointment link drives.
///
/// Narrow on purpose: the opener only ever shows the calendar, collapses the
/// stack and reads the live role. Depending on the interface rather than
/// `HubShellState` is what lets the routing be exercised without building the
/// real four-tab shell (every tab of which reaches Firebase). It lives here
/// beside [HubTabSelector] for that class's reason — so `core/` can name the
/// shell without `routes/` having to import back into `core/app/`.
abstract interface class AppointmentLinkHub {
  bool get isAdmin;

  String get employeeId;

  void showCalendar();

  void goHome();
}

/// Lets shell descendants reach the enclosing hub shell.
class HubShellScope extends InheritedWidget {
  const HubShellScope({
    required this.shell,
    required this.current,
    required super.child,
    super.key,
  });

  final HubTabSelector shell;
  final HubTab current;

  /// The most recently mounted shell, reachable from PUSHED routes — their
  /// subtree is a sibling overlay entry, so inheritance cannot find the
  /// scope. Set and cleared by HubShellState beside HubShell.liveState.
  static HubTabSelector? liveSelector;

  static HubTabSelector? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HubShellScope>()?.shell;

  /// The visible hub tab as a build dependency. Null outside the shell
  /// subtree — including on every pushed route.
  static HubTab? currentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HubShellScope>()?.current;

  /// One-shot read, no rebuild dependency — safe outside build.
  static HubTab? readCurrentOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<HubShellScope>()?.current;

  @override
  bool updateShouldNotify(HubShellScope oldWidget) =>
      current != oldWidget.current || shell != oldWidget.shell;
}

/// The one nav action for changing destination. Hub tabs switch the tab
/// (revealing the shell first when invoked from a pushed route); pushed
/// destinations push, deduped against the current route.
void navigateToDestination(
  BuildContext context,
  AppDestination destination, {
  required bool isAdmin,
  required String employeeId,
  String userName = '',
  String userEmail = '',
}) {
  switch (destination) {
    case final HubTab tab:
      final scoped = HubShellScope.maybeOf(context);
      if (scoped != null) {
        scoped.select(
          tab,
          isAdmin: isAdmin,
          employeeId: employeeId,
          userName: userName,
          userEmail: userEmail,
        );
        return;
      }
      final live = HubShellScope.liveSelector;
      if (live != null) {
        live.selectAndReveal(
          tab,
          isAdmin: isAdmin,
          employeeId: employeeId,
          userName: userName,
          userEmail: userEmail,
        );
        return;
      }
      final target = destinationRoute(
        tab,
        isAdmin: isAdmin,
        employeeId: employeeId,
        userName: userName,
        userEmail: userEmail,
      );
      Navigator.pushReplacementNamed(
        context,
        target.route,
        arguments: target.arguments,
      );
    case final PushedDestination pushed:
      final target = destinationRoute(
        pushed,
        isAdmin: isAdmin,
        employeeId: employeeId,
        userName: userName,
        userEmail: userEmail,
      );
      if (ModalRoute.settingsOf(context)?.name == target.route) return;
      Navigator.pushNamed(context, target.route, arguments: target.arguments);
  }
}

/// Calendar pill / drawer Calendar row: close the invoking surface's end
/// drawer, land on the calendar tab, collapse everything above the shell.
/// One canonical gesture — never hand-roll the parts.
void goHomeToCalendar(BuildContext context) {
  Scaffold.maybeOf(context)?.closeEndDrawer();
  final selector = HubShellScope.maybeOf(context) ?? HubShellScope.liveSelector;
  selector?.goHome();
}
