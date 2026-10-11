# 0055. The server owns the job time record

**Date:** 2026-09-01 · **Rules file:** `.claude/rules/appointments.md`

## Context
The 2026-09-01 audit found no `startedAt`/`completedAt` anywhere. Status changes arrive from an assignee's
Start job or mark-done, the admin edit form's picker and series propagate, so a client-side stamp would
either widen the mark-done rules branch or leave the admin picker path unstamped. Stamping in the write
trigger costs one extra write and one silent trigger re-fire per transition;
`notification_lifecycle.test.js` proves the re-fire produces no stamp, no event and no completion push.
Start job got its own disjunct rather than a second value on the mark-done one, whose `status == 'done'`
is its whole guarantee.

## Decision
`lifecycleStamps` decides and `stampLifecycle` writes, on transitions only; no client writes either field;
`toMap()` omits both.

## Consequences
New documents (`addAppointments`, `rewriteSeries` copies) must not inherit another job's record. Don't move
the stamp client-side to save the write.
