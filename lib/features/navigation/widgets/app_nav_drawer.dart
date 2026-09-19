import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/navigation/hub_shell_scope.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/application/overdue_review_providers.dart';
import 'package:scheduling/features/calendar/domain/appointment_day_slice.dart';
import 'package:scheduling/features/employees/application/employee_schedule_providers.dart';
import 'package:scheduling/features/navigation/domain/drawer_catalog.dart';
import 'package:scheduling/features/presence/application/live_map_providers.dart';
import 'package:scheduling/features/presence/domain/live_map_aggregator.dart';
import 'package:scheduling/features/settings/application/app_info_provider.dart';
import 'package:scheduling/features/settings/domain/role_label.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/branding/brand_logo.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';

const double _kDrawerWidth = 284;

/// The right-anchored navigation drawer - the app's only nav surface at
/// every screen size. Rows are grouped by when you would reach for them.
///
/// A closed drawer's child is never built (`_DrawerControllerState`
/// short-circuits to `SizedBox.shrink()` while dismissed), so the count
/// providers watched below subscribe only while it is open. Do not add an
/// "is open" flag to work around a cost that does not exist.
class AppNavDrawer extends ConsumerWidget {
  const AppNavDrawer({
    required this.isAdmin,
    required this.employeeId,
    super.key,
    this.userName,
    this.email,
  });

  final bool isAdmin;
  final String employeeId;
  final String? userName;
  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    // The route argument is a push-time SNAPSHOT, so the admin rows ask
    // Firestore too. Fails CLOSED while the user doc is unsettled, and is
    // resolved ONCE so the rows, the header and the counts agree.
    final isLiveAdmin = isAdmin && ref.watch(isActiveAdminProvider);
    final groups = drawerGroups(isAdmin: isLiveAdmin);

