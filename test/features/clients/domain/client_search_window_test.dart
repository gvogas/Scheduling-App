import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_record.dart';
import 'package:scheduling/features/clients/domain/models/client_search_window.dart';

ClientRecord _client(String id, String phone) =>
    ClientRecord(id: id, name: phone, phone: phone);

void main() {
  final marie = _client('c1', '5145628332');
  final jp = _client('c2', '5145628901');

  group('canNarrowTo', () {
    test('a longer prefix of the same number narrows', () {
      const window = ClientSearchWindow(
        digits: '5145628',
        results: [],
        truncated: false,
      );
      expect(window.canNarrowTo('51456283'), isTrue);
      expect(window.canNarrowTo('5145628332'), isTrue);
    });

    test('a shorter or different query does not', () {
      const window = ClientSearchWindow(
        digits: '5145628',
        results: [],
        truncated: false,
      );
      expect(window.canNarrowTo('514562'), isFalse);
      expect(window.canNarrowTo('4385628332'), isFalse);
    });

    // F5: at the cap the answer is incomplete, so the client we want may never
    // have come back. Filtering it further hides a real match silently.
    test('a truncated window never narrows', () {
      const window = ClientSearchWindow(
        digits: '5145628',
        results: [],
        truncated: true,
      );
      expect(window.canNarrowTo('5145628332'), isFalse);
    });

    test('an empty window never narrows', () {
      expect(ClientSearchWindow.empty.canNarrowTo('5145628332'), isFalse);
    });
  });

  group('narrowTo', () {
    test('keeps only the clients still matching', () {
      final window = ClientSearchWindow(
        digits: '5145628',
        results: [marie, jp],
        truncated: false,
      );
      final narrowed = window.narrowTo('5145628332');
      expect(narrowed.results, [marie]);
      expect(narrowed.digits, '5145628332');
      expect(narrowed.truncated, isFalse);
    });

    test('a narrowed window can be narrowed again', () {
      final window = ClientSearchWindow(
        digits: '514',
        results: [marie, jp],
        truncated: false,
      );
      expect(window.narrowTo('5145628').narrowTo('5145628332').results, [
        marie,
      ]);
    });

    test(
      'narrowing to nothing yields an empty result set, not a miss flag',
      () {
        final window = ClientSearchWindow(
          digits: '5145628',
          results: [marie, jp],
          truncated: false,
        );
        expect(window.narrowTo('5145628777').results, isEmpty);
      },
    );
  });
}
