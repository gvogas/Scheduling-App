# 0131. Two responsive gates; the nav rail is gone

**Date:** 2026-07-30 (rail deleted) · **Rules file:** `.claude/rules/frontend.md`

## Context
`AdaptiveShell`, the nav rail, `Breakpoints.expanded` and `isExpanded` were deleted 2026-07-30; the drawer
became the nav surface at every size. A landscape phone is wide enough for the calendar split but too
narrow for a readable list detail pane, and a pane swapping in on rotation was unwanted.

Gate values (`breakpoints.dart`): `tablet` 840, `tabletShortestSide` 600, `compactWidth` 360,
`compactTextScale` 1.4, `Breakpoints.shortViewportHeight` 700.

## Decision
`isSplitLayout` gates only the calendar split; `isTwoPane` (shortest side ≥ 600, orientation-independent)
gates list master-detail.

## Consequences
Don't reintroduce a rail or size-gated drawer, or gate master-detail on `isSplitLayout` or a raw width.
