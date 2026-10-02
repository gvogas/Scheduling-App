import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/navigation/widgets/app_nav_drawer.dart';
import 'package:scheduling/features/settings/screens/settings_screen.dart';
import 'package:scheduling/features/settings/widgets/views/text_size_view.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../support/tour_test_support.dart';

Widget _wrap(Widget child, {double textScale = 2}) => ProviderScope(
  // The drawer's admin rows are gated on the LIVE user doc as well as the
  // route argument, and the admin drawer is the taller overflow case.
  overrides: [
    currentUserDocProvider.overrideWith(
      (ref) => Stream.value(const {'role': 'admin', 'status': 'active'}),
    ),
  ],
  child: ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: textScale,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: child),
    ),
  ),
);

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

  testWidgets(
    'nav drawer does not overflow on narrow landscape at 2x text',
    (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(
          const AppNavDrawer(
            isAdmin: true,
            employeeId: 'e1',
            userName: 'George Alexander Vogas',
            email: 'george.vogas.very.long@example-scheduling-domain.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'text size detail pane does not overflow on narrow landscape at 2x text',
    (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(const TextSizeView()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings screen does not overflow on narrow landscape at 2x text',
    (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(
          const SettingsScreen(
            name: 'Test User',
            email: 'test.user@example.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}
