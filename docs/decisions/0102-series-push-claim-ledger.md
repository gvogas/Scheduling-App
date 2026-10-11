# 0102. Repeat-series pushes collapse through a fail-open claim ledger

**Date:** 2026-07 (ledger), op-id keying later · **Rules file:** `.claude/rules/notifications.md`

## Context
A "this and all future" edit writes up to ~15 sibling docs in one client batch; each fires
`notifyAppointmentChanges`, which meant ~15 pushes and ~15x the reads for one user action. The differ's
anchor rule (`id === seriesId`) covers CREATE only: delete/cancel/reschedule batches often start partway
through a series, so the anchor doc is frequently absent and an anchor-only rule would suppress every
notification. A time-window-only claim then dropped a genuinely separate action: "cancel Tuesday, then
Thursday of the same series" lost the second push.

## Decision
`claimSeriesNotice` claims `appointmentSeriesNotices/{seriesId}_{kind}_{employeeDocId}` (Admin-SDK-only).
WRITES carry a fresh `seriesOpId` from `_newSeriesOpId()` (`firebase_appointments_repository.dart`), one
uuid per write operation, so an `op_<opId>_<kind>_<emp>` collision is definitive and needs no window.
DELETES have no `after` and `before.seriesOpId` is stale, so the call site passes `""` and the claim falls
back to `(seriesId, kind, employee)` plus `SERIES_CLAIM_WINDOW_MS` (45 s; keep it seconds-wide so
separate deletes in one series aren't collapsed) and stale takeover. Every claim
error, and a claim with no readable `createdAt`, sends anyway. `seriesOpId` is write metadata, not on
`AppointmentRecord`. `updateAppointmentStatus` stamps it ONLY on `cancelled`: the employee mark-done rule
is `affectedKeys().hasOnly(['status','updatedAt'])`, so a stray field there is `permission-denied`.

## Consequences
Failing open degrades to one push per sibling, which beats a dropped cancellation for a tech already
driving to the job. The claim's `.doc()` is built inside the `try` because it throws synchronously on an
id containing `/`; an escape would kill every push for the write.
