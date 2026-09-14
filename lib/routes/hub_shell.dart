import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/adaptive/adaptive.dart';
import 'package:scheduling/core/analytics/analytics_providers.dart';
import 'package:scheduling/core/analytics/analytics_screens.dart';
import 'package:scheduling/core/layout/primary_scroll_scope.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/screens/main_calendar_screen.dart';
import 'package:scheduling/features/clients/screens/clients_screen.dart';
import 'package:scheduling/features/employees/screens/employees_screen.dart';
import 'package:scheduling/features/presence/screens/live_map_screen.dart';

/// Post-login shell with four tab destinations, all kept alive in an
/// IndexedStack. Android back goes to calendar, unless we're already there.
class HubShell extends ConsumerStatefulWidget {
  const HubShell({
    required this.isAdmin,
    required this.employeeId,
    this.initialTab = HubTab.calendar,
    this.userName = '',
    this.userEmail = '',
    super.key,
    @visibleForTesting this.screenBuilder,
  });

  final bool isAdmin;
  final String employeeId;

  /// Initial tab (calendar on login, or another tab if deep-linked).
  final HubTab initialTab;

  /// Initial identity carried into pushed destinations (sticky).
  final String userName;
  final String userEmail;

  /// Lets tests swap in stub screens instead of the real ones.
  final Widget Function(HubTab tab)? screenBuilder;

  /// The most recently active shell — used to redirect hub-route pushes into
  /// tab switches.
  static HubShellState? get liveState => HubShellState._live;

  @override
  ConsumerState<HubShell> createState() => HubShellState();
}

