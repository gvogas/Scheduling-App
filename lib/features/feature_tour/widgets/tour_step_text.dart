import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Localized title + description for a tour step.
({String title, String description}) tourStepText(
  AppLocalizations l,
  TourStepId id,
) => switch (id) {
  TourStepId.calendarGrid => (
    title: l.tour_calendarGridTitle,
    description: l.tour_calendarGridDesc,
  ),
  TourStepId.calendarDayList => (
    title: l.tour_calendarDayListTitle,
    description: l.tour_calendarDayListDesc,
  ),
  TourStepId.calendarAddAppointment => (
    title: l.tour_calendarAddTitle,
    description: l.tour_calendarAddDesc,
  ),
  TourStepId.calendarDayRoute => (
    title: l.tour_calendarDayRouteTitle,
    description: l.tour_calendarDayRouteDesc,
  ),
  TourStepId.calendarCollapse => (
    title: l.tour_calendarCollapseTitle,
    description: l.tour_calendarCollapseDesc,
  ),
  TourStepId.clientsSearch => (
    title: l.tour_clientsSearchTitle,
    description: l.tour_clientsSearchDesc,
  ),
  TourStepId.clientsFilter => (
    title: l.tour_clientsFilterTitle,
    description: l.tour_clientsFilterDesc,
  ),
  TourStepId.clientsSort => (
    title: l.tour_clientsSortTitle,
    description: l.tour_clientsSortDesc,
  ),
  TourStepId.clientsRow => (
    title: l.tour_clientsRowTitle,
    description: l.tour_clientsRowDesc,
  ),
  TourStepId.clientsAdd => (
    title: l.tour_clientsAddTitle,
    description: l.tour_clientsAddDesc,
  ),
  TourStepId.employeesSearch => (
    title: l.tour_employeesSearchTitle,
    description: l.tour_employeesSearchDesc,
  ),
  TourStepId.employeesAdd => (
    title: l.tour_employeesAddTitle,
    description: l.tour_employeesAddDesc,
  ),
  TourStepId.employeesRow => (
    title: l.tour_employeesRowTitle,
    description: l.tour_employeesRowDesc,
  ),
  TourStepId.historySearch => (
    title: l.tour_historySearchTitle,
    description: l.tour_historySearchDesc,
  ),
  TourStepId.historyFilter => (
    title: l.tour_historyFilterTitle,
    description: l.tour_historyFilterDesc,
  ),
  TourStepId.historyRow => (
    title: l.tour_historyRowTitle,
    description: l.tour_historyRowDesc,
  ),
  TourStepId.liveMapRoster => (
    title: l.tour_liveMapRosterTitle,
    description: l.tour_liveMapRosterDesc,
  ),
  TourStepId.liveMapNotOnMap => (
    title: l.tour_liveMapNotOnMapTitle,
    description: l.tour_liveMapNotOnMapDesc,
  ),
  TourStepId.liveMapRecenter => (
    title: l.tour_liveMapRecenterTitle,
    description: l.tour_liveMapRecenterDesc,
  ),
  TourStepId.settingsAppearance => (
    title: l.tour_settingsAppearanceTitle,
    description: l.tour_settingsAppearanceDesc,
  ),
  TourStepId.settingsNotifications => (
    title: l.tour_settingsNotificationsTitle,
    description: l.tour_settingsNotificationsDesc,
  ),
  TourStepId.settingsReplay => (
    title: l.tour_settingsReplayTitle,
    description: l.tour_settingsReplayDesc,
  ),
  TourStepId.dashboardHero => (
    title: l.tour_dashboardHeroTitle,
    description: l.tour_dashboardHeroDesc,
  ),
  TourStepId.dashboardUpcoming => (
    title: l.tour_dashboardUpcomingTitle,
    description: l.tour_dashboardUpcomingDesc,
  ),
  TourStepId.dashboardWorkload => (
    title: l.tour_dashboardWorkloadTitle,
    description: l.tour_dashboardWorkloadDesc,
  ),
  TourStepId.dashboardAttention => (
    title: l.tour_dashboardAttentionTitle,
    description: l.tour_dashboardAttentionDesc,
  ),
  TourStepId.dayRouteDaySwitcher => (
    title: l.tour_dayRouteDaySwitcherTitle,
    description: l.tour_dayRouteDaySwitcherDesc,
  ),
  TourStepId.dayRouteEmployee => (
    title: l.tour_dayRouteEmployeeTitle,
    description: l.tour_dayRouteEmployeeDesc,
  ),
  TourStepId.dayRouteStops => (
    title: l.tour_dayRouteStopsTitle,
    description: l.tour_dayRouteStopsDesc,
  ),
  TourStepId.dayRouteNavigate => (
    title: l.tour_dayRouteNavigateTitle,
    description: l.tour_dayRouteNavigateDesc,
  ),
  TourStepId.apptTemplates => (
    title: l.tour_apptTemplatesTitle,
    description: l.tour_apptTemplatesDesc,
  ),
  TourStepId.apptClient => (
    title: l.tour_apptClientTitle,
    description: l.tour_apptClientDesc,
  ),
  TourStepId.apptJobAddress => (
    title: l.tour_apptJobAddressTitle,
    description: l.tour_apptJobAddressDesc,
  ),
  TourStepId.apptCrew => (
    title: l.tour_apptCrewTitle,
    description: l.tour_apptCrewDesc,
  ),
  TourStepId.apptSchedule => (
    title: l.tour_apptScheduleTitle,
    description: l.tour_apptScheduleDesc,
  ),
  TourStepId.apptDetails => (
    title: l.tour_apptDetailsTitle,
    description: l.tour_apptDetailsDesc,
  ),
  TourStepId.apptSave => (
    title: l.tour_apptSaveTitle,
    description: l.tour_apptSaveDesc,
  ),
  TourStepId.clientWho => (
    title: l.tour_clientWhoTitle,
    description: l.tour_clientWhoDesc,
  ),
  TourStepId.clientReach => (
    title: l.tour_clientReachTitle,
    description: l.tour_clientReachDesc,
  ),
  TourStepId.clientSite => (
    title: l.tour_clientSiteTitle,
    description: l.tour_clientSiteDesc,
  ),
  TourStepId.clientSave => (
    title: l.tour_clientSaveTitle,
    description: l.tour_clientSaveDesc,
  ),
  TourStepId.personDetails => (
    title: l.tour_personDetailsTitle,
    description: l.tour_personDetailsDesc,
  ),
  TourStepId.personJobTitle => (
    title: l.tour_personJobTitleTitle,
    description: l.tour_personJobTitleDesc,
  ),
  TourStepId.personColour => (
    title: l.tour_personColourTitle,
    description: l.tour_personColourDesc,
  ),
  TourStepId.personCreate => (
    title: l.tour_personCreateTitle,
    description: l.tour_personCreateDesc,
  ),
  TourStepId.calendarWeekToggle => (
    title: l.tour_calendarWeekToggleTitle,
    description: l.tour_calendarWeekToggleDesc,
  ),
  TourStepId.calendarCrewFilter => (
    title: l.tour_calendarCrewFilterTitle,
    description: l.tour_calendarCrewFilterDesc,
  ),
  TourStepId.settingsLocationSharing => (
    title: l.tour_settingsLocationSharingTitle,
    description: l.tour_settingsLocationSharingDesc,
  ),
  TourStepId.jobPushBack => (
    title: l.tour_jobPushBackTitle,
    description: l.tour_jobPushBackDesc,
  ),
  TourStepId.jobFieldRecord => (
    title: l.tour_jobFieldRecordTitle,
    description: l.tour_jobFieldRecordDesc,
  ),
  TourStepId.jobStart => (
    title: l.tour_jobStartTitle,
    description: l.tour_jobStartDesc,
  ),
  TourStepId.jobMarkDone => (
    title: l.tour_jobMarkDoneTitle,
    description: l.tour_jobMarkDoneDesc,
  ),
  TourStepId.jobBookAgain => (
    title: l.tour_jobBookAgainTitle,
    description: l.tour_jobBookAgainDesc,
  ),
};
