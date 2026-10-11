# 0100. Client Job history: server-ordered past visits, provider-owned bound

**Date:** 2026-08-13 (`(clientId ASC, startTime DESC)`), 2026-09-28 (`_maxRendered` removed) · **Rules file:** `.claude/rules/clients.md`

## Context
The section filtered on `clientId` alone and sorted in Dart; with no `orderBy` Firestore uses `__name__`
order, so a client with more visits than the cap got an arbitrary slice, and sorting it newest-first made the
wrong page look right. The composite the old note said was needed already existed (`propagateClientEdits`
added it). The section's `_maxRendered` bound moved into the provider on 2026-09-28.

## Decision
`clientJobHistoryProvider` (`autoDispose.family`, re-fetching on `onRecordWrite`) reads
`fetchClientHistory` (`pastOnly: true`) ordered `startTime` DESC with `limit: kClientJobHistoryScan + 1` /
`cap: kClientJobHistoryScan` (60 — 10 of headroom for dropped run days 2+) and keeps `kClientJobHistoryVisits`
(50). `ClientJobHistorySection` renders what it is given.

## Consequences
`orderBy('startTime')` excludes a doc with no `startTime`; `getAppointmentById` is the only read that can
reach one, which is why `_recordFrom` keeps its breadcrumb. The section is a non-lazy `Column` of
`AppointmentCard`s (each an `IntrinsicHeight` subtree); a taller list needs a builder, not a bigger number.