class HubShellState extends ConsumerState<HubShell>
    implements HubTabSelector, AppointmentLinkHub {
  static HubShellState? _live;

  late bool _isAdmin = widget.isAdmin;
  late String _employeeId = widget.employeeId;
  late String _userName = widget.userName;
  late String _userEmail = widget.userEmail;
  late HubTab _current = widget.initialTab;

  /// Tabs built so far (lazy-built, kept alive by IndexedStack).
  late final Set<HubTab> _built = {widget.initialTab};

  /// The tab currently shown.
  HubTab get currentTab => _current;

  /// The live role, used by deep links to gate admin-only edit/cancel/delete
  /// controls.
  @override
  bool get isAdmin => _isAdmin;

  /// The live employee doc id, for a push that opens an admin screen.
  @override
  String get employeeId => _employeeId;

  /// The shell's own route — [goHome]'s pop target. Null only in a bare test
  /// harness with no enclosing route.
  ModalRoute<dynamic>? _shellRoute;

  @override
  void initState() {
    super.initState();
    _live = this;
    HubShellScope.liveSelector = this;
    _logTabView(_current);
  }

  /// The four hub tabs are the ONE set of screens the route observer ignores.
  ///
  /// A tab is reached three ways — a fresh shell, `HubTabRedirectRoute` handing
  /// off to a live one, or a plain in-shell switch — and only the middle one
  /// pushes a named route. Letting the observer see that push would count one
  /// path twice and the other two once, so the tabs would read busier than they
  /// are by an amount that depends on the user's back stack.
  /// `analyticsScreenForRoute` returns null for all four (`kShellOwnedRoutes`);
  /// this is the other half of that decision, and the two move together.
  void _logTabView(HubTab tab) {
    ref.read(analyticsServiceProvider).logScreenView(analyticsScreenForTab(tab));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not initState: ModalRoute.of registers an inherited dependency, which
    // is an assert failure there. Re-runs are harmless — the shell's route
    // identity is stable for its lifetime.
    _shellRoute = ModalRoute.of(context);
  }

  @override
  void dispose() {
    if (_live == this) _live = null;
    if (HubShellScope.liveSelector == this) HubShellScope.liveSelector = null;
    super.dispose();
  }

  @override
  void select(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {
    if (!mounted) return;
    // `select` also runs to refresh identity on the CURRENT tab (system back,
    // the back-swipe, a deep link re-entering the shell). Reporting those would
    // inflate the calendar in particular, since it is every one of those paths'
    // destination.
    final isTabChange = tab != _current;
    setState(() {
      _isAdmin = isAdmin;
      if (employeeId.isNotEmpty) _employeeId = employeeId;
      if (userName.isNotEmpty) _userName = userName;
      if (userEmail.isNotEmpty) _userEmail = userEmail;
      _current = tab;
      _built.add(tab);
    });
    if (isTabChange) _logTabView(tab);
  }

  @override
  void selectAndReveal(
    HubTab tab, {
    required bool isAdmin,
    required String employeeId,
    String userName = '',
    String userEmail = '',
  }) {
    select(
      tab,
      isAdmin: isAdmin,
      employeeId: employeeId,
      userName: userName,
      userEmail: userEmail,
    );
    _popToShell();
  }

  @override
  void goHome() {
    showCalendar();
    _popToShell();
  }

  /// Select before pop, so the revealed shell is already on the target tab —
  /// no flash of the previous one.
  void _popToShell() {
    if (!mounted) return;
    final navigator = Navigator.maybeOf(context);
    if (navigator == null) return;
    final shellRoute = _shellRoute;
    // Never popUntil(isFirst): on _hubRoute's fallback branch the shell is
    // not route #1, so that predicate pops the shell itself. A null capture
    // happens only in a bare harness, where the shell IS first.
    navigator.popUntil(
      shellRoute != null
          ? (route) => route == shellRoute
          : (route) => route.isFirst,
    );
  }

  /// Switch to calendar, preserving identity for deep-linked appointment sheets.
  @override
  void showCalendar() {
    select(
      HubTab.calendar,
      isAdmin: _isAdmin,
      employeeId: _employeeId,
    );
  }

  void _handlePop(bool didPop, Object? result) {
    if (didPop) return;
    // System back on non-calendar tab → calendar (like the app bar).
    select(
      HubTab.calendar,
      isAdmin: _isAdmin,
      employeeId: _employeeId,
    );
  }

  // iOS left-edge swipe for non-calendar tabs (no pushed route in IndexedStack).
  static const double _kBackSwipeEdge = 24;
  static const double _kBackSwipeMinVelocity = 250;
  bool _backSwipeArmed = false;
  double _backSwipeDx = 0;

  Widget _withBackSwipe(Widget child) {
    return GestureDetector(
      // Translucent to pass vertical drags to tab scrollables.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        _backSwipeArmed = details.globalPosition.dx <= _kBackSwipeEdge;
        _backSwipeDx = 0;
      },
      onHorizontalDragUpdate: (details) {
        if (_backSwipeArmed) _backSwipeDx += details.delta.dx;
      },
      onHorizontalDragEnd: (details) {
        if (!_backSwipeArmed) return;
        _backSwipeArmed = false;
        final width = MediaQuery.of(context).size.width;
        final velocity = details.primaryVelocity ?? 0;
        // Rightward fling or drag > 1/3 width → back.
        if (velocity > _kBackSwipeMinVelocity || _backSwipeDx > width * 0.35) {
          showCalendar();
        }
      },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    _refreshScreenCache();
    return HubShellScope(
      shell: this,
      current: _current,
      child: PopScope(
        canPop: _current == HubTab.calendar,
        onPopInvokedWithResult: _handlePop,
        child: IndexedStack(
          index: _current.index,
          children: [
            for (final destination in HubTab.values)
              if (_built.contains(destination))
                // Mute animations on hidden tabs, and pin viewInsets so they
                // don't cause rebuild churn while hidden.
                TickerMode(
                  enabled: destination == _current,
                  child: _TabViewInsets(
                    active: destination == _current,
                    // Each tab needs its own PrimaryScrollController.
                    child: PrimaryScrollScope(
                      // Fade in new tabs, unless reduced motion is on — then
                      // just swap instantly.
                      child: AnimatedOpacity(
                        opacity: destination == _current ? 1 : 0,
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : AppMotion.tabSwitch,
                        curve: Curves.easeInOut,
                        // iOS edge-swipe for non-calendar tabs (calendar owns week-swipe).
                        child:
                            destination == HubTab.calendar ||
                                !context.isCupertino
                            ? _cachedScreenFor(destination)
                            : _withBackSwipe(_cachedScreenFor(destination)),
                      ),
                    ),
                  ),
                )
              else
                const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  /// Caches screens so unchanged tabs skip a rebuild — cleared whenever
  /// identity changes.
  final Map<HubTab, Widget> _screenCache = {};
  ({bool isAdmin, String employeeId, String userName, String userEmail})?
  _screenCacheIdentity;

  /// Clear cache when identity args change (structural compare).
  void _refreshScreenCache() {
    final identity = (
      isAdmin: _isAdmin,
      employeeId: _employeeId,
      userName: _userName,
      userEmail: _userEmail,
    );
    if (identity != _screenCacheIdentity) {
      _screenCache.clear();
      _screenCacheIdentity = identity;
    }
  }

  Widget _cachedScreenFor(HubTab tab) =>
      _screenCache.putIfAbsent(tab, () => _screenFor(tab));

  Widget _screenFor(HubTab tab) {
    final builder = widget.screenBuilder;
    if (builder != null) return builder(tab);
    // Key on identity so in-place changes (e.g. admin upgrade) rebuild the screen.
    final key = ValueKey('hub-${tab.name}-$_isAdmin-$_employeeId');
    return switch (tab) {
      HubTab.calendar => MainCalendar(
        key: key,
        isAdmin: _isAdmin,
        employeeId: _employeeId,
      ),
      HubTab.clients => ListInformation(
        key: key,
        isAdmin: _isAdmin,
        employeeId: _employeeId,
      ),
      HubTab.employees => AddEmployeePage(
        key: key,
        isAdmin: _isAdmin,
        employeeId: _employeeId,
      ),
      HubTab.liveMap => LiveMapScreen(
        key: key,
        isAdmin: _isAdmin,
        employeeId: _employeeId,
      ),
    };
  }
}

/// Pins hidden tab viewInsets to zero so hidden tabs don't cause rebuild
/// churn. This widget stays mounted whether its tab is active or not.
class _TabViewInsets extends StatelessWidget {
  const _TabViewInsets({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: active ? data : data.copyWith(viewInsets: EdgeInsets.zero),
      child: child,
    );
  }
}

/// Redirect named hub-route pushes into tab switches on the live HubShell.
class HubTabRedirectRoute extends PageRouteBuilder<void> {
  HubTabRedirectRoute({
    required RouteSettings settings,
    required this.destination,
    required this.isAdmin,
    required this.employeeId,
    this.userName = '',
    this.userEmail = '',
  }) : super(
         settings: settings,
         opaque: false,
         transitionDuration: Duration.zero,
         reverseTransitionDuration: Duration.zero,
         pageBuilder: (_, _, _) => const SizedBox.shrink(),
       );

  final HubTab destination;
  final bool isAdmin;
  final String employeeId;
  final String userName;
  final String userEmail;

  @override
  TickerFuture didPush() {
    final ticker = super.didPush();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = navigator;
      if (nav == null || !isActive) return;
      final shell = HubShellState._live;
      if (shell != null && shell.mounted) {
        shell.select(
          destination,
          isAdmin: isAdmin,
          employeeId: employeeId,
          userName: userName,
          userEmail: userEmail,
        );
        nav.removeRoute(this);
      } else {
        nav.replace<void>(
          oldRoute: this,
          newRoute: MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => HubShell(
              initialTab: destination,
              isAdmin: isAdmin,
              employeeId: employeeId,
              userName: userName,
              userEmail: userEmail,
            ),
          ),
        );
      }
    });
    return ticker;
  }
}
