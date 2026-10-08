# 0155. Portrait calendar: two scroll areas, a non-scrolling grid capped by a ConstrainedBox

**Date:** 2026-07-31 (two scroll areas, grid never scrolls), 2026-08-31 (ConstrainedBox) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
Portrait splits into two scroll areas so reading down the day never moves the grid (owner call 2026-07-31). The old shared viewport needed a derived `gridHeight − stripHeight` spacer to hold the extent the grid vacated;
with two viewports there is none and the spacer is gone. The grid viewport was a `Flexible`, a flex-1 sibling of
the agenda's `Expanded`, so `RenderFlex` split free space evenly and the grid never exceeded half the pane. A
six-week month wants ~334px at 1.0 scale against ~326 on an iPhone 15, so its last week was clipped by ~11px (99px
on an SE) on the 4–5 six-row months a year — nothing overflowed or logged, because the never-scrolling viewport
absorbs it. A loose `Flexible` cannot express "natural height, capped": leftover space it declines goes to
`MainAxisAlignment`, not to the `Expanded` beside it.

## Decision
The grid is fixed above an agenda `CustomScrollView` with its own `ScrollController` (not primary, so off the
app-wide `Scrollbar`'s single controller). Collapse is a drag or tap on `CollapseHandle`; `CalendarCollapse` banks
24px, resetting on a direction reversal and on `endDrag` so two half-drags don't add up. The grid's `SingleChildScrollView` has `NeverScrollableScrollPhysics` and is bounded by a `ConstrainedBox`
at `_kMaxGridShare` (0.7) of a `LayoutBuilder`'s height in `_portraitContent`; clipping at large text scales is the
accepted fallback.

## Consequences
The column can now overflow where the flex share could not: it holds at 375x667 (the smallest pane that runs the
iOS 18 floor) even at 3x text and overflows ~5px at 320x568 (no supported device). Two tests in
`main_calendar_screen_test.dart` pin it: 390x844 with real safe-area insets (the bare 412x915 harness has ~81px
more pane and passes either way), and 2x text at 375x667. Raising the share or growing the handle or agenda header
spends the margin.
