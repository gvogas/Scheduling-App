import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/maps_failure.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';

/// Counts lookups so a test can tell a cached answer from a fresh billed call.
class _CountingPlaces implements PlacesRepository {
  _CountingPlaces({this.fail = false});

  bool fail;
  int calls = 0;

  @override
  Future<String?> reverseGeocode({
    required double lat,
    required double lng,
    required String locale,
  }) async {
    calls += 1;
    if (fail) throw const MapsFailureRateLimit();
    return '1234 Rue Principale, Laval, QC';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final key = ReverseGeocodeQuery(lat: 45.5017, lng: -73.5673, locale: 'en');

  /// Reads the provider to settle, then drops the subscription so autoDispose
  /// is free to tear it down exactly as a recycled list row does.
  ///
  /// Polls the `AsyncValue` rather than awaiting `.future`: an autoDispose
  /// provider released between reads can leave that future pending, which is
  /// a property of the harness, not of the behaviour under test.
  Future<void> readAndRelease(ProviderContainer container) async {
    final sub = container.listen(
      reverseGeocodeProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    while (container.read(reverseGeocodeProvider(key)).isLoading) {
      await Future<void>.delayed(Duration.zero);
    }
    sub.close();
    // autoDispose disposal is SCHEDULED, not immediate. Without letting the
    // event loop turn here, the next listen re-attaches before the teardown
    // runs and the provider is never actually recycled — which is the very
    // path these tests exist to exercise.
    await Future<void>.delayed(Duration.zero);
  }

  test('a successful lookup is not repeated', () async {
    final places = _CountingPlaces();
    final container = ProviderContainer(
      overrides: [placesRepositoryProvider.overrideWithValue(places)],
      // Same override `main()` installs. Without it Riverpod 3's default
      // exponential retry re-runs an errored provider on its own, which both
      // hangs `.future` and confounds the call count these tests assert on.
      retry: (retryCount, error) => null,
    );
    addTearDown(container.dispose);

    await readAndRelease(container);
    await readAndRelease(container);

    // Kept alive on success — the existing contract, pinned so the cooldown
    // below can't quietly weaken it.
    expect(places.calls, 1);
  });

  test('a FAILED lookup is not immediately retried', () async {
    // The live-map roster watches this provider per row inside a
    // `ListView.separated` builder, so scrolling disposes off-screen rows and
    // scrolling back re-creates them. With the failure left autoDispose, every
    // recycle was a fresh billed geocode against a 120/hour budget — and
    // production showed ten of them failing together, once per staff row.
    final places = _CountingPlaces(fail: true);
    final container = ProviderContainer(
      overrides: [placesRepositoryProvider.overrideWithValue(places)],
      // Same override `main()` installs. Without it Riverpod 3's default
      // exponential retry re-runs an errored provider on its own, which both
      // hangs `.future` and confounds the call count these tests assert on.
      retry: (retryCount, error) => null,
    );
    addTearDown(container.dispose);

    await readAndRelease(container);
    await readAndRelease(container);
    await readAndRelease(container);

    expect(places.calls, 1);
  });

  test('the failure is held for the cooldown, then retried', () async {
    final places = _CountingPlaces(fail: true);
    final container = ProviderContainer(
      overrides: [placesRepositoryProvider.overrideWithValue(places)],
      // Same override `main()` installs. Without it Riverpod 3's default
      // exponential retry re-runs an errored provider on its own, which both
      // hangs `.future` and confounds the call count these tests assert on.
      retry: (retryCount, error) => null,
    );
    addTearDown(container.dispose);

    await readAndRelease(container);
    expect(places.calls, 1);

    // "Retries later" has to stay true — a transient rate-limit or timeout
    // must not poison the cell for the session. Only "later" becomes real.
    expect(
      kReverseGeocodeFailureCooldown,
      greaterThan(const Duration(seconds: 30)),
    );
  });

  test('the failure still surfaces to the widget', () async {
    // Holding the cell must not swallow the error — the row renders
    // "No location" off an AsyncError, so turning it into data would read as
    // a successful lookup with no address.
    final places = _CountingPlaces(fail: true);
    final container = ProviderContainer(
      overrides: [placesRepositoryProvider.overrideWithValue(places)],
      retry: (retryCount, error) => null,
    );
    addTearDown(container.dispose);

    // Keep the subscription open — this asserts what a MOUNTED row sees.
    final sub = container.listen(
      reverseGeocodeProvider(key),
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);
    while (container.read(reverseGeocodeProvider(key)).isLoading) {
      await Future<void>.delayed(Duration.zero);
    }

    final value = container.read(reverseGeocodeProvider(key));
    expect(value.hasError, isTrue);
    expect(value.error, isA<MapsFailureRateLimit>());
  });

  test('a coarse key merges fixes ~250 m apart that the default key splits', () {
    ReverseGeocodeQuery q(double lat, {int decimals = 3}) => ReverseGeocodeQuery(
      lat: lat,
      lng: -73.5673,
      locale: 'en',
      decimals: decimals,
    );

    expect(q(45.5017), isNot(q(45.5042)));
    expect(
      q(45.5017, decimals: kCoarseGeocodePrecision),
      q(45.5042, decimals: kCoarseGeocodePrecision),
    );
    expect(
      q(45.5017, decimals: kCoarseGeocodePrecision).hashCode,
      q(45.5042, decimals: kCoarseGeocodePrecision).hashCode,
    );
    expect(q(45.5017, decimals: kCoarseGeocodePrecision).lat, 45.5);
  });
}
