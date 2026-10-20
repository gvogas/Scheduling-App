import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  Future<String> messageFor(WidgetTester tester, AuthFailure f) async {
    late String msg;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) {
            msg = f.toLocalizedMessage(c);
            return const SizedBox();
          },
        ),
      ),
    );
    return msg;
  }

  testWidgets('already-set-up message', (t) async {
    expect(
      await messageFor(t, const AuthFailureSetupAlreadyComplete()),
      contains('already set up'),
    );
  });
  testWidgets('missing account record message', (t) async {
    expect(
      await messageFor(t, const AuthFailureNoAccountRecord()),
      contains('employee record'),
    );
  });
  testWidgets('weak password names the checklist, not a 6-character floor', (
    t,
  ) async {
    // C2: the server policy is 8+ with mixed case and a digit, which is what
    // the checklist under the field already says.
    final message = await messageFor(t, const AuthFailureWeakPassword());
    expect(message, contains('requirements'));
    expect(message, isNot(contains('6')));
  });
  testWidgets('expired session message', (t) async {
    expect(
      await messageFor(t, const AuthFailureSessionExpired()),
      contains('expired'),
    );
  });

  group('isExpected', () {
    test('user-correctable failures are expected', () {
      for (final failure in const <AuthFailure>[
        AuthFailureInvalidEmail(),
        AuthFailureUserDisabled(),
        AuthFailureUserNotFound(),
        AuthFailureWrongCredentials(),
        AuthFailureTooManyRequests(),
        AuthFailureNetwork(),
        AuthFailureEmailAlreadyInUse(),
        AuthFailureWeakPassword(),
        AuthFailureRequiresRecentLogin(),
        AuthFailureNotAuthorized(),
        AuthFailureSetupAlreadyComplete(),
        AuthFailureSessionExpired(),
      ]) {
        expect(failure.isExpected, isTrue, reason: '${failure.runtimeType}');
      }
    });

    test('defects and misconfiguration are not expected', () {
      for (final failure in const <AuthFailure>[
        AuthFailureOperationNotAllowed(),
        AuthFailurePermissionDenied(),
        AuthFailureUnknown(),
        AuthFailureNoAccountRecord(),
      ]) {
        expect(failure.isExpected, isFalse, reason: '${failure.runtimeType}');
      }
    });
  });
}
