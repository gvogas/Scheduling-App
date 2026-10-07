import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/core/search/search_tokens.dart';
import 'package:scheduling/features/clients/domain/policies/client_search_policy.dart';

import '../../fixtures/shared/shared_fixture.dart';

// Shared examples live in test/fixtures/shared/search_tokens.json.
void main() {
  final fixture = loadSharedFixture('search_tokens.json');

  group('searchQueryTokens', () {
    for (final c in sharedCases(fixture, 'queryTokens')) {
      test(c['name'] as String, () {
        _expectTokens(searchQueryTokens(c['query'] as String), c);
      });
    }
  });

  group('searchIndexTokens', () {
    for (final c in sharedCases(fixture, 'indexTokens')) {
      test(c['name'] as String, () {
        final texts = (c['texts'] as List).cast<String>();
        final phones = (c['phones'] as List).cast<String>();
        final limit = c['limit'] as int?;
        final tokens = limit == null
            ? searchIndexTokens(texts: texts, phones: phones)
            : searchIndexTokens(texts: texts, phones: phones, limit: limit);
        _expectTokens(tokens, c);
      });
    }

    test('honours the field cap', () {
      final tokens = searchIndexTokens(
        texts: [for (var i = 0; i < 200; i++) 'word$i'],
        phones: ['5145554321'],
      );
      expect(tokens.length, kSearchTokenFieldLimit);
    });
  });

  group('normalize', () {
    for (final c in sharedCases(fixture, 'normalize')) {
      test(c['input'] as String, () {
        expect(ClientSearchPolicy.normalize(c['input'] as String), c['expect']);
      });
    }
  });
}

void _expectTokens(List<String> tokens, Map<String, dynamic> c) {
  expectAsserts(c, const ['expect', 'expectContains', 'expectLength']);
  if (c.containsKey('expect')) expect(tokens, c['expect']);
  if (c.containsKey('expectContains')) {
    expect(tokens, contains(c['expectContains']));
  }
  if (c.containsKey('expectLength')) {
    expect(tokens, hasLength(c['expectLength']));
  }
}
