import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

Widget _host(TargetPlatform platform, {ValueChanged<bool>? onResult}) =>
    MaterialApp(
      theme: ThemeData(platform: platform),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              // Awaited, not discarded: the RESULT is what every caller acts
              // on, and iOS is the only branch that ships.
              onPressed: () async {
                final confirmed = await showConfirmDialog(
                  context,
                  title: 'Delete?',
                  confirmLabel: 'Delete',
                  message: 'Are you sure?',
                );
                onResult?.call(confirmed);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

Future<bool?> _openAndTap(WidgetTester tester, String action) async {
  bool? result;
  await tester.pumpWidget(
    _host(TargetPlatform.iOS, onResult: (v) => result = v),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(CupertinoDialogAction, action));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('shows CupertinoAlertDialog on iOS', (tester) async {
    await tester.pumpWidget(_host(TargetPlatform.iOS));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows Material AlertDialog on Android', (tester) async {
    await tester.pumpWidget(_host(TargetPlatform.android));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Cancel on the iOS dialog returns false', (tester) async {
    expect(await _openAndTap(tester, 'Cancel'), isFalse);
  });

  testWidgets('the confirm action on the iOS dialog returns true', (
    tester,
  ) async {
    expect(await _openAndTap(tester, 'Delete'), isTrue);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('cancelLabel replaces Cancel on $platform', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showConfirmDialog(
                  context,
                  title: 'Mark 2 jobs not done?',
                  confirmLabel: 'Not done',
                  message: 'They will be cancelled.',
                  cancelLabel: 'Go back',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Go back'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
    });
  }
}
