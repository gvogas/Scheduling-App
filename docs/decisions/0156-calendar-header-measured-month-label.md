# 0156. Calendar header: measured month label, not a text-scale gate

**Date:** P2 (2026-07-30) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
The calendar has no `AppTopBar`: a `PreferredSizeWidget` cannot host the week strip that rises on collapse, so
`CalendarHeaderBlock` replaces it and must set the system overlay itself. The month name was switched to its
abbreviation by a text-scale threshold, but the in-app XL setting is exactly 1.4, which the `isCompact` gate
(`> 1.4`) missed entirely; the OS scaler, device width and the locale's month lengths all move independently.

## Decision
The screen passes `monthLabel` and `monthLabelShort` (`DateFormat.MMMM` / `.MMM`); `_MonthRow` measures the row
(minus year and chevron, `measureTextWidth`) and takes the abbreviation when the full name won't fit. The semantics label always speaks
the full month.

## Consequences
Don't "simplify" back to a scale threshold. The widget test asserts against viewport width, not a scale, because
the test font is far wider per glyph than the shipped one.
