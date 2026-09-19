import 'package:flutter/foundation.dart';
import 'package:scheduling/core/navigation/app_destination.dart';

/// Anything that can own a feature tour. Sealed so `tourStepsFor` stays
/// exhaustive — a new scope is a compile error, not a silently tour-less
/// surface.
@immutable
sealed class TourScope {
  const TourScope();

  /// The persisted SharedPreferences entry AND the showcaseview scope name.
  ///
  /// A destination's key is its bare `.name`, which is exactly what devices
  /// already hold under `tour_seen_tabs` — prefixing it would replay every
  /// tour on every installed device.
  String get storageKey;

  @override
  bool operator ==(Object other) =>
      other is TourScope && other.storageKey == storageKey;

  @override
  int get hashCode => storageKey.hashCode;
}

/// A whole screen — a hub tab or a pushed route.
class DestinationTour extends TourScope {
  const DestinationTour(this.destination);

  final AppDestination destination;

  @override
  String get storageKey => destination.name;
}

/// A modal sheet that carries a walkthrough. The `sheet_` prefix namespaces it
/// away from destination keys, which are bare names.
class FormTour extends TourScope {
  const FormTour(this.form);

  final TourForm form;

  @override
  String get storageKey => 'sheet_${form.name}';
}

/// The sheets that carry a walkthrough — the three create flows, plus the
/// job-details sheet. `.name` is persisted, so renaming a member replays or
/// orphans that tour.
enum TourForm { addAppointment, addClient, invitePerson, jobDetails }

/// Not `const` — a collection-`for` isn't a constant expression, even over
/// the const `allDestinations`.
final List<TourScope> allTourScopes = [
  for (final destination in allDestinations) DestinationTour(destination),
  for (final form in TourForm.values) FormTour(form),
];
