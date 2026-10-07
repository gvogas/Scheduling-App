import 'dart:convert';
import 'dart:io';

/// Reads a fixture shared with the jest suite (see README.md beside this file).
Map<String, dynamic> loadSharedFixture(String name) =>
    jsonDecode(File('test/fixtures/shared/$name').readAsStringSync())
        as Map<String, dynamic>;

/// The cases under [key], typed for iteration.
List<Map<String, dynamic>> sharedCases(Map<String, dynamic> fixture, String key) =>
    (fixture[key] as List).cast<Map<String, dynamic>>();

/// Fails a case that carries none of [keys], so a typo'd key can't pass vacuously.
void expectAsserts(Map<String, dynamic> c, List<String> keys) {
  if (!keys.any(c.containsKey)) {
    throw StateError('Shared fixture case asserts nothing: $c');
  }
}
