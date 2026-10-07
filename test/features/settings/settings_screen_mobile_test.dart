import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/features/settings/screens/settings_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../support/tour_test_support.dart';

void main() {
  setUpAll(
    () => PackageInfo.setMockInitialValues(
      appName: 'Scheduling',
      packageName: 'net.vogas.scheduling',
      version: '1.0.3',
      buildNumber: '4',
      buildSignature: '',
    ),
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    markAllToursSeen();
  });

  testWidgets('settings screen does not overflow on phone width at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: ThemeNotifier(
          themeMode: ThemeMode.light,
          toggleTheme: () {},
          textScale: 2,
          setTextScale: (_) {},
          setLanguage: (_) {},
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child ?? const SizedBox.shrink(),
            ),
            home: const SettingsScreen(
              name: 'Test User',
              email: 'test@example.com',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
