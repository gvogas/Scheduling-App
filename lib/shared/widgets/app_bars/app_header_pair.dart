import 'package:flutter/material.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Minimum tap target. The painted boxes below are deliberately smaller —
/// the design's 38px/36px are *visual* sizes, never hit areas.
const double _kTapTarget = 48;

/// The standard right-hand header controls: a Calendar pill that returns
/// home from anywhere, and the hamburger that opens the nav drawer.
/// Goes in `AppTopBar.actions`, which also suppresses Flutter's automatic
/// [EndDrawerButton] — this pair is its replacement.
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: context.l10n.nav_goToCalendar,
      child: ConstrainedBox(
        // Height derives from the scaled label; 48 is the floor, not the size.
        constraints: const BoxConstraints(minHeight: _kTapTarget),
        child: Center(
          child: Material(
            color: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.rFull),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => goHomeToCalendar(context),
              highlightColor: theme.palette.blueTintPressed,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 38),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(11, 8, 13, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.calendar_today_rounded,
                        size: 15,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: AppSpacing.sp8),
                      Flexible(
                        child: Text(
                          context.l10n.nav_goToCalendar,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kFontSans,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: context.l10n.nav_openMenu,
      child: SizedBox(
        width: _kTapTarget,
        height: _kTapTarget,
        child: Center(
          child: Material(
            color: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.rFull),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // Scaffold.of resolves from the enclosing screen's Scaffold, so
              // no call site needs a GlobalKey<ScaffoldState>.
              onTap: () => Scaffold.of(context).openEndDrawer(),
              highlightColor: theme.palette.blueTintPressed,
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  Icons.menu_rounded,
                  size: 19,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
