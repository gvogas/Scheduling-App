# 0189. Range tail query and `isPersonal` equality filters

**Date:** 2026-10-20 · **Rules file:** `.claude/rules/appointments.md`, `.claude/rules/firestore-indexes.md`

## Context
Audit findings P4 and P5 (`docs/audits/UX_PERFORMANCE_REVIEW_2026-10-20.md`). `watchOverdueOpen` read
`status in <open> AND endTime < boundary` and dropped personal blocks and time off only in Dart, so the
scan grew by every past block forever (a day off never reaches a terminal status, ADR-0047) and the 5000-row
window was what kept it bounded. Every range query started at `fetchStart`, 14 days before the window, to
catch a document that starts before it and ends inside it; since ADR-0050 a client job is one document per
day, so that lookback served only personal blocks and time off while widening the calendar window from 44
to 58 days and the mirrors from 8 to 22.

The risk was legacy data. `isPersonal` shipped 2026-07-31; `toMap()` and the server's `readEditableRecord`
(`value ?? false`) have stamped it on every full write since, Wave never writes appointments and no native
path writes Firestore, but no backfill ever ran, so a document created before that date and only patched
since (status, `pictureCount`, lifecycle stamps, `propagateClientEdits`) has NO field, and a Firestore
equality filter excludes it from both `== false` and `== true`. Multi-day client jobs were never split
either (ADR-0050 changed the create path; `count-multi-day-appointments.js` found 3 open runs on
2026-09-10), so a wide client job starting before a window stops being fetched by it.

## Decision
The main range query starts at `range.start`; a second query `isPersonal == true AND startTime in
[fetchStart, start)` with the same `employeeIds` scoping supplies the tail, merged in Dart by one
`docChanges` map per subscription, tail-then-main order, deduped by id, emitting on either. The overdue
query adds `isPersonal == false`; its Dart filter stays. Composites: `(isPersonal ASC, status ASC, endTime
DESC)`, `(isPersonal ASC, startTime ASC)`, `(employeeIds CONTAINS, isPersonal ASC, startTime ASC)`.
`functions/scripts/backfill-appointment-is-personal.js` stamps `isPersonal: false` where the field is
missing (the value the app always read) and reports, never modifies, every non-personal document spanning
two or more work days. Server windows (`overdue_scan.js`, the sweeps) are unchanged: the overdue sweep
already bounds itself to a 2-hour lookback with a rotating cursor and filters personal in JS.

## Consequences
Indexes `READY` and the backfill run are prerequisites of the app build (`docs/DEPLOYMENT.md` §4d); shipped
first, every pre-2026-07-31 overdue job leaves the review until the backfill lands. A legacy wide client job
that starts before a calendar window is no longer shown in it (History still lists a closed one); the
script's report is the owner's call on re-booking an open one per day. The tail at `_rangeStreamLimit` is
a ceiling with a warn like the main query.
