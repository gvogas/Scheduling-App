import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/features/maps/application/maps_providers.dart';
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

void main() {
  testWidgets('paused: typing never calls Places, and the text still lands', (
    tester,
  ) async {
    final places = _MockPlaces();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          placesRepositoryProvider.overrideWithValue(places),
          featureFlagsProvider.overrideWithValue(_flags(addr: false)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AddressAutocompleteField(controller: controller),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '123 Main Street');
    await tester.pump(const Duration(seconds: 2));
    expect(controller.text, '123 Main Street');
    verifyZeroInteractions(places);
  });
}
