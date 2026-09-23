import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/core/data/search_result_cache.dart';

/// The LRU behind both repositories' search caches.
void main() {
  late DateTime now;
  SearchResultCache<String> cache({int maxEntries = 50}) =>
      SearchResultCache(clock: () => now, maxEntries: maxEntries);

  setUp(() => now = DateTime(2026, 9, 1, 12));

  group('TTL', () {
    test('repeated reads do not extend freshness past the original TTL', () {
      final c = cache()..write('q', ['a']);
      now = now.add(const Duration(seconds: 119));
      expect(c.read('q'), ['a']);
      now = now.add(const Duration(seconds: 1));
      expect(c.read('q'), isNull);
    });

    test('a read inside the window returns the stored results', () {
      final c = cache()..write('q', ['a']);
      now = now.add(const Duration(seconds: 119));

      expect(c.read('q'), ['a']);
    });

    test('a read past the window misses', () {
      final c = cache()..write('q', ['a']);
      now = now.add(const Duration(seconds: 121));

      expect(c.read('q'), isNull);
    });

    test('a stale entry is DROPPED, not merely reported missing', () {
      // Otherwise an expired key still occupies an LRU slot, and a surface
      // searching a rotating set of terms evicts live entries to hold dead
      // ones.
      final c = cache()..write('q', ['a']);
      now = now.add(const Duration(seconds: 121));
      c.read('q');

      expect(c.length, 0);
    });

    test('isFresh is the same rule the scan windows use', () {
      final c = cache();
      expect(c.isFresh(now), isTrue);
      expect(c.isFresh(now.subtract(const Duration(seconds: 119))), isTrue);
      expect(c.isFresh(now.subtract(const Duration(seconds: 121))), isFalse);
    });
  });

  group('eviction', () {
    test('the map never grows past maxEntries', () {
      final c = cache(maxEntries: 3);
      for (var i = 0; i < 10; i++) {
        c.write('q$i', ['r$i']);
      }

      expect(c.length, 3);
    });

    test('the OLDEST entry goes first', () {
      final c = cache(maxEntries: 3)
        ..write('a', ['1'])
        ..write('b', ['2'])
        ..write('c', ['3'])
        ..write('d', ['4']);

      expect(c.read('a'), isNull);
      expect(c.read('d'), ['4']);
    });

    test('a READ refreshes recency, so this is an LRU not a queue', () {
      // The re-insert on a hit is the only thing making this true, and it
      // looked like a redundant line in both copies.
      final c = cache(maxEntries: 3)
        ..write('a', ['1'])
        ..write('b', ['2'])
        ..write('c', ['3'])
        ..read('a')
        ..write('d', ['4']);

      expect(c.read('a'), ['1'], reason: 'refreshed by the read above');
      expect(c.read('b'), isNull, reason: 'now the least recently used');
    });

    test('rewriting a key does not consume a second slot', () {
      final c = cache(maxEntries: 2)
        ..write('a', ['1'])
        ..write('a', ['2'])
        ..write('b', ['3']);

      expect(c.length, 2);
      expect(c.read('a'), ['2']);
      expect(c.read('b'), ['3']);
    });
  });

  test('clear forgets everything', () {
    final c = cache()
      ..write('a', ['1'])
      ..write('b', ['2'])
      ..clear();

    expect(c.length, 0);
    expect(c.read('a'), isNull);
  });

  group('in-flight loads', () {
    test('simultaneous identical queries share one load', () async {
      final c = cache();
      final pending = Completer<List<String>>();
      var calls = 0;
      Future<List<String>> load() {
        calls++;
        return pending.future;
      }

      final first = c.getOrLoad('q', load);
      final second = c.getOrLoad('q', load);
      pending.complete(['a']);
      expect(await Future.wait([first, second]), [
        ['a'],
        ['a'],
      ]);
      expect(calls, 1);
    });

    test('clear prevents an old response from refilling the cache', () async {
      final c = cache();
      final pending = Completer<List<String>>();
      final old = c.getOrLoad('q', () => pending.future);
      c.clear();
      pending.complete(['old']);
      await old;
      expect(c.read('q'), isNull);
    });

    test('an old response cannot replace a newer cached result', () async {
      final c = cache();
      final pending = Completer<List<String>>();
      final old = c.getOrLoad('q', () => pending.future);
      c.clear();
      await c.getOrLoad('q', () async => ['new']);
      pending.complete(['old']);
      await old;
      expect(c.read('q'), ['new']);
    });

    test('an old completion leaves a newer request shared', () async {
      final c = cache();
      final oldResponse = Completer<List<String>>();
      final newResponse = Completer<List<String>>();
      final old = c.getOrLoad('q', () => oldResponse.future);
      c.clear();
      final current = c.getOrLoad('q', () => newResponse.future);
      oldResponse.complete(['old']);
      await old;
      final joined = c.getOrLoad('q', () async => ['duplicate']);
      newResponse.complete(['new']);
      expect(await Future.wait([current, joined]), [
        ['new'],
        ['new'],
      ]);
    });

    test('a failed load is not cached and can be retried', () async {
      final c = cache();
      await expectLater(
        c.getOrLoad('q', () async => throw StateError('offline')),
        throwsStateError,
      );
      expect(await c.getOrLoad('q', () async => ['retried']), ['retried']);
    });

    test('a synchronous loader failure can be retried', () async {
      final c = cache();
      await expectLater(
        c.getOrLoad('q', () => throw StateError('offline')),
        throwsStateError,
      );
      expect(await c.getOrLoad('q', () async => ['retried']), ['retried']);
    });
  });
}
