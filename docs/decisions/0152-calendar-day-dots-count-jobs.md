# 0152. Day dots count jobs, not people; cancelled and time off get none

**Date:** 2026-07-31 (off-month and selected dots), 2026-08-04 (jobs not people), 2026-08-17 (cancelled), 2026-08-24 (time off) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
The design said off-month cells are "blank, Ink 15, not tappable" while the program spec widened the fetch range
precisely so trailing days aren't dotless; faint number plus dots reconciled the two (owner-confirmed). Dots were
suppressed under selection, which made the day being looked at the one whose crew was invisible (owner call
2026-07-31). P2 dotted one per distinct assignee and skipped jobs with no colour-resolvable crew, so a day of only
unassigned work read empty; the owner reversed it 2026-08-04 (two jobs for one person are two dots — the dots
answer "how busy is this day"). Cancelled visits (2026-08-17) and then days off (2026-08-24) were dotting as work,
so a holiday week painted as a fortnight of booked days.

## Decision
`dayJobDotColors` emits one entry per job in list order, capped at 3 (week strip: 1), each the job's first
colour-resolvable assignee, `null` painted `palette.textFaint` (the card's unassigned bar colour). `dottedJobsOn`
filters through `countsAsWork` BEFORE the cap; `done` still dots. `CalendarDayCell`'s semantics count uses the same
filter, uncapped. Dots show on off-month, selected and today cells alike.

## Consequences
Dropping the null entry hides unassigned work; capping before filtering lets a cancellation steal a live job's dot;
a raw slice count makes a screen reader describe dots nobody can see.
