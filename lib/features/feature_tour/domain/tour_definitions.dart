import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';

/// Ordered step catalog for a scope and role.
List<TourStepId> tourStepsFor(TourScope scope, {required bool isAdmin}) =>
    switch (scope) {
      DestinationTour(:final destination) => _destinationSteps(
        destination,
        isAdmin: isAdmin,
      ),
      FormTour(:final form) => _formSteps(form, isAdmin: isAdmin),
    };

List<TourStepId> _destinationSteps(
  AppDestination destination, {
  required bool isAdmin,
}) => switch (destination) {
  HubTab.calendar => [
    TourStepId.calendarGrid,
    TourStepId.calendarDayList,
    TourStepId.calendarWeekToggle,
    // Portrait only — the handle doesn't exist in the split layout, so
    // isTargetRendered drops this step there.
    TourStepId.calendarCollapse,
    if (isAdmin) TourStepId.calendarCrewFilter,
    if (isAdmin) TourStepId.calendarAddAppointment,
    TourStepId.calendarDayRoute,
  ],
  HubTab.clients => [
    if (isAdmin) ...[
      TourStepId.clientsSearch,
      TourStepId.clientsFilter,
      TourStepId.clientsSort,
      TourStepId.clientsAdd,
      TourStepId.clientsRow,
    ],
  ],
  HubTab.employees => [
    if (isAdmin) ...[
      TourStepId.employeesSearch,
      TourStepId.employeesAdd,
      TourStepId.employeesRow,
    ],
  ],
  // Not admin-gated: a technician reaches History too (their own jobs), and the
  // three targets — search bar, filter row, first row — render for them.
  PushedDestination.history => [
    TourStepId.historySearch,
    TourStepId.historyFilter,
    TourStepId.historyRow,
  ],
  HubTab.liveMap => [
    if (isAdmin) ...[TourStepId.liveMapRoster, TourStepId.liveMapRecenter],
  ],
  PushedDestination.settings => [
    TourStepId.settingsAppearance,
    TourStepId.settingsNotifications,
    TourStepId.settingsLocationSharing,
    TourStepId.settingsReplay,
  ],
  // Employees reach the day route too, so this catalog isn't admin-gated — only
  // the picker step is, since an employee sees just their own route.
  PushedDestination.dayRoute => [
    TourStepId.dayRouteDaySwitcher,
    if (isAdmin) TourStepId.dayRouteEmployee,
    TourStepId.dayRouteStops,
    TourStepId.dayRouteNavigate,
  ],
  // No walkthrough: the review is one list and one action bar.
  PushedDestination.overdueReview => const [],
  PushedDestination.dashboard => [
    if (isAdmin) ...[
      TourStepId.dashboardHero,
      TourStepId.dashboardUpcoming,
      TourStepId.dashboardWorkload,
      TourStepId.dashboardAttention,
    ],
  ],
};

/// The sheet walkthroughs.
List<TourStepId> _formSteps(TourForm form, {required bool isAdmin}) {
  // Every sheet but the job details is admin-only, and that one has its own
  // per-step gating below.
  if (!isAdmin && form != TourForm.jobDetails) return const [];
  return switch (form) {
    TourForm.addAppointment => [
      TourStepId.apptTemplates,
      TourStepId.apptClient,
      TourStepId.apptJobAddress,
      TourStepId.apptCrew,
      TourStepId.apptSchedule,
      TourStepId.apptDetails,
      TourStepId.apptSave,
    ],
    TourForm.addClient => [
      TourStepId.clientWho,
      TourStepId.clientReach,
      TourStepId.clientSite,
      TourStepId.clientSave,
    ],
    TourForm.invitePerson => [
      TourStepId.personDetails,
      TourStepId.personJobTitle,
      TourStepId.personColour,
      TourStepId.personCreate,
    ],
    // The sheet's own visual order: push back sits in the client block, the
    // field record above the action bar, the bar's buttons last. The field
    // record goes to a non-admin ASSIGNEE only — exactly the set the crew
    // branches of firestore.rules admit.
    TourForm.jobDetails => [
      if (isAdmin) TourStepId.jobPushBack,
      if (!isAdmin) TourStepId.jobFieldRecord,
      TourStepId.jobStart,
      TourStepId.jobMarkDone,
      if (isAdmin) TourStepId.jobBookAgain,
    ],
  };
}
