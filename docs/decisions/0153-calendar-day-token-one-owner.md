# 0153. Day token: today is a ring, selection a fill, one owner

**Date:** 2026-08-14 · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
Today used to be a blue NUMBER, which was also the picker/field accent, so "today" and "the value you picked" spoke
the same language. Three widgets render a day token — `CalendarDayCell`, the week strip and the form's
`InlineMonthCalendar` — each with a hand-written copy of the rule, two carrying a comment asserting they matched
the third; they had already drifted on the gate condition.

## Decision
`calendarDayCircleDecoration` (`widgets/views/calendar_day_circle.dart`) owns it: today is an `onSurface` ring
(a literal white vanishes in light), selection a filled circle, and selection wins (a ring over a fill is noise).
Sizes and number colour stay per-cell; `fill` takes a tint. `InlineMonthCalendar` renders from the same
`month_grid.dart` helpers and hoists its long-date `DateFormat` out of its 42 cells.

## Consequences
A fourth hand copy re-opens the drift; the picker and the screen must never disagree about where a day sits or
where the week starts.
