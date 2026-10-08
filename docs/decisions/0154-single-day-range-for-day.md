# 0154. One owner for a single-day window: `AppointmentDateRange.forDay`

**Date:** undated in the old rules (before 2026-10) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
The day pair was hand-copied at four sites, two citing each other as the authority, with
`add(Duration(days: 1))`, which lands an hour off real midnight on the two DST-shift days. That mis-buckets a
late-evening job, and because `appointmentsInRangeProvider` is keyed by range value, the drifted range stops
matching the one another surface holds open and forks a second live Firestore query for the same day.

## Decision
`AppointmentDateRange.forDay(day)` uses calendar arithmetic (`DateTime(y, m, d + 1)`); `forCalendar`'s selected-day
leg uses it. Every other single-day consumer reuses a range a listener already holds instead of a fresh `forDay`:
`todayRangeProvider` is deliberately `forMirrors` (the range the Siri snapshot holds for an admin all session;
`forDay` there forked a second permanent business-wide listener), the drawer's count reads `todayRangeProvider`,
and the day route uses `forWeekBucketOf`; each re-scopes with `runsOn`. (Corrected 2026-10-07: the old rules
claimed all four resolved through `forDay`.)

## Consequences
A re-derived pair silently doubles listeners on DST days and mis-buckets jobs.
