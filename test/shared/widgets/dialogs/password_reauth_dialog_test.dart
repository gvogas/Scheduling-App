import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/password_reauth_dialog.dart';

/// Opens the dialog with the delete-account copy, as `DeleteAccountFlow` does.
Future<void> _open(
  WidgetTester tester, {
  TargetPlatform? platform,
  bool destructive = true,
  void Function(String?)? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: platform == null ? null : ThemeData(platform: platform),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final result = await showPasswordReauthDialog(
                  context,
                  title: context.l10n.settings_confirmYourPassword,
                  message: context.l10n.settings_confirmYourPasswordToDelete,
                  confirmLabel: context.l10n.settings_deletePermanently,
                  destructive: destructive,
                );
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows password field with obscured text by default', (
    tester,
  ) async {
    await _open(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(find.text('Confirm your password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirm is disabled until a password is entered', (
    tester,
  ) async {
    await _open(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete permanently'),
    );
    expect(button.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pumpAndSettle();

    final enabledButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete permanently'),
    );
    expect(enabledButton.onPressed, isNotNull);
  });

  testWidgets('a non-destructive confirm keeps the default button style', (
    tester,
  ) async {
    await _open(tester, destructive: false);
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete permanently'),
    );
    expect(button.style, isNull);
  });

  testWidgets('empty keyboard submit keeps the dialog open', (tester) async {
    await _open(tester);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Confirm your password'), findsOneWidget);
  });

  testWidgets('renders the Cupertino variant on iOS', (tester) async {
    String? result;
    await _open(
      tester,
      platform: TargetPlatform.iOS,
      onResult: (r) => result = r,
    );

    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final field = tester.widget<CupertinoTextField>(
      find.byType(CupertinoTextField),
    );
    expect(field.obscureText, isTrue);

    await tester.enterText(find.byType(CupertinoTextField), 'hunter2');
    // The confirm action is null-gated on `_hasPassword`, so the rebuild that
    // enables it has to land before the tap.
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    expect(result, 'hunter2');
  });
}
