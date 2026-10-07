import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/remote_config/update_gate.dart';
import 'package:scheduling/core/remote_config/update_required_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

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

class _FlagsController extends Notifier<FeatureFlags> {
  @override
  FeatureFlags build() => _flags();

  void raiseMinimum(int build) => state = _flags(minBuild: build);
}

final _flagsController = NotifierProvider<_FlagsController, FeatureFlags>(
  _FlagsController.new,
);

Widget _app({required int minBuild, required int? build}) => ProviderScope(
  overrides: [
    featureFlagsProvider.overrideWithValue(_flags(minBuild: minBuild)),
    appBuildNumberProvider.overrideWith((ref) async => build),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: UpdateGate(child: Text('app body')),
  ),
);

void main() {
  group('isUpdateRequired', () {
    test(
      '0 never blocks',
      () => expect(isUpdateRequired(build: 1, minSupported: 0), isFalse),
    );
    test(
      'equal does not block',
      () => expect(isUpdateRequired(build: 93, minSupported: 93), isFalse),
    );
    test(
      'below blocks',
      () => expect(isUpdateRequired(build: 92, minSupported: 93), isTrue),
    );
  });

  testWidgets('a current build sees the app', (tester) async {
    await tester.pumpWidget(_app(minBuild: 93, build: 93));
    await tester.pumpAndSettle();
    expect(find.text('app body'), findsOneWidget);
  });

  testWidgets('an old build sees only the update screen', (tester) async {
    await tester.pumpWidget(_app(minBuild: 94, build: 93));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateRequiredScreen), findsOneWidget);
    expect(find.text('app body'), findsNothing);
  });

  testWidgets('an unreadable build number fails open', (tester) async {
    await tester.pumpWidget(_app(minBuild: 94, build: null));
    await tester.pumpAndSettle();
    expect(find.text('app body'), findsOneWidget);
  });

  testWidgets('raising the minimum mid-session replaces the app', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        featureFlagsProvider.overrideWith((ref) => ref.watch(_flagsController)),
        appBuildNumberProvider.overrideWith((ref) async => 93),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: UpdateGate(child: Text('app body')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('app body'), findsOneWidget);

    container.read(_flagsController.notifier).raiseMinimum(94);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateRequiredScreen), findsOneWidget);
    expect(find.text('app body'), findsNothing);
  });

  testWidgets('update screen does not overflow at 260 px and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: UpdateRequiredScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
