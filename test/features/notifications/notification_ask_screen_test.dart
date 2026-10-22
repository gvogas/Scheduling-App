import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:scheduling/core/notifications/push_notification_service.dart';
import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/notifications/application/push_registration_controller.dart';
import 'package:scheduling/features/notifications/screens/notification_ask_screen.dart';
import 'package:scheduling/l10n/l10n.dart';

class _MockPushService extends Mock implements PushNotificationService {}

class _MockController extends Mock implements PushRegistrationController {}

void main() {
  late _MockPushService service;
  late _MockController controller;

  setUp(() {
    service = _MockPushService();
    controller = _MockController();
    when(service.requestPermission).thenAnswer((_) async => true);
    when(controller.sync).thenAnswer((_) async {});
  });

  /// Pushes the page over a stub home, so a pop is observable.
  Future<void> openPage(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pushNotificationServiceProvider.overrideWithValue(service),
          pushRegistrationControllerProvider.overrideWithValue(controller),
        ],
        child: ThemeNotifier(
          themeMode: ThemeMode.light,
          toggleTheme: () {},
          textScale: textScale,
          setTextScale: (_) {},
          setLanguage: (_) {},
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: lightTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const NotificationAskScreen(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Turn on shows the OS prompt, re-syncs the token and closes', (
    tester,
  ) async {
    await openPage(tester);

    await tester.tap(find.text('Turn on notifications'));
    await tester.pumpAndSettle();

    verifyInOrder([service.requestPermission, controller.sync]);
    expect(find.byType(NotificationAskScreen), findsNothing);
  });

  testWidgets('Not now closes without touching the OS prompt', (tester) async {
    await openPage(tester);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(find.byType(NotificationAskScreen), findsNothing);
    verifyNever(service.requestPermission);
    verifyNever(controller.sync);
  });

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openPage(tester, textScale: 2);

    expect(find.byType(NotificationAskScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
