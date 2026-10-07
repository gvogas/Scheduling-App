import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/features/feature_tour/domain/tour_definitions.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';
import 'package:scheduling/features/feature_tour/domain/tour_step_id.dart';

/// Destinations that mount a FeatureTourHost.
const toured = <AppDestination>{
  HubTab.calendar,
  HubTab.clients,
  HubTab.employees,
  HubTab.liveMap,
  PushedDestination.history,
  PushedDestination.settings,
  PushedDestination.dashboard,
  PushedDestination.dayRoute,
};

/// The destinations an employee can actually reach — exactly the drawer rows
/// `drawerGroups(isAdmin: false)` offers.
const employeeToured = <AppDestination>{
  HubTab.calendar,
  PushedDestination.dayRoute,
  PushedDestination.history,
  PushedDestination.settings,
};

void main() {
  test(
    'employee tours exist only for the destinations employees can reach',
    () {
      for (final destination in allDestinations) {
        final steps = tourStepsFor(
          DestinationTour(destination),
          isAdmin: false,
        );
        if (employeeToured.contains(destination)) {
          expect(
            steps,
            isNotEmpty,
            reason: '$destination should have an employee tour',
          );
        } else {
          expect(steps, isEmpty, reason: '$destination is admin-only');
        }
      }
    },
  );

  test('employee calendar tour has no admin-only steps', () {
    final steps = tourStepsFor(
      const DestinationTour(HubTab.calendar),
      isAdmin: false,
    );
    expect(steps, isNot(contains(TourStepId.calendarAddAppointment)));
  });

  test('admin calendar tour showcases booking', () {
    final steps = tourStepsFor(
      const DestinationTour(HubTab.calendar),
      isAdmin: true,
    );
    expect(steps, contains(TourStepId.calendarAddAppointment));
  });

  test(
    'every toured destination has an admin tour and no catalog has duplicates',
    () {
      for (final destination in allDestinations) {
        final steps = tourStepsFor(DestinationTour(destination), isAdmin: true);
        if (toured.contains(destination)) {
          expect(
            steps,
            isNotEmpty,
            reason: '$destination should have an admin tour',
          );
        } else {
          expect(steps, isEmpty, reason: '$destination has no tour host');
        }
        expect(
          steps.toSet().length,
          steps.length,
          reason: '$destination catalog has duplicate steps',
        );
      }
    },
  );

  test('dashboard has a 4-step admin tour and none for employees', () {
    const scope = DestinationTour(PushedDestination.dashboard);
    expect(tourStepsFor(scope, isAdmin: true), hasLength(4));
    expect(tourStepsFor(scope, isAdmin: false), isEmpty);
  });

  test('day route tours both roles, with the picker admin-only', () {
    const scope = DestinationTour(PushedDestination.dayRoute);
    expect(tourStepsFor(scope, isAdmin: true), hasLength(4));
    final employee = tourStepsFor(scope, isAdmin: false);
    expect(employee, hasLength(3));
    expect(employee, isNot(contains(TourStepId.dayRouteEmployee)));
  });

  test('the gap-filled catalogs grew to their new lengths', () {
    int len(AppDestination d) =>
        tourStepsFor(DestinationTour(d), isAdmin: true).length;
    // 7 since 1.57 added the week toggle and the crew filter.
    expect(len(HubTab.calendar), 7);
    // 5 since 1.58 toured the sort control 1.57 shipped untoured.
    expect(len(HubTab.clients), 5);
    expect(len(HubTab.employees), 3);
    expect(len(PushedDestination.history), 3);
  });

  test('the appointment walkthrough is admin-only and 7 steps in order', () {
    const scope = FormTour(TourForm.addAppointment);
    expect(tourStepsFor(scope, isAdmin: true), [
      TourStepId.apptTemplates,
      TourStepId.apptClient,
      // The job address moved out of Details into WHO, under the client.
      TourStepId.apptJobAddress,
      TourStepId.apptCrew,
      TourStepId.apptSchedule,
      TourStepId.apptDetails,
      TourStepId.apptSave,
    ]);
    expect(tourStepsFor(scope, isAdmin: false), isEmpty);
  });

  test('the client walkthrough is 4 steps in order', () {
    const scope = FormTour(TourForm.addClient);
    expect(tourStepsFor(scope, isAdmin: true), [
      TourStepId.clientWho,
      TourStepId.clientReach,
      TourStepId.clientSite,
      TourStepId.clientSave,
    ]);
  });

  test('the invite walkthrough is 4 steps in order', () {
    const scope = FormTour(TourForm.invitePerson);
    expect(tourStepsFor(scope, isAdmin: true), [
      TourStepId.personDetails,
      TourStepId.personJobTitle,
      TourStepId.personColour,
      TourStepId.personCreate,
    ]);
    expect(tourStepsFor(scope, isAdmin: false), isEmpty);
  });

  test('no catalog anywhere repeats a step', () {
    for (final scope in allTourScopes) {
      final steps = tourStepsFor(scope, isAdmin: true);
      expect(
        steps.toSet().length,
        steps.length,
        reason: '${scope.storageKey} catalog has duplicate steps',
      );
    }
  });

  test('the job details sheet has a tour for both roles', () {
    const scope = FormTour(TourForm.jobDetails);
    expect(tourStepsFor(scope, isAdmin: true), isNotEmpty);
    expect(tourStepsFor(scope, isAdmin: false), isNotEmpty);
  });

  test('the job details tour splits by what each role may do', () {
    const scope = FormTour(TourForm.jobDetails);
    final admin = tourStepsFor(scope, isAdmin: true);
    final crew = tourStepsFor(scope, isAdmin: false);
    // Push back and book again are the admin's.
    expect(admin, contains(TourStepId.jobPushBack));
    expect(admin, contains(TourStepId.jobBookAgain));
    expect(crew, isNot(contains(TourStepId.jobPushBack)));
    expect(crew, isNot(contains(TourStepId.jobBookAgain)));
    // The field record is offered to a non-admin assignee only.
    expect(crew, contains(TourStepId.jobFieldRecord));
    expect(admin, isNot(contains(TourStepId.jobFieldRecord)));
    // Starting and closing a job belong to both.
    expect(admin, contains(TourStepId.jobStart));
    expect(crew, contains(TourStepId.jobStart));
    expect(admin, contains(TourStepId.jobMarkDone));
    expect(crew, contains(TourStepId.jobMarkDone));
  });

  test('the three create-flow sheets stay admin-only', () {
    const createFlows = [
      TourForm.addAppointment,
      TourForm.addClient,
      TourForm.invitePerson,
    ];
    for (final form in createFlows) {
      expect(
        tourStepsFor(FormTour(form), isAdmin: false),
        isEmpty,
        reason: '$form is admin-only',
      );
    }
  });

  test('the calendar week toggle is offered to both roles', () {
    expect(
      tourStepsFor(const DestinationTour(HubTab.calendar), isAdmin: false),
      contains(TourStepId.calendarWeekToggle),
    );
    expect(
      tourStepsFor(const DestinationTour(HubTab.calendar), isAdmin: true),
      contains(TourStepId.calendarWeekToggle),
    );
  });

  test('the crew filter is admin-only', () {
    expect(
      tourStepsFor(const DestinationTour(HubTab.calendar), isAdmin: false),
      isNot(contains(TourStepId.calendarCrewFilter)),
    );
  });

  test('every step id belongs to some catalog', () {
    final owned = <TourStepId>{};
    for (final scope in allTourScopes) {
      for (final isAdmin in [true, false]) {
        owned.addAll(tourStepsFor(scope, isAdmin: isAdmin));
      }
    }
    // A step in no catalog is copy nobody can ever see.
    expect(
      TourStepId.values.where((id) => !owned.contains(id)),
      isEmpty,
      reason: 'these ids are in no catalog',
    );
  });
  test(
    'the live map tour explains who is missing between its two controls',
    () {
      const scope = DestinationTour(HubTab.liveMap);
      expect(tourStepsFor(scope, isAdmin: true), [
        TourStepId.liveMapRoster,
        TourStepId.liveMapNotOnMap,
        TourStepId.liveMapRecenter,
      ]);
    },
  );
}
