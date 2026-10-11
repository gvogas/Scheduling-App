// The forgot-password screen must never confirm whether an address has an
// account. `toForgotPasswordMessage` returns null for AuthFailureUserNotFound
// so the caller renders the ordinary "check your inbox" panel — the deliberate
// silence is a security property, not a missing message, and a well-meaning
// "improve the error" change turns the screen into an email-enumeration
// endpoint with nothing else failing.
//
// The family is enumerated from the SOURCE below, so a new AuthFailure member
// fails this file until someone decides which side of the line it falls on.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/auth/domain/auth_failure.dart';
import 'package:scheduling/l10n/l10n.dart';

/// Every member of the sealed family, spelled out so each one is exercised.
const List<AuthFailure> _allFailures = [
  AuthFailureInvalidEmail(),
  AuthFailureUserDisabled(),
  AuthFailureUserNotFound(),
  AuthFailureWrongCredentials(),
  AuthFailureTooManyRequests(),
  AuthFailureNetwork(),
  AuthFailureEmailAlreadyInUse(),
  AuthFailureWeakPassword(),
  AuthFailureOperationNotAllowed(),
  AuthFailureRequiresRecentLogin(),
  AuthFailureNotAuthorized(),
  AuthFailureSetupAlreadyComplete(),
  AuthFailureNoAccountRecord(),
  AuthFailureSessionExpired(),
  AuthFailureStartingPasswordReused(),
  AuthFailurePermissionDenied(),
  AuthFailureUnknown(),
];

void main() {
  /// Resolves the messages for [_allFailures] plus the raw l10n strings the
  /// assertions compare against, in one pump.
  Future<({List<String?> messages, AppLocalizations l10n})> resolve(
    WidgetTester tester,
  ) async {
    late List<String?> messages;
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = context.l10n;
            messages = [
              for (final failure in _allFailures)
                failure.toForgotPasswordMessage(context),
            ];
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return (messages: messages, l10n: l10n);
  }

  testWidgets('a missing account stays silent — the screen is not an oracle', (
    tester,
  ) async {
    final resolved = await resolve(tester);
    final index = _allFailures.indexOf(const AuthFailureUserNotFound());

    // null means "render the check-your-inbox panel". Anything else here tells
    // an anonymous caller whether the address is registered.
    expect(resolved.messages[index], isNull);
  });

  testWidgets('no variant leaks the account-existence sentence', (
    tester,
  ) async {
    final resolved = await resolve(tester);

    // The wording that would give the answer away, wherever it came from —
    // this is what fails if a user-not-found-ish variant starts returning a
    // message, or if a new variant is mapped onto the same string.
    expect(
      resolved.messages,
      everyElement(
        isNot(contains(resolved.l10n.error_noAccountFoundWithThisEmail)),
      ),
    );
  });

  testWidgets('user-not-found is the ONLY silent variant', (tester) async {
    final resolved = await resolve(tester);

    // The other half of the rule: null also means "we sent the mail", so a
    // variant that genuinely failed must never fall through to null. This is
    // the regression the old `_ => null` default shipped.
    for (var i = 0; i < _allFailures.length; i++) {
      final failure = _allFailures[i];
      if (failure is AuthFailureUserNotFound) continue;
      expect(
        resolved.messages[i],
        isNotNull,
        reason: '${failure.runtimeType} silently reports a sent email',
      );
      expect(
        resolved.messages[i],
        isNotEmpty,
        reason: '${failure.runtimeType} renders a blank message',
      );
    }
  });

  test('the enumeration above covers the whole sealed family', () {
    // Reflection cannot enumerate a sealed family, so read the declarations
    // back. Without this a NEW member is handled by the source's exhaustive
    // switch but never asserted here — and the one decision that matters
    // (silent vs. spoken) would go unmade.
    final source = File(
      'lib/features/auth/domain/auth_failure.dart',
    ).readAsStringSync();
    final declared = RegExp(
      r'class (AuthFailure\w+) extends AuthFailure',
    ).allMatches(source).map((m) => m.group(1)!).toSet();
    final covered = _allFailures.map((f) => f.runtimeType.toString()).toSet();

    expect(declared, isNotEmpty, reason: 'the family failed to parse');
    expect(
      covered,
      declared,
      reason:
          'add the new AuthFailure member to _allFailures and decide '
          'whether the forgot-password screen may speak about it',
    );
  });
}
