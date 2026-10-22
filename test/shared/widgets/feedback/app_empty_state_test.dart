import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/shared/widgets/feedback/app_empty_state.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('AppEmptyState shows icon, title, and body', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const AppEmptyState(
          icon: Icons.event_outlined,
          title: 'No appointments',
          body: 'Tap + to add one.',
        ),
      ),
    );
    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
    expect(find.text('No appointments'), findsOneWidget);
    expect(find.text('Tap + to add one.'), findsOneWidget);
  });

  testWidgets('AppEmptyState shows action button when provided', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        AppEmptyState(
          icon: Icons.people_outline,
          title: 'No clients',
          body: 'Add your first client.',
          actionLabel: 'Add Client',
          onAction: () => tapped = true,
        ),
      ),
    );
    expect(find.text('Add Client'), findsOneWidget);
    await tester.tap(find.text('Add Client'));
    expect(tapped, isTrue);
  });

  testWidgets('AppEmptyState hides button when actionLabel is null', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AppEmptyState(
          icon: Icons.search_outlined,
          title: 'No results',
          body: 'Try a different search.',
        ),
      ),
    );
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('skips its entrance animation under reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(
            body: AppEmptyState(
              icon: Icons.event_outlined,
              title: 'No appointments',
              body: 'Tap + to add one.',
            ),
          ),
        ),
      ),
    );
    final opacity = tester.widget<Opacity>(find.byType(Opacity).first);
    expect(opacity.opacity, 1);
  });

  testWidgets('action grows past 160 px at 2x text on a 260 px screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: AppEmptyState(
            icon: Icons.people_outline,
            title: 'No clients',
            body: 'Add your first client.',
            actionLabel: 'Add your first client',
            onAction: _noop,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(FilledButton)).width, greaterThan(160));
  });
}

void _noop() {}
