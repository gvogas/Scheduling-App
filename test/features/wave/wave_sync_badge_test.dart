import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/core/theme/themes.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';
import 'package:scheduling/features/wave/widgets/wave_sync_badge.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _wrap(Widget child) {
  return ThemeNotifier(
    themeMode: ThemeMode.light,
    toggleTheme: () {},
    textScale: 1,
    setTextScale: (_) {},
    setLanguage: (_) {},
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: lightTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('WaveSyncBadge', () {
    testWidgets('renders "Synced with Wave" for syncState synced', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const WaveSyncBadge(syncState: 'synced')));
      await tester.pumpAndSettle();

      expect(find.text('Synced with Wave'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders "Sync pending" for syncState pending', (tester) async {
      await tester.pumpWidget(_wrap(const WaveSyncBadge(syncState: 'pending')));
      await tester.pumpAndSettle();

      expect(find.text('Sync pending'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders "Sync error" for syncState error', (tester) async {
      await tester.pumpWidget(_wrap(const WaveSyncBadge(syncState: 'error')));
      await tester.pumpAndSettle();

      expect(find.text('Sync error'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders nothing for empty syncState', (tester) async {
      await tester.pumpWidget(_wrap(const WaveSyncBadge(syncState: '')));
      await tester.pumpAndSettle();

      expect(find.text('Synced with Wave'), findsNothing);
      expect(find.text('Sync pending'), findsNothing);
      expect(find.text('Sync error'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders nothing for unrecognised syncState', (tester) async {
      await tester.pumpWidget(
        _wrap(const WaveSyncBadge(syncState: 'unknown-state')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Synced with Wave'), findsNothing);
      expect(find.text('Sync pending'), findsNothing);
      expect(find.text('Sync error'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error badge Semantics includes syncError when provided', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const WaveSyncBadge(
            syncState: 'error',
            syncError: 'timeout connecting to Wave',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final semantics = tester.getSemantics(find.byType(WaveSyncBadge));
      expect(semantics.label, contains('timeout connecting to Wave'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the blocked badge for syncState blocked', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const WaveSyncBadge(
            syncState: 'blocked',
            problems: <WaveProblem>[
              WaveProblem(
                field: 'name',
                code: WaveProblemCode.empty,
                isBlocking: true,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Can't sync to Wave"), findsOneWidget);
      expect(find.text('The client needs a name'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a TOO_LONG problem names the field and both numbers', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const WaveSyncBadge(
            syncState: 'blocked',
            problems: <WaveProblem>[
              WaveProblem(
                field: 'name',
                code: WaveProblemCode.tooLong,
                isBlocking: true,
                length: 218,
                cap: 200,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Visible TEXT, not a Semantics label — the whole point of the change.
      expect(find.text('Name is too long (218 / 200)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an advisory on a SYNCED client still shows its reason', (
      tester,
    ) async {
      // Client 2wcEiCNztsWYUYNXYBEm: Wave took the value happily, the data is
      // still wrong, and nothing in the app said so.
      await tester.pumpWidget(
        _wrap(
          const WaveSyncBadge(
            syncState: 'synced',
            problems: <WaveProblem>[
              WaveProblem(
                field: 'phone',
                code: WaveProblemCode.notDialable,
                isBlocking: false,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Synced with Wave'), findsOneWidget);
      expect(find.text('Phone has no digits to dial'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unknown problem code still renders a sentence', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const WaveSyncBadge(
            syncState: 'blocked',
            problems: <WaveProblem>[
              WaveProblem(
                field: 'city',
                code: WaveProblemCode.unknown,
                isBlocking: true,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("Wave won't accept City"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders every problem, not just the first', (tester) async {
      await tester.pumpWidget(
        _wrap(
          const WaveSyncBadge(
            syncState: 'blocked',
            problems: <WaveProblem>[
              WaveProblem(
                field: 'name',
                code: WaveProblemCode.empty,
                isBlocking: true,
              ),
              WaveProblem(
                field: 'email',
                code: WaveProblemCode.invalidEmail,
                isBlocking: true,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('The client needs a name'), findsOneWidget);
      expect(find.text("The email address isn't valid"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a small phone at 2x text', (tester) async {
      tester.view.physicalSize = const Size(260, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrap(
          const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: WaveSyncBadge(
              syncState: 'blocked',
              problems: <WaveProblem>[
                WaveProblem(
                  field: 'name',
                  code: WaveProblemCode.tooLong,
                  isBlocking: true,
                  length: 218,
                  cap: 200,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
