import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:scheduling/core/theme/theme_notifier.dart';
import 'package:scheduling/features/settings/screens/settings_screen.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('replay row clears the tour seen flags and notifies', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'tour_seen_tabs': ['calendar', 'settings'],
    });

    await tester.pumpWidget(
      ProviderScope(
        child: ThemeNotifier(
          themeMode: ThemeMode.light,
          toggleTheme: () {},
          textScale: 1,
          setTextScale: (_) {},
          setLanguage: (_) {},
          child: const MaterialApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: SettingsScreen(
              name: 'Test User',
              email: 'test@example.com',
              role: 'admin',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Target the master list by key. `find.byType(Scrollable).first` is
    // ambiguous (the two-pane layout renders a second one), and anchoring on a
    // row's ancestor breaks as soon as that row scrolls out of the built range
    // or a new row is added above it.
    final masterScrollable = find.descendant(
      of: find.byKey(const ValueKey('settingsMasterList')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Replay app tour'),
      200,
      scrollable: masterScrollable,
    );
    // scrollUntilVisible's ensureVisible can land the row right at the
    // viewport edge (not hit-testable) — nudge it fully into view.
    await tester.drag(masterScrollable, const Offset(0, -80));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replay app tour'));
    // Settings is a pushed route now, so clearing the flags immediately
    // restarts its tour; the showcase overlay animates continuously, which
    // would make pumpAndSettle time out. Bounded pumps flush the async save
    // and let showcase's auto-scroll settle before the harness tears down.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    final prefs = await SharedPreferences.getInstance();
    // Progress is per STEP now. The legacy per-scope key is deliberately left
    // untouched — it is only ever read when tour_seen_steps is ABSENT, and an
    // empty list is still a present key, so the migration cannot undo this
    // replay.
    expect(prefs.getStringList('tour_seen_steps'), isEmpty);
  });
}
