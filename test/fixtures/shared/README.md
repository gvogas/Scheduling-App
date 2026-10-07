# Shared Dart/JS fixtures

Worked examples for code that exists twice — once in `lib/`, once in `functions/`.
Both suites read these files; neither keeps its own copy. Add a new example HERE, never inline in one test.
Dart: `loadSharedFixture('x.json')` (`shared_fixture.dart`). Jest: `require("../../test/fixtures/shared/x.json")`.
`test/shared_fixtures_registry_test.dart` fails if a file here loses its reader on either side.
