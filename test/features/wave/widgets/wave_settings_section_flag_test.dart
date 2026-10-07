import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/animations/animated_loading_button.dart';
import 'package:scheduling/core/remote_config/feature_flags.dart';
import 'package:scheduling/core/remote_config/feature_flags_providers.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/wave/application/wave_providers.dart';
import 'package:scheduling/features/wave/domain/models/wave_connection.dart';
import 'package:scheduling/features/wave/widgets/wave_settings_section.dart';
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

Widget _wrap({required bool wave, WaveConnection? connection}) {
  return ProviderScope(
    overrides: [
      featureFlagsProvider.overrideWithValue(_flags(wave: wave)),
      waveConnectionProvider.overrideWith((ref) async => connection),
      waveBlockedClientsProvider.overrideWith(
        (ref) => Stream<List<ClientRecord>>.value(const []),
      ),
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        home: const Scaffold(
          body: SingleChildScrollView(child: WaveSettingsSection()),
        ),
      ),
    ),
  );
}

const _connected = WaveConnection(
  businessId: 'biz-1',
  businessName: 'Persisted Co',
  pendingCount: 1,
  failedCount: 2,
);

void main() {
  testWidgets('paused, not connected: banner shown and Connect disabled', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(wave: false));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(WaveSettingsSection)),
    );
    expect(find.text(l10n.settings_wavePaused), findsOneWidget);
    final button = tester.widget<AnimatedLoadingButton>(
      find.byType(AnimatedLoadingButton),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('paused, connected: status rows stay, Sync and Retry disabled', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(wave: false, connection: _connected));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(WaveSettingsSection)),
    );
    expect(find.text(l10n.settings_wavePaused), findsOneWidget);
    expect(find.text('Persisted Co'), findsOneWidget);
    expect(find.text('2 clients failed to sync'), findsOneWidget);
    final sync = tester.widget<AnimatedLoadingButton>(
      find.byType(AnimatedLoadingButton),
    );
    final retry = tester.widget<TextButton>(
      find.widgetWithText(TextButton, l10n.wave_retryFailedButton),
    );
    expect([sync.onPressed, retry.onPressed], [isNull, isNull]);
  });

  testWidgets('not paused: no banner and Sync is enabled', (tester) async {
    await tester.pumpWidget(_wrap(wave: true, connection: _connected));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(WaveSettingsSection)),
    );
    expect(find.text(l10n.settings_wavePaused), findsNothing);
    final sync = tester.widget<AnimatedLoadingButton>(
      find.byType(AnimatedLoadingButton),
    );
    expect(sync.onPressed, isNotNull);
  });
}
