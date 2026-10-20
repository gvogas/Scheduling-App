import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One focus node per validated field, so a failed Save can bring the first
/// errored field into view instead of shaking it below the fold.
///
/// [order] lists the validator's error keys in on-screen order; [shared] maps
/// a key onto the key whose node it rides (several rows in one panel).
class FormErrorFocus {
  FormErrorFocus(this.order, {this.shared = const {}});

  final List<String> order;
  final Map<String, String> shared;
  final _nodes = <String, FocusNode>{};

  /// The node for [key], created on first use. Hand it to the field's
  /// `focusNode`, or to the `SheetFocusScroll` wrapping a non-text field.
  FocusNode nodeFor(String key) {
    final owner = shared[key] ?? key;
    return _nodes.putIfAbsent(owner, () => FocusNode(debugLabel: owner));
  }

  /// Focuses the first errored field in [order] and buzzes; false when none of
  /// [errored] is a known key.
  bool focusFirstError(Iterable<String> errored) {
    final set = errored.toSet();
    for (final key in order) {
      if (!set.contains(key)) continue;
      nodeFor(key).requestFocus();
      unawaited(HapticFeedback.mediumImpact());
      return true;
    }
    return false;
  }

  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    _nodes.clear();
  }
}
