import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/sheets/form_sheet_frame.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: lightTheme(),
  home: Scaffold(body: child),
);

/// Hosts a guarded frame in a real modal sheet; [dirty] is read at dismiss time.
Widget _guardedHost({required ValueGetter<bool> dirty}) => _wrap(
  Builder(
    builder: (context) => ElevatedButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => FormSheetFrame(
          title: 'New job',
          primaryLabel: 'Save',
          isDirty: dirty,
          children: const [Text('body')],
        ),
      ),
      child: const Text('open'),
    ),
  ),
);

Future<void> _openGuarded(
  WidgetTester tester, {
  required ValueGetter<bool> dirty,
}) async {
  await tester.pumpWidget(_guardedHost(dirty: dirty));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('body'), findsOneWidget);
}

void main() {
  testWidgets('renders Cancel, the title and the primary verb', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FormSheetFrame(
          title: 'New job',
          primaryLabel: 'Save',
          onPrimary: () {},
          children: const [Text('body')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('New job'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('body'), findsOneWidget);
  });

  testWidgets('lays the bar out as Cancel · centred title · verb', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        FormSheetFrame(
          title: 'New job',
          primaryLabel: 'Save',
          onPrimary: () {},
          children: const [Text('body')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final barWidth = tester.getSize(find.byType(FormSheetFrame)).width;
    final cancel = tester.getRect(find.text('Cancel'));
    final title = tester.getRect(find.text('New job'));
    final save = tester.getRect(find.text('Save'));

    // The title is optically centred in the bar, not packed against Cancel.
    expect((title.center.dx - barWidth / 2).abs(), lessThan(4));
    // Cancel hugs the leading edge, the verb the trailing edge.
    expect(cancel.left, lessThan(barWidth / 4));
    expect(save.right, greaterThan(barWidth * 3 / 4));
  });

  testWidgets('fires the primary verb', (tester) async {
    var saved = 0;
    await tester.pumpWidget(
      _wrap(
        FormSheetFrame(
          title: 'New job',
          primaryLabel: 'Save',
          onPrimary: () => saved++,
          children: const [Text('body')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    expect(saved, 1);
  });

  testWidgets('swaps the primary verb for a spinner while busy', (
    tester,
  ) async {
    var saved = 0;
    await tester.pumpWidget(
      _wrap(
        FormSheetFrame(
          title: 'New job',
          primaryLabel: 'Save',
          isBusy: true,
          onPrimary: () => saved++,
          children: const [Text('body')],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Save'), findsNothing);
    // Busy disables the verb, so an in-flight save can't be double-submitted.
    await tester.tap(find.byType(FormSheetFrame), warnIfMissed: false);
    expect(saved, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a null onPrimary renders the verb disabled', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const FormSheetFrame(
          title: 'New job',
          primaryLabel: 'Save',
          children: [Text('body')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<TextButton>(
      find.ancestor(of: find.text('Save'), matching: find.byType(TextButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Cancel pops the sheet by default', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const FormSheetFrame(
                title: 'New job',
                primaryLabel: 'Save',
                children: [Text('body')],
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('body'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('body'), findsNothing);
  });

  group('discard guard', () {
    testWidgets('a clean sheet dismisses on Cancel with no confirm', (
      tester,
    ) async {
      await _openGuarded(tester, dirty: () => false);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('body'), findsNothing);
    });

    testWidgets('a dirty sheet asks on Cancel; Keep editing keeps it open', (
      tester,
    ) async {
      await _openGuarded(tester, dirty: () => true);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('confirming Discard pops the sheet', (tester) async {
      await _openGuarded(tester, dirty: () => true);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('body'), findsNothing);
    });

    testWidgets('a scrim tap on a dirty sheet asks first', (tester) async {
      await _openGuarded(tester, dirty: () => true);

      // The frame fills 92% of the height, so the top strip is the barrier.
      await tester.tapAt(const Offset(400, 10));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('a scrim tap on a clean sheet dismisses it', (tester) async {
      await _openGuarded(tester, dirty: () => false);

      await tester.tapAt(const Offset(400, 10));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('body'), findsNothing);
    });

    testWidgets('a fling down on the bar asks when dirty', (tester) async {
      await _openGuarded(tester, dirty: () => true);

      await tester.fling(find.text('New job'), const Offset(0, 200), 2000);
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('a fling down on the bar pops a clean sheet', (tester) async {
      await _openGuarded(tester, dirty: () => false);

      await tester.fling(find.text('New job'), const Offset(0, 200), 2000);
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('body'), findsNothing);
    });

    testWidgets('dirtiness is read at dismiss time, not at build', (
      tester,
    ) async {
      var dirty = false;
      await _openGuarded(tester, dirty: () => dirty);
      dirty = true;

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
    });
  });
}
