import 'package:flutter/material.dart' show Color, IconData, Icons;

import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/l10n/l10n.dart';

/// One labelled block of drawer rows.
typedef DrawerGroup = ({
  String Function(AppLocalizations) title,
  List<AppDestination> rows,
});

/// Grouped drawer rows for a role, grouped by WHEN you would reach for them,
/// not by object type.
List<DrawerGroup> drawerGroups({required bool isAdmin}) => [
  (
    title: (l10n) => l10n.nav_groupToday,
    rows: [
      HubTab.calendar,
      PushedDestination.dayRoute,
      // History is admin-only (2026-09-06). An employee's copy carried no
      // filter control of any kind, and a technician still reaches a finished
      // job through the calendar's closed-job sink.
      if (isAdmin) HubTab.liveMap,
    ],
  ),
  if (isAdmin)
    (
      title: (l10n) => l10n.nav_groupPeople,
      rows: [HubTab.employees, HubTab.clients],
    ),
  if (isAdmin)
    (
      title: (l10n) => l10n.nav_groupBusiness,
      rows: [
        PushedDestination.dashboard,
        PushedDestination.history,
        PushedDestination.overdueReview,
      ],
    ),
  (
    title: (l10n) => l10n.nav_groupAccount,
    // My details is NOT a drawer row: P5 landed it inside Settings, which is
    // where its two grants (own emergency contact, self-service availability)
    // sit beside the rest of a person's own preferences.
    rows: [PushedDestination.settings],
  ),
];

/// Localized row label. Kept out of [AppDestination] so the destination enum
/// stays presentation-free.
String drawerRowLabel(AppLocalizations l10n, AppDestination destination) =>
    switch (destination) {
      HubTab.calendar => l10n.common_calendar,
      HubTab.clients => l10n.common_clients,
      HubTab.employees => l10n.nav_team,
      HubTab.liveMap => l10n.common_liveMap,
      PushedDestination.dayRoute => l10n.nav_dayRoute,
      PushedDestination.history => l10n.common_history,
      PushedDestination.overdueReview => l10n.nav_overdueReview,
      PushedDestination.dashboard => l10n.nav_dashboard,
      PushedDestination.settings => l10n.common_settings,
    };

/// The row's icon. Seven of these are the icons the pre-redesign drawer used
/// before P1 replaced them with bare colour squares; `dayRoute` is the one row
/// that had no predecessor.
IconData drawerRowIcon(AppDestination destination) => switch (destination) {
  HubTab.calendar => Icons.calendar_today_rounded,
  PushedDestination.dayRoute => Icons.route_rounded,
  HubTab.liveMap => Icons.map_rounded,
  HubTab.employees => Icons.badge_rounded,
  HubTab.clients => Icons.people_rounded,
  PushedDestination.dashboard => Icons.insights_rounded,
  PushedDestination.history => Icons.history_rounded,
  PushedDestination.overdueReview => Icons.assignment_late_rounded,
  PushedDestination.settings => Icons.settings_rounded,
};

/// The row's colour. These are crew-palette hues used as decoration, so a call
/// site must resolve them through `crewColorOf` to get the dark lift — never
/// paint the stored value directly.
Color drawerDotColor(AppDestination destination) => switch (destination) {
  HubTab.calendar => AppColors.navCalendar,
  PushedDestination.dayRoute => AppColors.navDayRoute,
  HubTab.liveMap => AppColors.navLiveMap,
  HubTab.employees => AppColors.navTeam,
  HubTab.clients => AppColors.navClients,
  PushedDestination.dashboard => AppColors.navDashboard,
  PushedDestination.history => AppColors.navHistory,
  PushedDestination.overdueReview => AppColors.navOverdueReview,
  PushedDestination.settings => AppColors.navSettings,
};

/// Whether a row's live count is a warning, painted in the overdue colour.
bool drawerCountIsAlert(AppDestination destination) =>
    destination == PushedDestination.overdueReview;
