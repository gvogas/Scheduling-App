import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/maps/data/google_places_repository.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';

final placesRepositoryProvider = Provider<PlacesRepository>(
  (ref) => GooglePlacesRepository(),
);

/// Roster rows show only a city, so they key on a ~1.1 km cell.
const int kCoarseGeocodePrecision = 2;

/// Family key for [reverseGeocodeProvider]: a rounded cell plus the locale.
@immutable
class ReverseGeocodeQuery {
  ReverseGeocodeQuery({
    required double lat,
    required double lng,
    required this.locale,
    int decimals = 3,
  }) : lat = double.parse(lat.toStringAsFixed(decimals)),
       lng = double.parse(lng.toStringAsFixed(decimals));

  final double lat;
  final double lng;
  final String locale;

  @override
  bool operator ==(Object other) =>
      other is ReverseGeocodeQuery &&
      other.lat == lat &&
      other.lng == lng &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(lat, lng, locale);
}

/// How long a FAILED cell is held before it may be looked up again.
///
/// "Retries later" is the intent; this is what makes *later* real. It has to
/// outlast the roster's 30 s freshness tick (`liveMapTickProvider`), or a
/// rebuild still lands on an expired cell and the retry loop returns.
const Duration kReverseGeocodeFailureCooldown = Duration(minutes: 5);

/// Resolves the display address for a rounded lat/lng cell (see
/// [ReverseGeocodeQuery]). A successful lookup is kept alive for the session;
/// a failure is held for [kReverseGeocodeFailureCooldown] and then retried.
/// The widget should treat an [AsyncError] here as "no address available"
/// rather than a notice.
///
/// **A failure must be held, not merely re-thrown.** The live-map roster
/// watches this per ROW inside a `ListView.separated` builder, so scrolling
/// disposes off-screen rows and scrolling back re-creates them. Left plain
/// autoDispose, every recycle was a fresh BILLED geocode against a 120/hour
/// per-uid budget — and because the client abandons the callable at 10 s
/// while the function keeps running, an abandoned lookup still spent both the
/// upstream call and its rate-limit slot. Production showed ten failing
/// together, once per staff row.
final reverseGeocodeProvider = FutureProvider.autoDispose
    .family<String?, ReverseGeocodeQuery>((ref, key) async {
      // Watched, so a re-enable re-resolves; paused, the server refuses anyway.
      if (!ref.watch(
        featureFlagsProvider.select((f) => f.addressAutocomplete),
      )) {
        return null;
      }
      final repo = ref.watch(placesRepositoryProvider);
      try {
        final address = await repo.reverseGeocode(
          lat: key.lat,
          lng: key.lng,
          locale: key.locale,
        );
        ref.keepAlive();
        return address;
      } on Object {
        // Held, then released — so the error still reaches the widget (the
        // row renders "No location" off it) but the cell is not re-requested
        // until the cooldown expires. A cache-eviction keep-alive is one of
        // the sanctioned raw-`Timer` uses; this is not a debounce.
        final link = ref.keepAlive();
        final timer = Timer(kReverseGeocodeFailureCooldown, link.close);
        ref.onDispose(timer.cancel);
        rethrow;
      }
    });
