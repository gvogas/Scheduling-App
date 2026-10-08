# 0081. `travelAlertsEnabled` defaults ON and is read before the Routes call

**Date:** 2026-08-10 (travel-time notifications), 2026-08-11 (flag read before the Routes call) · **Rules file:** `.claude/rules/employees.md`, `.claude/rules/notifications.md`

## Context
Every users doc written before the field existed has no value, so an `undefined`-is-off reading would silence
departure alerts fleet-wide, and a push that never arrives is never reported. The flag was first read only where the
push `kind` was chosen: the escalation was suppressed, but the lead time was still travel-derived, so an opted-out
tech got the generic "Upcoming job" push up to `MAX_LEAD_MINUTES` (90, `travel_policy.js`) early on a long drive, and the business still paid Google
Routes for an estimate that changed nothing.

## Decision
Absent reads as ON on both sides (`wantsTravelAlerts`, `EmployeeRecord.fromMap`). The flag gates only the `leaveNow`
escalation: an opted-out assignee gets the fixed 30-minute `reminder`, the same degradation as a missing origin or a
Routes failure. `resolveReminderForAssignee` skips the whole `decideOrigin`/`computeTravelSeconds` block when it is off, so `travelSeconds` stays null;
`travel_utils.test.js` ("an opted-out assignee") asserts the sweep never calls `fetchImpl`. It is a SERVER flag
(unlike the device-local Live Activity switch beside it — the sweep picks the push kind, so a local preference could
never reach it), its Settings row is hidden until the person's own record loads rather than rendered against a
guessed default, and `toMap()` omits it so an admin save leaves it exactly as it was.

## Consequences
Absent `locationSharingEnabled` reads the opposite way (OFF); don't unify the defaults.
