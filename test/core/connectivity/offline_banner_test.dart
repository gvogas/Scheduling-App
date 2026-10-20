import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/connectivity/connectivity_providers.dart';
import 'package:scheduling/core/connectivity/offline_banner.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _app(List<ConnectivityResult> results) => ProviderScope(
  overrides: [
    connectivityResultsProvider.overrideWith((ref) => Stream.value(results)),
  ],
  child: const MaterialApp(
    localizationsDelegates: [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: OfflineBanner()),
  ),
);

void main() {
  const offlineText = 'Offline — you can view your schedule; saving needs a connection';

  testWidgets('shows the banner when the device is offline', (tester) async {
    await tester.pumpWidget(_app(const [ConnectivityResult.none]));
    await tester.pump();
    expect(find.text(offlineText), findsOneWidget);
  });

  testWidgets('hidden while a connection is available', (tester) async {
    await tester.pumpWidget(_app(const [ConnectivityResult.wifi]));
    await tester.pump();
    expect(find.text(offlineText), findsNothing);
  });

  group('isOfflineProvider', () {
    ProviderContainer container(List<ConnectivityResult>? results) {
      final c = ProviderContainer(
        overrides: [
          connectivityResultsProvider.overrideWith(
            (ref) => results == null
                ? const Stream<List<ConnectivityResult>>.empty()
                : Stream.value(results),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<bool> offline(List<ConnectivityResult>? results) {
      final c = container(results)..listen(isOfflineProvider, (_, _) {});
      return Future<bool>.microtask(() => c.read(isOfflineProvider));
    }

    test('true only when every report is "none"', () async {
      expect(await offline(const [ConnectivityResult.none]), isTrue);
      expect(await offline(const []), isTrue);
      expect(await offline(const [ConnectivityResult.wifi]), isFalse);
      expect(
        await offline(const [
          ConnectivityResult.none,
          ConnectivityResult.mobile,
        ]),
        isFalse,
      );
    });

    test('unknown state (no report yet) counts as online', () async {
      expect(await offline(null), isFalse);
    });
  });
}
