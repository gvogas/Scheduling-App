import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/employees/domain/models/new_account_credentials.dart';
import 'package:scheduling/features/employees/widgets/dialogs/new_account_dialog.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  /// Captures whatever the dialog puts on the clipboard.
  List<String?> mockClipboard(WidgetTester tester) {
    final copied = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewAccountDialog(
                context,
                name: 'Zoé',
                credentials: const NewAccountCredentials(
                  email: 'zoe@example.com',
                  password: 'Pw23456789x',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Close before copying asks first, and Cancel keeps the '
      'credentials on screen', (tester) async {
    // The password is never persisted; closing uncopied loses it for good.
    await openDialog(tester);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Close without copying?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Close without copying?'), findsNothing);
    expect(find.text('Pw23456789x'), findsOneWidget);
  });

  testWidgets('Close anyway discards the uncopied credentials', (tester) async {
    await openDialog(tester);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close anyway'));
    await tester.pumpAndSettle();

    expect(find.text('Pw23456789x'), findsNothing);
  });

  testWidgets('once copied, Close closes at once', (tester) async {
    final copied = mockClipboard(tester);
    await openDialog(tester);

    await tester.tap(find.text('Copy both'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(copied, ['zoe@example.com\nPw23456789x']);
    expect(find.text('Close without copying?'), findsNothing);
    expect(find.text('Pw23456789x'), findsNothing);
  });
}
