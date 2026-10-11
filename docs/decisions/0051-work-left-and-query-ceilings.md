# 0051. "Work left" gates on the end; every repository query has a ceiling

**Date:** 2026-08-13 (`countFutureAssignments` query and cap), 2026-08-19 (ceilings restored), 2026-08-28/31 (index deleted and restored) · **Rules file:** `.claude/rules/appointments.md`

## Context
Backend sweeps that filter on `startTime` without reaching `MAX_APPOINTMENT_SPAN_DAYS` back caused three
bugs: no overdue prompt for multi-day runs, a digest telling an on-site crew "no jobs tomorrow", and a
long job dropping out of its own travel context. Gating "still live" on `startTime` meant a mid-run
cancel or delete pushed nothing (only the Live Activity card silently vanished) and `propagateClientEdits`
never reached a crew on site; it was a per-module closure in `notification_policy.js` and
`client_propagation.js` before `hasWorkLeft`.

Admitting started jobs made a status filter mandatory: a visit completed this morning still told the
admin to reassign it. Before 2026-08-13 `countFutureAssignments` used `startTime >= now -
maxAppointmentSpanDays` with no upper bound, reading every job from a fortnight ago to the five-year repeat
horizon (`RepeatInterval.maxOccurrences` 120 per series) to render one caption. A `.limit` was chosen over a
horizon bound because `endTime` ASC keeps the soonest-ending jobs and the number stays exact below the cap,
so `employees_disableReassignCaption` needs no rewording; "12 jobs in the next 90 days" would change what
the sentence claims, a product call.

The ceiling invariant broke twice: `deleteTokensOfKind` ran an unbounded subcollection query, and on
2026-08-19 the cleanup commits replaced every named ceiling with an unbounded `while (true)` loop; both were
restored. The `(employeeIds CONTAINS, endTime ASC)` composite was deleted as a "redundant prefix" and
restored 2026-08-31 (`3eebcc93`) after it broke the travel sweep for two days, visible only in the Cloud
Functions log (detail in `.claude/rules/firestore-indexes.md`).

## Decision
Gate on `hasWorkLeft`; test terminal status explicitly in Dart; name a ceiling and warn at it on every
repository query.

## Consequences
Understating the reassign caption tells an admin they have less to reassign than they do. Don't delete an
index as a prefix without checking the query's trailing `orderBy`.
