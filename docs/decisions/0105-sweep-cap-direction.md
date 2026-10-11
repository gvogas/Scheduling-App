# 0105. A sweep cap keeps the jobs the sweep is about: order by direction

**Date:** 2026-08-13 (overdue), 2026-08-16 (digest fix) · **Rules file:** `.claude/rules/notifications.md`

## Context
`sendDailyJobDigest`'s floor is `tomorrowStart - MAX_APPOINTMENT_SPAN_MS`, ~15 days in the past. Its
query ordered `startTime` ASC, reasoning copied from the travel sweep, whose window starts at `now`. Once
a tail of unclosed jobs passed 1000, the cap kept the OLDEST, `groupTomorrowsJobsByEmployee` found no
overlap, and every crew silently got no digest. The overdue sweep queried `startTime` until 2026-08-13,
which forced a floor of 24 h plus the longest span (~15 days), re-read every open job of two weeks 96
times a day, and lost any run longer than `MAX_APPOINTMENT_SPAN_DAYS` written by console/Admin SDK.

## Decision
The digest orders `startTime` DESC on the `(status, startTime DESC)` composite and reverses in memory
before grouping. The overdue sweep (`runOverduePromptSweep`) queries `endTime` over `OVERDUE_LOOKBACK_MS`
(2 h, sized to the 5-minute cadence, not to an outage) with bounds `> floor`, `<= now` that mirror
`selectOverdueCandidates` exactly, ordered `endTime` DESC on the `(status, endTime DESC)` composite.
`OVERDUE_QUERY_WINDOW_MS` is gone. `TRAVEL_SWEEP_MAX`, `OVERDUE_SWEEP_MAX` (500) and `DIGEST_SWEEP_MAX`
(1000, `notification_policy.js`) all warn at the cap through `scanAppointmentWindow`.

## Consequences
The wrong direction silently spends the cap on the wrong jobs. Without the `(status, endTime DESC)` index
deployed the sweep fails `FAILED_PRECONDITION` and prompts nobody. A doc with no `endTime` is excluded by
the filter. The overdue nudge mirrors the display-only `overdue` state; keep it in step with
`AppointmentRecord.displayStatus`.
