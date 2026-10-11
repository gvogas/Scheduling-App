# 0138. Push decisions live in `notification_policy.js`; sweeps are imported from their own module

**Date:** 2026-08-02, 2026-09-28, 2026-09-29 · **Rules file:** `functions/CLAUDE.md`

## Context
On 2026-08-02 the clock/data rules behind push (`diffAppointmentForNotifications`,
`selectOverdueCandidates`, `groupTomorrowsJobsByEmployee`, `tomorrowWindowToronto`, `ledgerBody`,
`overduePromptLedgerId`, `recordOf`, `contextFor`, the kind-priority and recipient-role tables) moved
out of `notification_utils.js` into a module with no `deps`, no db and no messaging.
`notification_utils.js` re-exports each under its original name, so `notifications.js` and the jest
tests did not change. The three scheduled sweeps (`runOverduePromptSweep`, `runDailyDigest`,
`runMonthEndOverdueReview`) live in `notification_sweeps.js`, which requires `notification_utils.js`; a
reverse re-export was papered over with lazy getters until 2026-09-29. On 2026-09-28 the travel decisions
and constants (`PRESENCE_STALE_MINUTES`, module-private and read by the Dart mirror test;
`TRAVEL_SWEEP_MAX`; `CONTEXT_QUERY_MAX`) moved to `travel_policy.js`, re-exported by `travel_utils.js`.

## Decision
A helper that needs `deps` stays in `notification_utils.js`; a new pure rule goes in
`notification_policy.js` and is re-exported. Import the sweeps from `notification_sweeps.js`.

## Consequences
Growing the orchestration file back hides pure rules behind mocks. Re-exporting the sweeps from
`notification_utils.js` is a require cycle.
