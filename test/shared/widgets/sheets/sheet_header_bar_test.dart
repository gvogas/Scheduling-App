import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/sheets/sheet_header_bar.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: lightTheme(),
  home: Scaffold(body: Column(children: [child])),
);

/// The small-phone worst case: 260 logical px with 2x text.
Widget _harness(Widget child) => MaterialApp(
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
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child ?? const SizedBox.shrink(),
  ),
  home: Scaffold(body: Column(children: [child])),
);

void main() {
  testWidgets('lays out Cancel · centred title · verb', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SheetHeaderBar(
          title: 'Edit client',
          primaryLabel: 'Save',
          onPrimary: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final barWidth = tester.getSize(find.byType(SheetHeaderBar)).width;
    final cancel = tester.getRect(find.text('Cancel'));
    final title = tester.getRect(find.text('Edit client'));
    final save = tester.getRect(find.text('Save'));

    expect((title.center.dx - barWidth / 2).abs(), lessThan(4));
    expect(cancel.left, lessThan(barWidth / 4));
    expect(save.right, greaterThan(barWidth * 3 / 4));
  });

  testWidgets('stays centred when the verb is much wider than Cancel', (
    tester,
  ) async {
    // The side slots share a flex, so an asymmetric pair of labels must not
    // drag the title off centre — "Send invite" vs "Cancel" is the real case.
    await tester.pumpWidget(
      _wrap(
        SheetHeaderBar(
          title: 'Invite person',
          primaryLabel: 'Send invite',
          onPrimary: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final barWidth = tester.getSize(find.byType(SheetHeaderBar)).width;
    final title = tester.getRect(find.text('Invite person'));
    expect((title.center.dx - barWidth / 2).abs(), lessThan(4));
  });

  testWidgets('fires both actions', (tester) async {
    var saved = 0;
    var cancelled = 0;
    await tester.pumpWidget(
      _wrap(
        SheetHeaderBar(
          title: 'New job',
          primaryLabel: 'Save',
          onPrimary: () => saved++,
          onCancel: () => cancelled++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.tap(find.text('Cancel'));
    expect(saved, 1);
    expect(cancelled, 1);
  });

  testWidgets('busy swaps the verb for a spinner and blocks both actions', (
    tester,
  ) async {
    var saved = 0;
    var cancelled = 0;
    await tester.pumpWidget(
      _wrap(
        SheetHeaderBar(
          title: 'New job',
          primaryLabel: 'Save',
          isBusy: true,
          onPrimary: () => saved++,
          onCancel: () => cancelled++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Save'), findsNothing);
    await tester.tap(find.text('Cancel'));
    expect(saved, 0);
    // Cancel is disabled too: dismissing mid-write would strand the save.
    expect(cancelled, 0);
  });

  testWidgets('a null onPrimary renders the verb disabled', (tester) async {
    await tester.pumpWidget(
      _wrap(const SheetHeaderBar(title: 'New job', primaryLabel: 'Save')),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(
      find.ancestor(of: find.text('Save'), matching: find.byType(TextButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('survives 260x640 at 2.0 text scale', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(
        SheetHeaderBar(
          title: 'Invite person',
          primaryLabel: 'Send invite',
          onPrimary: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  // Both ghost controls carry their own painted width now, so a title long
  // enough to want the whole bar is what proves the three slots still yield.
  testWidgets('a long title beside both actions survives 260px at 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _harness(
        SheetHeaderBar(
          title: 'Edit recurring appointment details',
          primaryLabel: 'Save changes',
          onPrimary: () {},
          onCancel: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
