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
      final file = RegExp.escape(name);
      expect(
        _calls(dartSources, RegExp("loadSharedFixture\\(\\s*'$file'\\s*\\)")),
        isTrue,
        reason: '$name has no Dart reader (loadSharedFixture)',
      );
      expect(
        _calls(
          jestSources,
          RegExp('require\\(\\s*["\'][^"\']*fixtures/shared/$file["\']'),
        ),
        isTrue,
        reason: '$name has no jest reader (require)',
      );
    }
  });
}

/// True when [call] appears on a code line, so a comment naming a fixture can't count as a reader.
bool _calls(List<String> sources, RegExp call) => sources.any(
  (source) => source.split('\n').any((line) {
    final code = line.trimLeft();
    final isComment =
        code.startsWith('//') || code.startsWith('*') || code.startsWith('/*');
    return !isComment && call.hasMatch(line);
  }),
);

List<String> _sources(String root, String extension) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith(extension))
    .map((f) => f.readAsStringSync())
    .toList();
