import 'package:flutter/foundation.dart';

/// The ticked jobs on the overdue review, and whether a write is running.
@immutable
class OverdueReviewState {
  const OverdueReviewState({this.selected = const {}, this.isApplying = false});

  final Set<String> selected;
  final bool isApplying;

  OverdueReviewState copyWith({Set<String>? selected, bool? isApplying}) =>
      OverdueReviewState(
        selected: selected ?? this.selected,
        isApplying: isApplying ?? this.isApplying,
      );
}
