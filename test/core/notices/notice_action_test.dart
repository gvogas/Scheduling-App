import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/notices/notice_listener.dart';
import 'package:scheduling/core/notices/notice_service.dart';
import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The action a success notice may carry — the mark-complete Undo is its only
/// caller, and it is the app's only undo.
void main() {
  Future<void> pumpApp(WidgetTester tester) async {
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
          builder: (context, child) => NoticeListener(
            navigatorKey: navigatorKey,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: Text('app-body')),
        ),
      ),
    );
  }

  NoticeService service(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.text('app-body')),
  ).read(noticeServiceProvider);

  /// The banner's own exit animation, reached through the one widget that can
  /// only be the notice.
  AnimationStatus bannerStatus(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.ancestor(
          of: find.byType(Dismissible),
          matching: find.byType(FadeTransition),
        ),
      )
      .opacity
      .status;

  Future<void> showBanner(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a plain success notice carries no action button', (
    tester,
  ) async {
    // `AppNotice.info`/`.error` take none either: an error already says what
    // to do in its cause sentence, and an auto-dismissing banner is a race.
    await pumpApp(tester);
    service(tester).success('Marked as complete');
    await showBanner(tester);

    expect(find.text('Marked as complete'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('the action renders as a labelled button on the notice', (
    tester,
  ) async {
    await pumpApp(tester);
    service(tester).successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () {},
    );
    await showBanner(tester);

    expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);

    await tester.pump(AppMotion.noticeActionFloor);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('the action runs AFTER the notice is dismissed', (tester) async {
    // Load-bearing ordering: the action pushes a notice of its own, and
    // `_show` removes whatever entry is standing. Run first and the Undo's
    // own confirmation is the thing racing the banner that launched it.
    await pumpApp(tester);

    AnimationStatus? statusWhenActionRan;
    service(tester).successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () {
        statusWhenActionRan = bannerStatus(tester);
      },
    );
    await showBanner(tester);
    expect(
      bannerStatus(tester),
      AnimationStatus.completed,
      reason: 'the banner is fully in before the tap',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Undo'));

    expect(
      statusWhenActionRan,
      AnimationStatus.reverse,
      reason:
          'the outgoing notice must already be leaving when the action runs',
    );

    await tester.pumpAndSettle();
    await tester.pump(AppMotion.noticeActionFloor);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('a notice the action pushes survives and replaces the first', (
    tester,
  ) async {
    // The end-to-end shape of the Undo: tap it, and the confirmation it emits
    // is what is left on screen.
    await pumpApp(tester);
    final notices = service(tester);
    notices.successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () => notices.success('Changes saved'),
    );
    await showBanner(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.pumpAndSettle();

    expect(find.text('Changes saved'), findsOneWidget);
    expect(find.text('Marked as complete'), findsNothing);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('an action notice holds 6 s, not the 2.6 s cycle', (
    tester,
  ) async {
    await pumpApp(tester);
    service(tester).successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () {},
    );
    await showBanner(tester);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);

    await tester.pump(AppMotion.noticeActionFloor - AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Marked as complete'), findsNothing);
  });

  testWidgets('a later info notice waits behind the Undo, then shows', (
    tester,
  ) async {
    await pumpApp(tester);
    service(tester).successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () {},
    );
    await showBanner(tester);

    service(tester).info('Photos queued');
    await showBanner(tester);
    expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
    expect(find.text('Photos queued'), findsNothing);

    await tester.pump(AppMotion.noticeActionFloor);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await showBanner(tester);
    expect(find.text('Marked as complete'), findsNothing);
    expect(find.text('Photos queued'), findsOneWidget);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('only the latest parked notice survives the Undo', (
    tester,
  ) async {
    await pumpApp(tester);
    service(tester).successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () {},
    );
    await showBanner(tester);

    service(tester)
      ..info('first')
      ..info('second');
    await tester.pump(AppMotion.noticeActionFloor);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await showBanner(tester);
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);

    await tester.pump(AppMotion.noticeCycle);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('an error still pre-empts the Undo', (tester) async {
    await pumpApp(tester);
    service(tester).successWithAction(
      'Marked as complete',
      actionLabel: 'Undo',
      onAction: () {},
    );
    await showBanner(tester);

    service(tester).error('Lost connection');
    await showBanner(tester);
    expect(find.text('Marked as complete'), findsNothing);
    expect(find.text('Lost connection'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  });
}
