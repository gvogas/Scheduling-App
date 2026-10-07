import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/images/image_magic.dart';

import '../../fixtures/shared/shared_fixture.dart';

// Shared with functions/__tests__/maintenance.test.js through
// test/fixtures/shared/image_magic.json — the server half DELETES a failing upload.
void main() {
  group('hasValidImageMagic', () {
    for (final c in sharedCases(
      loadSharedFixture('image_magic.json'),
      'cases',
    )) {
      test(c['name'] as String, () {
        expect(
          hasValidImageMagic((c['bytes'] as List).cast<int>()),
          c['expect'],
        );
      });
    }
  });
}
