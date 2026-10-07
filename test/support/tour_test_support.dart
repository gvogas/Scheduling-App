import 'package:scheduling/features/feature_tour/domain/tour_definitions.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Marks every sheet walkthrough as already seen.
///
/// A sheet's tour gates on `ModalRoute.isCurrent`, which is true the moment a
/// test pumps the sheet — so on a fresh-install preferences store the tour
/// starts, and showcaseview's tooltip animation repeats forever, which makes
/// `pumpAndSettle` time out. A hub tab can't hit this (a standalone screen has
/// no `HubShellScope`, so it never starts).
///
/// Call this from any test that pumps `AddEventSheet`, `AddClientSheet`,
/// `InvitePersonSheet` or the job-details sheet and isn't testing the tour
/// itself. It represents someone who has already been through the
/// walkthrough, which is the ordinary case.
///
/// Derived from the live catalogs across BOTH roles, so a step added to a
/// sheet can't hang a suite that never mentions the tour.
///
/// Pass [extra] to keep other preferences the test relies on.
void markFormToursSeen({Map<String, Object> extra = const {}}) {
  final seen = <TourStepId>{
    for (final form in TourForm.values)
      for (final isAdmin in [true, false])
        ...tourStepsFor(FormTour(form), isAdmin: isAdmin),
  };
  SharedPreferences.setMockInitialValues({
    ...extra,
    'tour_seen_steps': [for (final id in seen) id.name],
  });
}

/// Marks every tour step seen, screen tours included, for tests that pump a
/// tour-hosting screen (Dashboard, Settings) and aren't testing the tour.
void markAllToursSeen() {
  SharedPreferences.setMockInitialValues({
    'tour_seen_steps': [for (final id in TourStepId.values) id.name],
  });
}
