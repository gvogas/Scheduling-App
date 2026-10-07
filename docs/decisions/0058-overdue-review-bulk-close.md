# 0058. The overdue review is the one bulk close

**Date:** 2026-09-13 (screen), 2026-09-19 (two caps, audit B2; warm grace, audit I2) · **Rules file:** `.claude/rules/appointments.md`

## Context
`OverdueReviewScreen` lists stored-open jobs past their end, so a legacy `confirmed` doc is not listed even
though the server's `OPEN_STATUSES` still counts it for the push. One cap of 500 applied before the
`overdueJobsAt` filter let past personal blocks and days off — which never reach a terminal status and so
sit in this window forever — push the oldest real overdue jobs out of the screen and the badge. Audit B2
split it into a 5000 raw scan and a 1000 post-filter trim, mirroring the server's month-end constants.
Audit I2 held the provider warm for its 15-minute refresh rather than the shared 3, so a reopened drawer
does not re-read the set. `restoreAppointmentStatus` is one doc per call behind a rate limit, so the bulk
action has no Undo and confirms first.

## Decision
One provider feeds screen and badge; two caps with a warn; writes in 450-id chunks through
`updateAppointmentStatuses`, every doc written alone with no scope dialog.

## Consequences
Complete stamps `completedAt` with the review time, not when the work happened (accepted; the dialog says
so).
