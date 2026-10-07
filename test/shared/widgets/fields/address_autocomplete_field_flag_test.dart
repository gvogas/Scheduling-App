import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
import 'package:scheduling/features/maps/domain/models/address_suggestion.dart';
import 'package:scheduling/features/maps/domain/places_repository.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/fields/address_autocomplete_field.dart';

class _MockPlaces extends Mock implements PlacesRepository {}

FeatureFlags _flags({
  bool addr = true,
  bool presence = true,
  bool liveAct = true,
  bool wave = true,
  int minBuild = 0,
}) => FeatureFlags(
  addressAutocomplete: addr,
  presence: presence,
  liveActivities: liveAct,
  waveSync: wave,
  minSupportedBuild: minBuild,
);

Future<void> _pump(
  WidgetTester tester,
  PlacesRepository places,
  TextEditingController controller, {
  required bool addr,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      placesRepositoryProvider.overrideWithValue(places),
      featureFlagsProvider.overrideWithValue(_flags(addr: addr)),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: AddressAutocompleteField(controller: controller)),
    ),
  ),
);

/// Lets a test flip the kill switch while suggestions are on screen.
class _AddrFlag extends Notifier<bool> {
  @override
  bool build() => true;

  bool get enabled => state;
  set enabled(bool value) => state = value;
}

final _addrEnabled = NotifierProvider<_AddrFlag, bool>(_AddrFlag.new);

/// Enabled, with one suggestion shown for '123 Main'; returns the container.
Future<ProviderContainer> _pumpWithSuggestion(
  WidgetTester tester,
  PlacesRepository places,
  TextEditingController controller,
) async {
  when(
    () => places.autocomplete(any(), sessionToken: any(named: 'sessionToken')),
  ).thenAnswer(
    (_) async => [
      const AddressSuggestion(placeId: 'p1', description: '123 Main St, Laval'),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      placesRepositoryProvider.overrideWithValue(places),
      featureFlagsProvider.overrideWith(
        (ref) => _flags(addr: ref.watch(_addrEnabled)),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: AddressAutocompleteField(controller: controller)),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField), '123 Main');
  await tester.pump(const Duration(seconds: 2));
  expect(find.text('123 Main St, Laval'), findsOneWidget);
  return container;
}

void main() {
  testWidgets('paused: typing never calls Places, and the text still lands', (
    tester,
  ) async {
    final places = _MockPlaces();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pump(tester, places, controller, addr: false);
    await tester.enterText(find.byType(TextField), '123 Main Street');
    await tester.pump(const Duration(seconds: 2));
    expect(controller.text, '123 Main Street');
    verifyZeroInteractions(places);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabled: typing past the debounce makes exactly one lookup', (
    tester,
  ) async {
    final places = _MockPlaces();
    when(
      () =>
          places.autocomplete(any(), sessionToken: any(named: 'sessionToken')),
    ).thenAnswer((_) async => []);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await _pump(tester, places, controller, addr: true);
    await tester.enterText(find.byType(TextField), '123 Main Street');
    await tester.pump(const Duration(seconds: 2));
    verify(
      () =>
          places.autocomplete(any(), sessionToken: any(named: 'sessionToken')),
    ).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pausing clears suggestions already on screen', (tester) async {
    final places = _MockPlaces();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final container = await _pumpWithSuggestion(tester, places, controller);

    container.read(_addrEnabled.notifier).enabled = false;
    await tester.pump();

    expect(find.text('123 Main St, Laval'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused: tapping a stale suggestion never calls getDetails', (
    tester,
  ) async {
    final places = _MockPlaces();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final container = await _pumpWithSuggestion(tester, places, controller);

    // Flipped with no frame pumped, so the row is still there to be tapped.
    container.read(_addrEnabled.notifier).enabled = false;
    await tester.tap(find.text('123 Main St, Laval'));
    await tester.pump();

    verifyNever(
      () => places.getPlaceDetails(
        any(),
        sessionToken: any(named: 'sessionToken'),
      ),
    );
    expect(controller.text, '123 Main St, Laval');
    expect(find.text('123 Main St, Laval'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a re-enable re-fetches the query typed before the pause', (
    tester,
  ) async {
    final places = _MockPlaces();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final container = await _pumpWithSuggestion(tester, places, controller);

    container.read(_addrEnabled.notifier).enabled = false;
    await tester.tap(find.text('123 Main St, Laval'));
    await tester.pump();
    container.read(_addrEnabled.notifier).enabled = true;
    await tester.pump();

    // The first keystroke after a selection is absorbed by `_suppressFetch`.
    await tester.enterText(find.byType(TextField), '1');
    await tester.enterText(find.byType(TextField), '123 Main');
    await tester.pump(const Duration(seconds: 2));

    verify(
      () => places.autocomplete(
        '123 Main',
        sessionToken: any(named: 'sessionToken'),
      ),
    ).called(2);
    expect(tester.takeException(), isNull);
  });
}
