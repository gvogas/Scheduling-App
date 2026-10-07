import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

import '../../fixtures/shared/shared_fixture.dart';

void main() {
  final folds = (loadSharedFixture('accent_fold.json')['folds'] as List)
      .cast<List<dynamic>>();

  test('covers every Latin-1 letter from U+00C0 to U+00FF', () {
    expect(folds.map((f) => f[0]), [for (var c = 0xC0; c <= 0xFF; c++) c]);
  });

  for (final fold in folds) {
    final codePoint = fold[0] as int;
    test('U+${codePoint.toRadixString(16).toUpperCase()} folds to "${fold[1]}"', () {
      expect(
        ClientSearchPolicy.normalize(String.fromCharCode(codePoint)),
        fold[1],
      );
    });
  }
}
