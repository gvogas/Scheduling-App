import 'dart:async';

/// A bounded, TTL'd LRU of search results, keyed by normalized query.
class SearchResultCache<T> {
  SearchResultCache({
    required DateTime Function() clock,
    this.maxEntries = 50,
    this.ttl = const Duration(minutes: 2),
  }) : _clock = clock;

  final DateTime Function() _clock;

  /// Bound on retained queries, so a long-lived repository singleton cannot
  /// grow this without limit.
  final int maxEntries;

  /// How long a cached result stands.
  final Duration ttl;

  final Map<String, _CachedSearch<T>> _entries = {};
  final Map<String, Future<List<T>>> _pending = {};
  int _generation = 0;

  /// Changes whenever local writes or session teardown invalidate cached data.
  int get generation => _generation;

  /// Whether something stamped at [fetchedAt] is still inside [ttl].
  bool isFresh(DateTime fetchedAt) => _clock().difference(fetchedAt) < ttl;

  /// The cached results for [key], or null when absent or stale.
  List<T>? read(String key) {
    final cached = _entries[key];
    if (cached == null || !isFresh(cached.fetchedAt)) {
      _entries.remove(key);
      return null;
    }
    _entries.remove(key);
    _entries[key] = cached;
    return cached.results;
  }

  /// Shares an in-flight lookup without retaining results after invalidation.
  Future<List<T>> getOrLoad(String key, Future<List<T>> Function() load) async {
    final cached = read(key);
    if (cached != null) return cached;
    final existing = _pending[key];
    if (existing != null) return await existing;

    final generation = _generation;
    final pending = Future<List<T>>.sync(load);
    _pending[key] = pending;
    try {
      final results = await pending;
      if (generation == _generation) write(key, results);
      return results;
    } finally {
      if (identical(_pending[key], pending)) unawaited(_pending.remove(key));
    }
  }

  /// Stores [results] for [key], evicting the least recently used entry first.
  void write(String key, List<T> results) {
    _entries.remove(key);
    if (_entries.length >= maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _entries[key] = _CachedSearch(results, _clock());
  }

  /// Forgets every entry. Invalidation policy stays with the caller.
  void clear() {
    _generation++;
    _entries.clear();
    _pending.clear();
  }

  /// Retained entry count, for tests that pin the eviction bound.
  int get length => _entries.length;
}

class _CachedSearch<T> {
  const _CachedSearch(this.results, this.fetchedAt);

  final List<T> results;
  final DateTime fetchedAt;
}
