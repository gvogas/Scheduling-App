# 0047. Personal jobs and time off

**Date:** 2026-07-31 (personal jobs), 2026-08-11 (optional address), 2026-08-24 (time off), 2026-08-25 (`countsAsWork`; strip layout), 2026-09-06 (P6 cancelled) · **Rules file:** `.claude/rules/appointments.md`

## Context
Personal jobs (`isPersonal`) shipped 2026-07-31 with no client and no address; the owner reversed the
address half on 2026-08-11 (a dentist or supply run still happens somewhere), so `controllers.address` is
the one clear that was removed, and a timed personal job with an address became a real travel candidate
instead of always degrading to the fixed 30-minute reminder. The Lock Screen card read "Client"/"un client"
while the `leaveNow` push read "Dentist" until `title` was threaded through `live_activity_utils.js`'s own
`_who`; four hand-written `ctx` literals had already drifted on `address` normalization, hence
`liveActivityCtx`.

Time off (`isDayOff`, 2026-08-24) is "never counted as a job, always still shown". `countsAsLoadOn` was
kept in step with the roster by a prose comment and had drifted on the cancelled half; since 2026-08-25 it
is `countsAsWork` plus `runsOn`. A short-lived `appointmentChip`/`appointmentChipLabel` resolver and a
`DayOffChip` existed for a day off rendered as a card; the strip (designed in
`docs/archive/2026-08-24-day-off-card.md`) made both unreachable and they were deleted. Two strip clauses
were reversed on 2026-08-25 (the typed reason now leads; the strip has a dashed crew rail) and live in
`lib/features/calendar/CLAUDE.md`. P6 (a `timeOff` collection, request/approve, allowances) was CANCELLED
by owner call 2026-09-06 (`docs/archive/2026-07-29-redesign-program.md`), so the flag is the permanent
answer; it closed the old stopgap's "counts as a job on the dashboard" gap. No rules change was needed:
the appointment validator is per-key bounded, not a `hasOnly`, and type-checks neither `isPersonal` nor
`isAllDay`.

## Decision
Personal jobs keep assignees required, write empty client fields, keep an optional address and fall back
to the title. Time off is asked through `isTimeOff`, counted through `countsAsWork`, rendered as a strip,
completed by derivation, and left in `findBusyEmployees`.

## Consequences
Don't restore a `DayOffChip` or an `AppointmentStatus` member for time off. A day off is never purged by
`purgeExpiredHistory` (it stays `pending`); accepted at a handful per person per year.
