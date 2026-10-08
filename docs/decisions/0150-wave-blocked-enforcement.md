# 0150. Contract enforcement: the `blocked` state, one evaluation, three points

**Date:** 2026-09-10 (Phase 2), 2026-09-13 (Phase 3 backfill run), 2026-09-19 (audit B1) · **Rules file:** `.claude/rules/wave.md`

## Context
Phase 1 was report-only (`problemsPatch`); Phase 2's `statePatch` replaced it and added `wave.syncState: 'blocked'`. Re-deriving the verdict ran the contract a
second time inside `writeSyncBlocked`'s transaction, where a retry runs it again. A review on 2026-09-10 caught,
before deploy, an import writing dotted keys through `set(..., {merge: true})` (`set` merge: `DocumentMask.fromObject` does
not split dots), so it created a literal `wave.syncState` field, left enforcement inert, never advanced
`wave.lastSyncedHash` (so every imported client re-entered the outbox) and accrued junk fields. Its premise (a
nested map erases siblings) was false; the test asserted the dotted key over a fake batch. The hand-spelled
create copy had drifted into an unreachable `|| "synced"`. Requeuing a refused dead job dead-lettered it again
in the same call. The trigger stamps only edited docs, so `backfill-wave-blocked.js` replays the contract (live
2026-09-13: 726 scanned, 1 patched). Audit B1: a `blocked` client edited back to its last-synced values never
re-ran the contract (the refusal write never touched `lastSyncedHash`). The badge reasons were a `Semantics`
label only until Phase 2 made them visible text. Plan: `docs/plans/2026-09-10-wave-validated-contract-phases-2-4.md`.

## Decision
`verdictPatch` over one verdict; enforce at enqueue, dispatch and import; build state and search tokens in
`stageWrite()` below the skip gates; write one nested map via `waveStateFields`; requeue deletes refused jobs as
`blocked`; `clearStaleBlock` handles the revert case; ship index, app, backend, then the backfill.
`statePatch(fields)` is `verdictPatch(buildCustomerPayload(fields))`. The rollout order was the `wave.syncState` +
`name` index, the app build (1.61.0), the backend, then `backfill-wave-blocked.js` LAST. The backfill treats an
absent `wave.problems` and a derived empty list as EQUAL (else every clean client costs a write per run), reports
and leaves ENTIRELY alone a `blocked` doc that now passes (the push owns the non-blocked state), cancels no queued
job (the dispatcher refuses it), and stays uncapped (`scanByName`); a live run patching 0 against a non-zero
advisory count means the comparison is wrong, not the data. Surfaces: `WaveSyncBadge` shows `blocked` and its
reasons as visible text; `WaveBlockedList` reads `watchBlockedClients()`, admin-only by the read rule.

## Consequences
Deploying enforcement before the app leaves shipped builds with no badge for `blocked` clients. A backfill that
clears problems without state shows a blocked client with no reason.
