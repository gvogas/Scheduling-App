import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/employees/domain/policies/self_service_fields.dart';

/// Dart and CEL cannot share a constant, so this test is the only mechanism
/// keeping the two allowlists equal. The rules use `hasOnly`, so a self write
/// carrying a key they do not name fails in FULL — and reaches the user as an
/// opaque `permission-denied` on a save that looks perfectly ordinary.
void main() {
  test('the Dart allowlist equals the rules allowlist', () {
    final fn = RegExp(
      r'function isAvailabilityOnlyChange\(\)\s*\{(.*?)\}',
      dotAll: true,
    ).firstMatch(File('firestore.rules').readAsStringSync())?.group(1);

    expect(fn, isNotNull, reason: 'isAvailabilityOnlyChange() was removed');
    final inRules = RegExp(
      "'([A-Za-z]+)'",
    ).allMatches(fn!).map((m) => m.group(1)!).toSet();

    expect(kSelfServiceUserFields, equals(inRules));
  });

  test('isTestAccount is admin-only, so nobody can un-hide themselves', () {
    expect(kSelfServiceUserFields, isNot(contains('isTestAccount')));
  });

  test('updatedAt is in the set', () {
    // Every write path stamps it, so the rules must permit it — `hasOnly` is
    // exact about what MAY appear, not about what must.
    expect(kSelfServiceUserFields, contains('updatedAt'));
  });
}
