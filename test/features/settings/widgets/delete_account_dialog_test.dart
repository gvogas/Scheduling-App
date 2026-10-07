import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/settings/widgets/dialogs/delete_account_dialog.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/dialogs/confirm_dialog.dart';

Future<bool?> _showConfirm(WidgetTester tester, {required bool isAdmin}) async {
  bool? result;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              // Mirrors the composition in settings_screen._confirmDeleteAccount.
              onPressed: () async {
                result = await showConfirmDialog(
                  context,
                  title: context.l10n.settings_deleteAccountConfirmTitle,
                  confirmLabel: context.l10n.settings_deletePermanently,
                  content: DeleteAccountWarningContent(isAdmin: isAdmin),
                );
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
  return result;
}

void main() {
  group('delete-account confirm dialog', () {
    testWidgets('shows admin warning when isAdmin = true', (tester) async {
      await _showConfirm(tester, isAdmin: true);
      expect(find.text('Delete account?'), findsOneWidget);
      expect(find.textContaining('admin'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hides admin warning when isAdmin = false', (tester) async {
      await _showConfirm(tester, isAdmin: false);
      expect(find.text('Delete account?'), findsOneWidget);
      expect(find.textContaining('admin'), findsNothing);
    });

    testWidgets('Cancel returns false', (tester) async {
      await _showConfirm(tester, isAdmin: false);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsNothing);
    });

    testWidgets('Delete permanently button is present', (tester) async {
      await _showConfirm(tester, isAdmin: false);
      expect(find.text('Delete permanently'), findsOneWidget);
    });
  });
}