    // The shadow wraps the drawer from OUTSIDE. A BoxShadow is painted from the
    // edges of its own box and its blur reaches inward as well as outward, so a
    // decoration placed inside the drawer paints a dark 44px haze across the
    // drawer's own surface, above the background and below the rows: invisible
    // against the dark theme, a grey fog over the light one (fixed 2026-07-31).
    return DecoratedBox(
      decoration: BoxDecoration(boxShadow: theme.cardStyle.drawerShadow),
      child: Drawer(
        width: _kDrawerWidth,
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(isAdmin: isLiveAdmin, userName: userName),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
                children: [
                  for (final (index, group) in groups.indexed) ...[
                    if (index > 0) const SizedBox(height: AppSpacing.sp16),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(13, 0, 13, 7),
                      child: Text(
                        group.title(l10n),
                        style: theme.monoType.groupLabel.copyWith(
                          color: theme.palette.textMuted,
                        ),
                      ),
                    ),
                    for (final destination in group.rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _NavRow(
                          destination: destination,
                          isAdmin: isLiveAdmin,
                          employeeId: employeeId,
                          userName: userName,
                          email: email,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const _VersionFooter(),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.isAdmin, this.userName});

  final bool isAdmin;
  final String? userName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Both derive from the app-wide currentUserDocProvider, so no new stream.
    final docName = ref.watch(currentUserNameProvider);
    final displayName = (userName?.isNotEmpty ?? false)
        ? userName!
        : (docName.isNotEmpty
              ? docName
              : (FirebaseAuth.instance.currentUser?.displayName ?? ''));

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Row(
            children: [
              AppAvatar(name: displayName, size: AvatarSize.lg),
              const SizedBox(width: AppSpacing.sp12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName.isNotEmpty ? displayName : ' ',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kFontSans,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    Text(
                      // brandName is a proper noun and stays in English.
                      '${roleLabel(context.l10n, isAdmin: isAdmin)} · '
                      '$brandName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: kFontSans,
                        fontSize: 12,
                        color: theme.palette.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavRow extends ConsumerWidget {
  const _NavRow({
    required this.destination,
    required this.isAdmin,
    required this.employeeId,
    this.userName,
    this.email,
  });

  final AppDestination destination;
  final bool isAdmin;
  final String employeeId;
  final String? userName;
  final String? email;

  bool _isActive(BuildContext context) => switch (destination) {
    final HubTab tab => HubShellScope.readCurrentOf(context) == tab,
    final PushedDestination pushed =>
      ModalRoute.settingsOf(context)?.name ==
          destinationRoute(
            pushed,
            isAdmin: isAdmin,
            employeeId: employeeId,
          ).route,
  };

  void _go(BuildContext context) {
    Scaffold.of(context).closeEndDrawer();
    // Calendar routes through goHome so it also collapses any pushed stack -
    // no screen is a dead end.
    if (destination == HubTab.calendar) {
      goHomeToCalendar(context);
      return;
    }
    navigateToDestination(
      context,
      destination,
      isAdmin: isAdmin,
      employeeId: employeeId,
      userName: userName ?? '',
      userEmail: email ?? '',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isActive = _isActive(context);
    final count = _countFor(ref);
    // The stored hue lifted for the current theme - never paint the raw value.
    final tint = crewColorOf(theme, drawerDotColor(destination).toARGB32());

    return Material(
      color: isActive ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.rRow),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _go(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            // sp8, not sp12: the 28px chip plus 2x12 would make the row 52
            // and grow the whole drawer. At sp8 the chip sits inside the
            // 48px minimum above, so the row height is unchanged.
            padding: const EdgeInsets.symmetric(
              horizontal: 13,
              vertical: AppSpacing.sp8,
            ),
            child: Row(
              children: [
                // The tinted icon chip InfoCardRow already uses, at 28 rather
                // than 34 to sit inside the row's 48px minimum. The icon is
                // what identifies the row; the tint is decoration, so colour
                // is never the only cue.
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: tint.withValues(
                      alpha: theme.cardStyle.iconChipAlpha,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.r8),
                  ),
                  child: Icon(
                    drawerRowIcon(destination),
                    size: 16,
                    color: tint,
                  ),
                ),
                const SizedBox(width: AppSpacing.sp12),
                Expanded(
                  child: Text(
                    drawerRowLabel(context.l10n, destination),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kFontSans,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: isActive
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                // An absent count renders nothing - the empty-omitted rule.
                if (count != null) ...[
                  const SizedBox(width: AppSpacing.sp8),
                  Text(
                    '$count',
                    style: drawerCountIsAlert(destination)
                        ? theme.monoType.data.copyWith(
                            color: theme.statusColors.overdue,
                          )
                        : theme.monoType.data,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The rows that carry a live count.
  int? _countFor(WidgetRef ref) => switch (destination) {
    HubTab.calendar => _todayJobCount(ref),
    HubTab.liveMap => _onTheClockCount(ref),
    PushedDestination.overdueReview =>
      ref.watch(overdueOpenJobsProvider).value?.length,
    _ => null,
  };

  int? _todayJobCount(WidgetRef ref) {
    // todayRangeProvider, not a local range: it re-derives at midnight off
    // currentDayProvider, and sharing its value means sharing the Firestore
    // listener the Team tab already holds open rather than forking a second.
    final range = ref.watch(todayRangeProvider);
    final jobs = isAdmin
        ? ref.watch(appointmentsInRangeProvider(range))
        : ref.watch(
            myAppointmentsProvider((employeeId: employeeId, range: range)),
          );
    final today = jobs.value;
    if (today == null) return null;
    // Re-scoped through the shared predicate: the range stream is a 14-day
    // superset (see runsOn), and cancelled visits and time off are not load.
    // Shared with employeeJobsTodayProvider rather than restated here.
    return today.where((j) => countsAsLoadOn(j, range.start)).length;
  }

  int? _onTheClockCount(WidgetRef ref) {
    final points = ref.watch(liveMapPointsProvider).value;
    if (points == null) return null;
    ref.watch(liveMapTickProvider); // recompute every 30 s
    final now = ref.watch(liveMapClockProvider)();
    return points
        .where((p) => !LiveMapAggregator.isStale(p.updatedAt, now))
        .length;
  }
}

class _VersionFooter extends ConsumerWidget {
  const _VersionFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final info = ref.watch(appInfoProvider).value;
    if (info == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(25, 0, 25, 12),
        child: Text(
          'v${info.version} (${info.buildNumber})',
          style: theme.monoType.micro.copyWith(color: theme.palette.textFaint),
        ),
      ),
    );
  }
}
