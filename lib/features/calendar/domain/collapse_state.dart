/// Drag accounting for the calendar's month-grid collapse. Held apart from the
/// widget so the threshold rule is testable without a gesture.
///
/// The gesture is a drag on the **divider between the calendar and the jobs**
/// (owner call, 2026-07-31), not the jobs' own scroll: the grid is fixed above
/// the list, so reading down the day never moves it, and collapsing is always
/// something the user asked for on the handle itself.
class CalendarCollapse {
  /// Distance the handle must travel before the grid gives way. Past the slop
  /// of a tap, short enough that one deliberate flick does it.
  static const double dragThreshold = 24;

  bool get isCollapsed => _collapsed;
  bool _collapsed = false;

  /// Distance dragged since the last transition or [endDrag].
  double _travel = 0;

  /// Feeds one drag delta ([dy] negative upward, as `DragUpdateDetails` gives
  /// it). Returns true when the collapsed flag flipped — the caller rebuilds
  /// only on a transition, never per gesture frame.
  bool onDragDelta(double dy) {
    // Reversing direction restarts the count, so a wobble on the way up can't
    // bank travel toward the opposite transition. A dy of exactly 0 is not a
    // reversal — a frame that moved purely sideways would otherwise throw away
    // the travel banked so far and force the user to re-drag the full 24px.
    if (dy != 0 && _travel.sign != dy.sign) _travel = 0;
    _travel += dy;
    final wants = _collapsed
        ? _travel >= dragThreshold
        : _travel <= -dragThreshold;
    if (!wants) return false;
    _collapsed = !_collapsed;
    _travel = 0;
    return true;
  }

  /// Clears the accumulated travel when the finger lifts, so two separate
  /// half-drags don't add up into one transition.
  void endDrag() => _travel = 0;

  /// The handle is also a button, for anyone not making a 24px drag.
  void toggle() {
    _collapsed = !_collapsed;
    _travel = 0;
  }

  /// Applies a remembered state (the per-device preference) without a gesture.
  void restore({required bool collapsed}) {
    _collapsed = collapsed;
    _travel = 0;
  }
}
