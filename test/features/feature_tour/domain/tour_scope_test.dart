import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/navigation/app_destination.dart';
import 'package:scheduling/features/feature_tour/domain/tour_scope.dart';

void main() {
  test('a destination scope key is the bare destination name', () {
    // Load-bearing: devices already persisted these names under
    // tour_seen_tabs, so changing the key would replay every seen tour.
    expect(const DestinationTour(HubTab.calendar).storageKey, 'calendar');
    expect(
      const DestinationTour(PushedDestination.settings).storageKey,
      'settings',
    );
  });

  test('a form scope key is namespaced so it cannot collide', () {
    expect(
      const FormTour(TourForm.addAppointment).storageKey,
      'sheet_addAppointment',
    );
  });

  test('scopes with the same key are equal and share a hash', () {
    expect(
      const DestinationTour(HubTab.calendar),
      const DestinationTour(HubTab.calendar),
    );
    // Built from a list so the analyzer doesn't flag the deliberate duplicate.
    const pair = [
      DestinationTour(HubTab.calendar),
      DestinationTour(HubTab.calendar),
    ];
    expect(pair.toSet(), hasLength(1));
  });

  test('every scope key is unique', () {
    final keys = [for (final scope in allTourScopes) scope.storageKey];
    expect(keys.toSet().length, keys.length);
  });
}
