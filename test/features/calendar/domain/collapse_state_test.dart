import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/collapse_state.dart';

void main() {
  test('collapses once the handle is dragged 24px up', () {
    final collapse = CalendarCollapse();
    expect(collapse.onDragDelta(-10), isFalse);
    expect(collapse.onDragDelta(-13), isFalse);
    expect(collapse.isCollapsed, isFalse);
    expect(collapse.onDragDelta(-2), isTrue);
    expect(collapse.isCollapsed, isTrue);
  });

  test('dragging back down re-expands', () {
    final collapse = CalendarCollapse()..onDragDelta(-40);
    expect(collapse.isCollapsed, isTrue);
    expect(collapse.onDragDelta(30), isTrue);
    expect(collapse.isCollapsed, isFalse);
  });

  test('dragging down while expanded does nothing', () {
    final collapse = CalendarCollapse();
    expect(collapse.onDragDelta(300), isFalse);
    expect(collapse.isCollapsed, isFalse);
  });

  test('reversing direction restarts the count', () {
    final collapse = CalendarCollapse()
      ..onDragDelta(-20)
      // A wobble the other way must not bank toward the threshold.
      ..onDragDelta(5);
    expect(collapse.onDragDelta(-20), isFalse);
    expect(collapse.isCollapsed, isFalse);
    expect(collapse.onDragDelta(-5), isTrue);
  });

  test('two separate half-drags do not add up', () {
    final collapse = CalendarCollapse()
      ..onDragDelta(-20)
      ..endDrag();
    expect(collapse.onDragDelta(-20), isFalse);
    expect(collapse.isCollapsed, isFalse);
  });

  test('reports a transition only once per crossing', () {
    final collapse = CalendarCollapse();
    expect(collapse.onDragDelta(-30), isTrue);
    expect(collapse.onDragDelta(-30), isFalse);
    expect(collapse.onDragDelta(-30), isFalse);
  });

  test('restoring a remembered state applies it and drops banked travel', () {
    final collapse = CalendarCollapse()
      ..onDragDelta(-20)
      ..restore(collapsed: true);
    expect(collapse.isCollapsed, isTrue);
    // The 20px banked before the restore must not count toward re-expanding.
    expect(collapse.onDragDelta(20), isFalse);
    expect(collapse.onDragDelta(4), isTrue);
    expect(collapse.isCollapsed, isFalse);
  });

  test('tapping the handle toggles it without a drag', () {
    final collapse = CalendarCollapse()..toggle();
    expect(collapse.isCollapsed, isTrue);

    collapse.toggle();
    expect(collapse.isCollapsed, isFalse);
  });

  test('a full collapse and re-expand cycle can repeat', () {
    final collapse = CalendarCollapse();
    for (var i = 0; i < 3; i++) {
      expect(collapse.onDragDelta(-40), isTrue, reason: 'collapse pass $i');
      expect(collapse.onDragDelta(40), isTrue, reason: 'expand pass $i');
    }
  });
}
