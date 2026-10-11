# 0049. Multi-day span: a 14-day daily window with one day-slice owner

**Date:** 2026-08-03 (span), 2026-08-04 (superset audit), 2026-08-08 (one clamp), 2026-08-10 (mirrors, Plan 2), 2026-08-11 (rules bound, today's window, Live Activity gate), 2026-08-28 (`expandRunWindows`) · **Rules file:** `.claude/rules/appointments.md`

## Context
An appointment may span up to 14 days as a daily window, with no schema change. The rules bound
(`isValidAppointmentSpan`, 2026-08-11) first used a flat `duration.value(14, 'd')`, which refused for about
two weeks each autumn a booking the form had accepted, as an opaque `permission-denied`: the widest run
(09:00 → +14d 09:00) across the fall-back stores 14d 1h, a 14-day all-day block 14d 0h59m.

The 2026-08-04 audit found the range stream is a superset (it starts at `fetchStart`): the day route, the
roster's jobs-today, the employee TODAY panel and the drawer badge reported a fortnight of past jobs as
today's. On 2026-08-11 the dashboard's "Upcoming today" tested `startTime.isAfter(now)` after `runsOn`, so
day 3 of a 14:00 job counted in the status line but rendered "No visits today". `MyDetailsScreen` read
`appointmentsInRangeProvider` raw; the rules rejected the technician's query and a `?? const []` swallowed
it, leaving a permanently failing listener open.

Before the 2026-08-08 clamp, owners disagreed on a corrupt doc: 14 slices on the calendar, "Day 400 of
900" and a year of "1 job today" elsewhere. `_windowsOf` and the run fan-out were the same body twice until
2026-08-28. The Live Activity skip was asserted in this file from 2026-08-10 but built only 2026-08-11
(`docs/archive/2026-08-02-multi-day-appointments.md` §10 had deferred it), so cards counted down a run's
`endTime` through `Text(timerInterval:countsDown:)`.

## Decision
`AppointmentDaySlice` owns day-scoping, `_clampedDayCount` the cap, `expandRunWindows` the window loop,
`runLengthDays` the form length; `functions/day_slice_utils.js` mirrors the Dart. Consumers re-scope
through `runsOn`; the rules bound keeps its +2h DST term.

## Consequences
Re-deriving any of these at a call site reintroduces the drift seen with `displayStatusAt` and `_who`.
