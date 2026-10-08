# 0104. Travel-aware "time to leave" reminders degrade, never regress

**Date:** 2026-07-18 (deployed), 2026-08-13 (candidate cap) · **Rules file:** `.claude/rules/notifications.md`

## Context
The fixed 30-minute reminder ignored drive time. `runTravelAwareReminderSweep` (`travel_utils.js`, pure
decisions and constants in `travel_policy.js`) picks an origin per (job, assignee): intervening job's
address, then a presence fix at most 25 min old, then a job that ended within 4 h, then none. It calls the
Routes API `computeRoutes` with `TRAFFIC_AWARE` and fires at `startTime - driveTime - 10 min`. The
candidate query was the only sweep with no ceiling; a bulk import or wide series landing in the 90-minute
window was an unbounded fan-out making a BILLABLE Routes call per assignee.

## Decision
Every failure (no origin, empty address, any Routes error) degrades to the fixed 30-minute `reminder`
kind; `leaveNow` sets APNs `interruption-level: time-sensitive`. It reuses the
`appointmentReminders/{id}_{startMs}_{employeeDocId}` ledger and key, so old claims stay honored. The
candidate read is capped at `TRAVEL_SWEEP_MAX` (500), `startTime` ASC (keeps the most imminent; a deferred
one self-heals next run), warns at the cap, on the existing `(status, startTime ASC)` composite. The
per-employee context read (`loadContextByEmployee`) is capped at `CONTEXT_QUERY_MAX` (50), `endTime` ASC,
with an `endTime` upper bound of `TRAVEL_WINDOW_MS + MAX_BOOKING_MS`. Estimates are memoized per
(job, assignee) for `ESTIMATE_TTL_MS` (10 min) and may only DEFER a Routes call by `SKIP_MARGIN_MS`.

## Consequences
Removing the context `.limit()` re-reads every future appointment each sweep; narrowing its bound to the
travel window drops an intervening job that runs a day longer from `decideOrigin`'s first prong. A cached
estimate that TRIGGERS a send fires on stale traffic. Needs the Routes API enabled on the
`GOOGLE_MAP_API_KEY` restriction.
