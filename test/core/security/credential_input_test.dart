// Every field that receives a credential must set
// `enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning`, so a
// third-party keyboard cannot retain and cloud-sync a typed password.
//
// `obscureText` is NOT a safe proxy for it: every password field in this app
// carries a Show/Hide toggle, so the instant it is tapped the field renders
// plain text at the framework's `true` default. That is exactly how
// `AuthPasswordField` and both `PasswordReauthDialog` variants once
// shipped without the flag — a rule nothing enforced.
//
// A widget test can only pin the fields it happens to mount, and the failure
// mode here is a NEW field that no test knows about. So this reads `lib/` back
// as source, the same mechanism `text_limits_test.dart` uses on
// `firestore.rules`. See `.claude/rules/security.md`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/security/credential_input.dart';

/// Widget-argument occurrences only — the rule is also discussed in prose in
/// several doc comments, and a comment is not a field.
bool _isCode(String line) {
  final trimmed = line.trimLeft();
  return !trimmed.startsWith('//') && !trimmed.startsWith('///');
}

/// How far below an `obscureText:` argument the flag may sit and still count
/// as "beside" it. Generous enough to survive `dart format` rewrapping the
/// argument list, tight enough that it cannot reach the next widget.
const int _adjacencyWindow = 12;

List<File> _libDartFiles() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  late final files = _libDartFiles();

  test('the flag turns IME personalisation OFF', () {
    // The whole point of the named constant: a `true` here would silently
    // re-enable learning at all four sites at once.
    expect(kCredentialImePersonalizedLearning, isFalse);
  });

  test('lib/ was actually scanned', () {
    // Guards the guard: a broken path would make every assertion below pass
    // vacuously.
    expect(files, isNotEmpty);
    expect(
      files.any((f) => f.readAsStringSync().contains('obscureText:')),
      isTrue,
      reason: 'no obscured field found at all — the scan is not reaching lib/',
    );
  });

  test('every obscured field sets enableIMEPersonalizedLearning beside it', () {
    final offenders = <String>[];

    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!_isCode(lines[i]) || !lines[i].contains('obscureText:')) continue;
        final end = (i + _adjacencyWindow + 1).clamp(0, lines.length);
        final window = lines.sublist(i, end).where(_isCode).join('\n');
        if (!window.contains(
          'enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning',
        )) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'credential field(s) without '
          'enableIMEPersonalizedLearning: kCredentialImePersonalizedLearning — '
          '${offenders.join(', ')}',
    );
  });

  test('the flag is never spelled as a bare literal', () {
    // A hand-written `false` works today and drifts tomorrow; the named
    // constant is what makes "every credential field" greppable.
    final offenders = <String>[];

    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!_isCode(lines[i])) continue;
        final match = RegExp(
          r'enableIMEPersonalizedLearning:\s*(\S+)',
        ).firstMatch(lines[i]);
        final value = match?.group(1)?.replaceAll(',', '');
        if (match != null && value != 'kCredentialImePersonalizedLearning') {
          offenders.add('${file.path}:${i + 1} -> $value');
        }
      }
    }

    expect(offenders, isEmpty, reason: offenders.join(', '));
  });

  test('the four known credential fields are all still covered', () {
    // A count, so DELETING the flag from a site (rather than adding an
    // uncovered one) also fails: the adjacency check above would pass an
    // obscured field that had simply been removed along with its flag.
    final sites = <String>[];

    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_isCode(lines[i]) &&
            lines[i].contains(
              'enableIMEPersonalizedLearning: '
              'kCredentialImePersonalizedLearning',
            )) {
          sites.add(file.path.replaceAll(r'\', '/'));
        }
      }
    }

    expect(
      sites,
      containsAll(<String>[
        'lib/features/auth/widgets/auth_fields.dart',
        'lib/features/settings/widgets/dialogs/change_email_dialog.dart',
        'lib/shared/widgets/dialogs/password_reauth_dialog.dart',
      ]),
    );
    // password_reauth_dialog carries BOTH the Cupertino and Material variants —
    // the pair that shipped broken because only one was ever looked at.
    expect(
      sites
          .where(
            (p) => p.endsWith(
              'shared/widgets/dialogs/password_reauth_dialog.dart',
            ),
          )
          .length,
      2,
    );
  });
}
