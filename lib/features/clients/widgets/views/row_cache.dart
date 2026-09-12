/// One stable list instance per input key, so a memo keyed on list IDENTITY
/// downstream can hit — `PagingState.items` re-flattens on every access.
class RowCache<T> {
  static const Object _unset = Object();

  Object? _key = _unset;
  List<T> _rows = List<T>.empty();

  List<T> of(Object? key, List<T> Function() compute) {
    if (_key != key) {
      _key = key;
      _rows = compute();
    }
    return _rows;
  }
}
