# 0045. Mark-complete has no clock gate, a pinned `updatedAt`, and an Undo callable

**Date:** 2026-07 (`hasStarted` gate), 2026-08-17 (no clock gate), 2026-08-28 (`updatedAt` pin), 2026-09-04 (Undo) · **Rules file:** `.claude/rules/appointments.md`

## Context
The 2026-07 rule hid the button until `!appointment.startTime.isAfter(now)`, because the edit form's status
picker is admin-only and an employee who missed the button before midnight (or was on day 2+ of a
multi-day visit) had no other way to close a job the server kept nudging them about. The owner call of
2026-08-17 widened it to no clock gate at all: the same reasoning holds before the start time, for a crew
that finishes early. The rules never date-restricted an assignee's `status:'done'`.
Admitting `updatedAt` unpinned in the `hasOnly(['status', 'updatedAt'])` diff let a modified client stamp an
arbitrary value while closing a job (audit-trail integrity, not an exploit; nothing server-side branches
on it), so 2026-08-28 pinned it to `request.time`.
Mark-complete became undoable on 2026-09-04 through `restoreAppointmentStatus` rather than a rules grant.

## Decision
`DetailsActionBar` offers mark-complete on every open job. The mark-done branch refuses only from
`cancelled` (a `done`/`completed` → `done` write is allowed) and pins `updatedAt`. Undo goes
through the callable, which re-checks completed status, caller scope (`mayRestore`) and an open target,
rate-limits 30/hour, and deletes `completedAt`.

## Consequences
Don't add a clock test back. Don't widen an employee disjunct to allow reopening; it would let an assignee
reopen anything at any age.
