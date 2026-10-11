import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Active admin, resolved through the `usersByUid` bridge" has FOUR
/// independent implementations — `firestore.rules`, `storage.rules`,
/// `functions/security.js` and `functions/employee_accounts_self.js`. Six
/// tests already read `firestore.rules` back; nothing read `storage.rules`, which
/// makes it the least-observed copy of a rule whose documented historical bug
/// was precisely a missing `status == 'active'` in a bridge gate.
///
/// Drop that clause from `storage.rules` and a DISABLED admin keeps minting
/// download URLs for every appointment photo in the business, keeps uploading
/// and keeps deleting — with nothing failing anywhere. Rules cannot be
/// unit-tested without the emulator, so this reads both files back as TEXT and
/// pins that both clauses are present, the same idiom as
/// `self_service_fields_test.dart`.
void main() {
  /// The body of the `isAdmin()` helper in [path].
  ///
  /// Brace-matched rather than cut at the first `;` — `storage.rules` resolves
  /// the bridge into a `let` first, so a semicolon cut stops one statement
  /// short of the two clauses under test and would pass on an empty gate.
  String adminGate(String path) {
    final source = File(path).readAsStringSync();
    final start = source.indexOf('function isAdmin()');
    expect(
      start,
      greaterThan(-1),
      reason:
          '$path has no isAdmin() helper — a gate spelled inline at each call '
          'site is a fifth copy nothing observes',
    );
    final open = source.indexOf('{', start);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('$path: isAdmin() has no closing brace');
  }

  for (final path in const ['firestore.rules', 'storage.rules']) {
    group("$path's admin gate", () {
      test('requires the bridge doc to name the admin role', () {
        expect(adminGate(path), contains("role == 'admin'"));
      });

      test('requires the bridge doc to still be active', () {
        // Load-bearing, not belt-and-braces: the usersByUid bridge doc SURVIVES
        // deactivation, so without this an admin `syncUsersByUid` has already
        // disabled keeps full access until someone notices.
        expect(adminGate(path), contains("status == 'active'"));
      });
    });
  }

  test('storage.rules resolves the caller through the usersByUid bridge', () {
    // `firestore.rules` reaches the bridge through its own `userByUid()`
    // helper; `storage.rules` has no such helper and spells the lookup out, so
    // the path itself is what there is to pin here.
    expect(
      adminGate('storage.rules'),
      contains(r'usersByUid/$(request.auth.uid)'),
    );
  });
}
