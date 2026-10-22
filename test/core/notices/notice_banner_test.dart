import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/notices/app_notice.dart';
import 'package:scheduling/core/notices/notice_hold.dart';
import 'package:scheduling/core/notices/notice_listener.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    bool accessibleNavigation = false,
  }) async {
    // Mirrors main.dart: NoticeListener sits above the Navigator and inserts
    // its banners into the navigator's overlay via the key.
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: lightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(accessibleNavigation: accessibleNavigation),
            child: NoticeListener(
              navigatorKey: navigatorKey,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: const Scaffold(body: Text('app-body')),
        ),
      ),
    );
  }

  NoticeService service(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.text('app-body')),
  ).read(noticeServiceProvider);

  testWidgets('close button is a 48px IconButton with a tooltip', (
    tester,
  ) async {
    await pumpApp(tester, accessibleNavigation: true);
    service(tester).info('hello notice');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('hello notice'), findsOneWidget);
    final closeButton = find.byTooltip('Close');
    expect(closeButton, findsOneWidget);
    final size = tester.getSize(
      find.ancestor(of: closeButton, matching: find.byType(IconButton)),
    );
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    await tester.tap(closeButton);
    await tester.pump(); // Start the exit animation (ticker start frame).
    await tester.pump(const Duration(milliseconds: 400)); // Finish it.
    await tester.pump(); // Process the overlay-entry removal.
    expect(find.text('hello notice'), findsNothing);

    // Flush the (now no-op) auto-dismiss timer so the test ends cleanly.
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('no close button without accessible navigation', (tester) async {
    await pumpApp(tester);
    service(tester).info('hello notice');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('hello notice'), findsOneWidget);
    // The design has no close button; swipe-up still dismisses for everyone.
    expect(find.byTooltip('Close'), findsNothing);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('banner can be swiped up to dismiss', (tester) async {
    await pumpApp(tester);
    service(tester).error('swipe me');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('swipe me'), findsOneWidget);

    await tester.fling(find.text('swipe me'), const Offset(0, -120), 1000);
    await tester.pumpAndSettle();
    expect(find.text('swipe me'), findsNothing);

    // Flush the (now no-op) auto-dismiss timer so the test ends cleanly.
    await tester.pump(AppMotion.noticeCycle);
  });

  testWidgets('auto-dismiss timer is preserved', (tester) async {
    await pumpApp(tester);
    service(tester).success('short lived');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('short lived'), findsOneWidget);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('short lived'), findsNothing);
  });

  Icon kindIcon(WidgetTester tester) =>
      tester.widget<Icon>(find.byKey(const ValueKey('notice-icon')));

  Future<void> flush(WidgetTester tester, Duration hold) async {
    await tester.pump(hold);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('the notice renders on the inverse surface with a kind icon', (
    tester,
  ) async {
    await pumpApp(tester);
    service(tester).success('all good');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final surface = tester.widget<Material>(
      find
          .ancestor(of: find.text('all good'), matching: find.byType(Material))
          .first,
    );
    expect(surface.color, lightTheme().colorScheme.inverseSurface);

    final icon = kindIcon(tester);
    expect(icon.icon, Icons.check_circle_outline_rounded);
    expect(icon.color, lightTheme().palette.noticeMint);

    await flush(tester, AppMotion.noticeCycle);
  });

  testWidgets('info and error carry their own icon and tint', (tester) async {
    // A2: colour is never the only cue — each kind has a glyph as well.
    await pumpApp(tester);
    service(tester).info('heads up');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(kindIcon(tester).icon, Icons.info_outline_rounded);
    expect(kindIcon(tester).color, lightTheme().palette.noticeInfo);

    service(tester).error('boom');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(kindIcon(tester).icon, Icons.error_outline_rounded);
    expect(kindIcon(tester).color, lightTheme().palette.noticeRed);

    await flush(
      tester,
      noticeHoldFor(const AppNotice.error('boom'), accessible: false),
    );
  });

  testWidgets('the live region reads the kind before the message', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);

    service(tester).error("Couldn't save");
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel("Error: Couldn't save"), findsOneWidget);
    // The plain message is not announced a second time.
    expect(find.bySemanticsLabel("Couldn't save"), findsNothing);

    service(tester).success('Saved');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Success: Saved'), findsOneWidget);

    service(tester).info('Photos queued');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Info: Photos queued'), findsOneWidget);

    await flush(tester, AppMotion.noticeCycle);
    semantics.dispose();
  });

  testWidgets('an error outlives the success cycle and then dismisses', (
    tester,
  ) async {
    await pumpApp(tester);
    const message = "Couldn't save the appointment. Someone else edited it.";
    service(tester).error(message);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text(message), findsOneWidget);

    final hold = noticeHoldFor(
      const AppNotice.error(message),
      accessible: false,
    );
    await flush(tester, hold - AppMotion.noticeCycle);
    expect(find.text(message), findsNothing);
  });

  testWidgets('a finger on the banner pauses the hold until it lifts', (
    tester,
  ) async {
    await pumpApp(tester);
    service(tester).success('hold me');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('hold me')),
    );
    await tester.pump(AppMotion.noticeCycle * 3);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('hold me'), findsOneWidget);

    await gesture.up();
    await flush(tester, AppMotion.noticeCycle);
    expect(find.text('hold me'), findsNothing);
  });
}
