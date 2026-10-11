# 0118. Month-end overdue review rides the digest

**Date:** 2026-09-13 · **Rules file:** `.claude/rules/notifications.md`

## Context
Admins needed a monthly nudge to close stale jobs without a fourth scheduled function (ADR-0106). Every
rider shares the digest's 540 s timeout, so a rider below Wave can be killed on exactly the evening it
matters. Personal blocks and time off never reach a stored terminal status, so they pile up in the scan
window; a single cap let them eat the reported number. A bulk Complete from the review screen made
`notifyAdminsOfCompletion` send every other admin one push per job closed.

## Decision
`runMonthEndOverdueReview` (`notification_sweeps.js`) runs in its own `try` AFTER the TTL prune and
BEFORE `runWaveDaily` (`notifications_riders.test.js`). It acts only when `isLastDayOfBusinessMonth`
(calendar-day arithmetic on `businessYmd`/`businessDayStartMs`), counts `selectMonthEndOverdue` over
`scanAppointmentWindow` capped at `MONTH_END_SCAN_MAX` (5000, `endTime` DESC on the existing
`(status ASC, endTime DESC)` composite), sends nothing at zero, and reports `1000+` past
`MONTH_END_REVIEW_MAX`. Recipients are `sendToActiveAdmins` narrowed by `includeUser` to
`monthEndReviewPush === true`; it logs `monthEndReview: sent` with the count. Data is
`{kind: 'overdueReview', count}` with no `appointmentId`; text from `buildOverdueReviewMessage`. No
ledger: the host is an `onSchedule` with no retry and `maxInstances: 1`. `updateAppointmentStatuses`
stamps a fresh `seriesOpId` on every status, which `isCrewCompletion` reads as an admin write.

## Consequences
A run that reached nobody is visible in the log (every run, until an admin turns the switch on).
