import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/settings/screens/settings_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

import '../../../support/tour_test_support.dart';

Widget _wrap({
  double textScale = 1.0,
  bool isDark = false,
  AuthorizationStatus notificationStatus = AuthorizationStatus.notDetermined,
}) => ProviderScope(
  overrides: [
    // FirebaseMessaging is a system boundary, so stub it rather than letting
    // the real call fail. Unstubbed, every test here reached
    // `getNotificationSettings()`, took `[core/no-app] No Firebase App` (there
    // is no Firebase in a widget test), and fell through the service's catch to
    // `notDetermined` — so the suite asserted against the FAILURE path by
    // accident, and printed nine identical warning traces that would camouflage
    // a real one. Overriding also makes `authorized` reachable, which the
    // failure path never was.
    notificationAuthStatusProvider.overrideWith(
      (ref) async => notificationStatus,
    ),
  ],
  child: ThemeNotifier(
    themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
    toggleTheme: () {},
    textScale: textScale,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: const MaterialApp(
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(name: 'Test User', email: 'test@example.com'),
    ),
  ),
);

void main() {
  // SettingsScreen now watches appInfoProvider (PackageInfo) and the
  // app-lock flag (secure storage) during build.
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

  testWidgets('shows Appearance section header', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.textContaining('APPEARANCE'), findsOneWidget);
  });

  testWidgets('shows Account section header', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.textContaining('ACCOUNT'), findsOneWidget);
  });

  testWidgets('shows Dark Mode label', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.textContaining('Dark Mode'), findsOneWidget);
  });

  testWidgets('shows Text Size label', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.textContaining('Text Size'), findsOneWidget);
  });

  testWidgets('shows Language label', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.textContaining('Language'), findsOneWidget);
  });

  testWidgets('shows EN and FR language buttons', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.text('EN'), findsOneWidget);
    expect(find.text('FR'), findsOneWidget);
  });

  testWidgets('does not show a Slider widget', (tester) async {
    await tester.pumpWidget(_wrap());
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('shows current text scale label next to Text Size', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    expect(find.text('Medium'), findsOneWidget);
  });

  // The settings body is a lazy ListView and these rows sit well below the
  // fold, so they are never built at the default viewport — hence the tall one
  // rather than a scroll, which would depend on each row's exact offset.
  Future<void> pumpTall(
    WidgetTester tester, {
    AuthorizationStatus status = AuthorizationStatus.notDetermined,
  }) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(_wrap(notificationStatus: status));
    await tester.pumpAndSettle();
  }

  group('the notifications row reflects the OS status', () {
    // Neither state was reachable before the provider was stubbed: the real
    // call always failed in a widget test, so the row was permanently "Off"
    // and nothing here could tell a genuine Off from a swallowed error.
    testWidgets('reads Off when the OS has not been asked', (tester) async {
      await pumpTall(tester);

      expect(find.text('Off'), findsOneWidget);
      expect(find.text('On'), findsNothing);
    });

    testWidgets('reads On once notifications are authorized', (tester) async {
      await pumpTall(tester, status: AuthorizationStatus.authorized);

      expect(find.text('On'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
    });
  });

  // The setup screen's consent link is shown once, only to a new employee, so
  // this row is the DURABLE route to the agreement they were made to accept.
  // A revert dropped it once and nothing caught it; this is that guard.
  testWidgets('Legal offers Terms of Service beside Privacy Policy', (
    tester,
  ) async {
    await pumpTall(tester);

    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Service'), findsOneWidget);
  });

  testWidgets('does not overflow at small screen + 2x text', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: _wrap(),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
