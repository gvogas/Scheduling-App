import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/validators/password_requirements.dart';
import 'package:scheduling/features/auth/widgets/password_requirements_checklist.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  Future<void> pumpChecklist(
    WidgetTester tester,
    String password, {
    bool mustDifferFromStarting = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PasswordRequirementsChecklist(
            password: password,
            mustDifferFromStarting: mustDifferFromStarting,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  final requirementCount = PasswordRequirement.values.length;

  testWidgets('shows an empty circle for every unmet requirement', (
    tester,
  ) async {
    await pumpChecklist(tester, '');
    expect(find.byIcon(Icons.circle_outlined), findsNWidgets(requirementCount));
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('shows a checkmark for every met requirement', (tester) async {
    await pumpChecklist(tester, 'Abcdef1!');
    expect(find.byIcon(Icons.check_circle), findsNWidgets(requirementCount));
    expect(find.byIcon(Icons.circle_outlined), findsNothing);
  });

  testWidgets('mixes circles and checkmarks for a partial password', (
    tester,
  ) async {
    // 'abc' meets only the lowercase requirement.
    await pumpChecklist(tester, 'abc');
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
      find.byIcon(Icons.circle_outlined),
      findsNWidgets(requirementCount - 1),
    );
  });

  testWidgets('the starting-password note is informational, never a check', (
    tester,
  ) async {
    // Only the server can tell a retyped starting password apart (C4), so the
    // row must not read as met when every checkable requirement is.
    await pumpChecklist(tester, 'Abcdef1!', mustDifferFromStarting: true);
    expect(
      find.text('Not the temporary password you were given'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(requirementCount));
  });

  testWidgets('the note is absent by default', (tester) async {
    await pumpChecklist(tester, 'Abcdef1!');
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });
}
