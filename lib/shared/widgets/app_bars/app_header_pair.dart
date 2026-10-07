import 'package:flutter/material.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/ghost_control.dart';

/// The standard right-hand header controls: a Calendar pill that returns
/// home from anywhere, and the hamburger that opens the nav drawer.
/// Goes in `AppTopBar.actions` for uniformity — `AppTopBar` is no longer an
/// `AppBar`, so there is no implicit [EndDrawerButton] left to suppress.
class AppHeaderPair extends StatelessWidget {
  const AppHeaderPair({super.key, this.showCalendarPill = true});

  /// False on the calendar itself: a go-home pill on the screen it goes home
  /// to is dead weight. Every other screen keeps it.
  final bool showCalendarPill;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      // Flexible so the pill's label ellipsises rather than overflowing the
      // row on a narrow viewport at large text.
      if (showCalendarPill) ...const [
        Flexible(child: _CalendarPill()),
        SizedBox(width: 6),
      ],
      const _MenuButton(),
    ],
  );
}

class _CalendarPill extends StatelessWidget {
  const _CalendarPill();

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.nav_goToCalendar;
    return GhostControl.pill(
      onTap: () => goHomeToCalendar(context),
      label: label,
      tooltip: label,
      icon: Icons.calendar_today_rounded,
      iconColor: Theme.of(context).colorScheme.primary,
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton();

  @override
  Widget build(BuildContext context) => GhostControl.icon(
    // Scaffold.of resolves from the enclosing screen's Scaffold, so no call
    // site needs a GlobalKey<ScaffoldState>.
    onTap: () => Scaffold.of(context).openEndDrawer(),
    icon: Icons.menu_rounded,
    tooltip: context.l10n.nav_openMenu,
  );
}
