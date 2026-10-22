import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/validators/auth_validators.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Sign-in (`password`) is non-empty only; the 8+ / mixed-case / digit policy
/// lives on `newPassword`. This test uses a real [Localizations] harness so
/// `context.l10n.*` messages match what users actually see.

void main() {
  Future<BuildContext> buildContext(WidgetTester tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      Localizations(
        locale: const Locale('en'),
        delegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        child: Builder(
          builder: (ctx) {
            capturedContext = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return capturedContext;
  }

  testWidgets('AuthValidators.password rejects empty input', (tester) async {
    final context = await buildContext(tester);
    expect(
      AuthValidators.password(context, ''),
      AppLocalizations.of(context).validation_pleaseEnterYourPassword,
    );
    expect(AuthValidators.password(context, '   '), isNotNull);
  });

  testWidgets(
    'AuthValidators.password accepts a short password: legacy accounts predate '
    'the 8-character policy, and a format error at sign-in locks them out (C3)',
    (tester) async {
      final context = await buildContext(tester);
      expect(AuthValidators.password(context, '1234567'), isNull);
      expect(AuthValidators.password(context, 'a'), isNull);
      expect(
        AuthValidators.password(context, 'a-perfectly-fine-password'),
        isNull,
      );
    },
  );

  testWidgets('AuthValidators.newPassword enforces the checklist', (
    tester,
  ) async {
    final context = await buildContext(tester);
    expect(
      AuthValidators.newPassword(context, '1234567'),
      AppLocalizations.of(
        context,
      ).validation_passwordDoesNotMeetAllRequirements,
    );
    expect(AuthValidators.newPassword(context, 'Abcdefg1'), isNull);
  });
}
