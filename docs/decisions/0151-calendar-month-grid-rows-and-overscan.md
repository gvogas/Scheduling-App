# 0151. Month grid: our own widget, derived row count, ±7-day overscan

**Date:** 2026-07-30 (P2 rebuild), 2026-07-31 (variable rows), 2026-08-13 (overscan narrowed) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
P2 deleted `table_calendar` for our own `CalendarMonthGrid` + `CalendarMonthPager`. A fixed 6 rows trailed a
week of nothing but off-month cells (owner call 2026-07-31); a fixed 5 drops the end of months like August 2026.
With variable rows the pager animates its height, so a taller month dragged in overflowed before the height
settled. `visibleMonth` overscanned ±14 days, a superset of every grid shape including the fixed-6 one, costing a
fortnight of documents per month view on top of the fortnight `fetchStart` already adds. `weekStartForLocale`
builds a `DateFormat` to read its symbols and was asked by grid, pager and week strip on every rebuild.

## Decision
`monthGridRowCount` derives 4, 5 or 6 rows; `heightFor` takes a required `rows`; each page is clipped
(`ClipRect` + top-aligned `OverflowBox`). Overscan is ±7 (`_gridOverscanDays`): the grid trails at most 6
off-month days a side, so 7 clears the worst case by one. `weekStartForLocale` is memoized per locale string and
widgets resolve it through `CalendarMonthGrid.weekStartOf(context)`.

## Consequences
The fetch window is now sized to the row rule: restoring a fixed row count leaves edge cells dotless.
`month_grid_overscan_test.dart` walks every month across a leap cycle at all seven week starts so that breaks
loudly.
