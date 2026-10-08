# 0114. Live Activity content: server-built text, countdown, real departure time

**Date:** 2026-07-21 (`endTime` countdown), 2026-07-27 (`startsAt` fallback) · **Rules file:** `.claude/rules/notifications.md`

## Context
A travel-phase card with no known `leaveAt` labelled the job's own `startTime` "Leave at", so a
rescheduled job told the tech to leave exactly when they were due to arrive. The old `setCardPhase` wrote
phase only, so a reschedule left `marker.startTime` stale: a job moved earlier flipped past the real
arrival, a job moved later re-pushed a travel update every sweep. Under the series claim, which sibling
sends the push is nondeterministic, but each occurrence owns its own card.

## Decision
Card text is built server-side in EN/FR from the `_MESSAGES`-shaped table in `live_activity_utils.js`,
never `NSLocalizedString`. `buildContentState`/`buildAttributes` mirror
`ios/ScheduleWidget/LiveActivitiesAppAttributes.swift`. The content state carries `endTime`, so the
on-site card counts down to the scheduled end (`Text(timerInterval:countsDown:true)`), falling back to
count-up past the end or without `endTime`; thread it through every dispatch `ctx`. With no `leaveAt`,
`buildContentState` renders `startsAt` ("Starts at" / "Débute à"). `writeCardMarker` persists
`leadMinutes`/`travelMinutes`; `updateLiveActivity` rebuilds `leaveAt` from them (`_withLeaveAt`), fed by
`_liveRowsFor`'s `{rows, marker}`, and refreshes start+phase via `setCardStart` (a merge that never
overwrites those two fields) on EVERY update; `listCardsDueForOnSite` keys off `marker.startTime`. The
reschedule refresh runs per occurrence ABOVE the series-claim gate in `handleAppointmentWrite`.

## Consequences
A dropped `endTime` silently loses the countdown. `live_activity_dispatch.js` defines its own `MINUTE_MS`;
never import it from `travel_utils.js`, which requires this module (a cycle). `travel_policy.js` exports
one without a cycle. A deactivated employee
has no marker or tokens, so the per-occurrence refresh cannot resurrect a card.
