import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every shared fixture is read by a Dart test AND a jest test', () {
    final fixtures = Directory('test/fixtures/shared')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .toList();
    expect(fixtures, isNotEmpty);

    final dartSources = _sources('test', '.dart');
    final jestSources = _sources('functions/__tests__', '.js');
    for (final name in fixtures) {
      expect(
        dartSources.any((s) => s.contains("'$name'")),
        isTrue,
        reason: '$name has no Dart reader (loadSharedFixture)',
      );
      expect(
        jestSources.any((s) => s.contains('fixtures/shared/$name')),
        isTrue,
        reason: '$name has no jest reader',
      );
    }
  });
}

List<String> _sources(String root, String extension) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith(extension))
    .map((f) => f.readAsStringSync())
    .toList();
