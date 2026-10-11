# 0007. Server-side image cascade and a debounced, always-on recount

**Date:** 2026-08-13 (added, +2 exports), 2026-08-15 (debounce), 2026-08-28 (shared claim module) · **Rules file:** `.claude/rules/images.md`

## Context
Firestore does NOT delete a subcollection when its parent is deleted, so without
`cascadeDeleteAppointmentImages` every appointment delete leaves `appointments/{id}/images/*`
orphaned: invisible in the console, unreachable by every query the app makes, reported by nothing. At
the CONTRACT step the client lost the array it enumerated to delete bytes, so without the server half
every delete orphans its photos in Storage, paid for monthly. `maintenance.js` once hard-coded the
literal `"images"`; a rename would have left the purge deleting an empty prefix and reporting success
on the one path with no other way to find those bytes.

An `if (before.exists && after.exists) return` guard on the recount was written and removed: it
skipped only the offline queue replaying `set(..., {merge: true})` on the derived id and a backfill
re-run — the counter's only self-heal — and bought nothing against the real amplification:
`appendAppointmentPictures` writes N docs in ONE batch, so N recounts hit one parent within
milliseconds (against ~1 write/sec/document), all genuine creates; and every parent write re-fires
`notifyAppointmentChanges` (10 photos was 10 recounts and 11 notification invocations for one user
action). The fix (2026-08-15) was to DEBOUNCE, never to suppress the replay: a
`create()`-fails-if-exists claim (same shape as `claimSeriesNotice`) lets the first trigger of a
batch recount and the other N−1 return having written nothing. `recursiveDelete` is the same
Admin-SDK bulk writer `syncUsersByUid` uses for `liveActivityTokens`.

Until 2026-08-28 `appointment_images.js` carried a byte-identical second copy of all six claim bodies,
the drift the shared module was extracted to prevent. They moved to `functions/recount_claim.js`, shared with the client `jobCount` counter;
`CLAIM_STALE_MS` / `CLAIM_TTL_MS` live there, not as `RECOUNT_CLAIM_STALE_MS` / `_TTL_MS` here.

The replay self-heal survives because the claim never outlives its batch: it is deleted on the
normal path, `CLAIM_STALE_MS` (15 s) takes over one abandoned by a killed invocation, and the
`expiresAt` TTL policy (`firestore.indexes.json`, offset 0) is only housekeeping behind both — so a
later, separate write (the offline queue's replay, a backfill re-run) always claims afresh and
recounts. The claim path fails open on any ledger error: an extra parent write is exactly the old
behaviour, while a skipped recount is a wrong count with nothing left to notice it.

## Decision
The cascade deletes bytes then documents and rethrows; the recount is an absolute `count()` on every
write, debounced by a claim released BEFORE the aggregate runs.

## Consequences
A suppressed sibling's photo was committed before its trigger fired, and its trigger fired before the
release, so a strongly-consistent `count()` after the release necessarily sees it. Counting first and
releasing after lets a photo written in the gap be both suppressed and uncounted. Releasing first also lets a `retry: true` retry of a failed parent
`update()` re-claim instead of suppressing itself. `pictureCount` exists because `AppointmentCard`
renders on every range-query surface and cannot afford a subcollection read each. Don't add an
"unchanged" guard, an increment, or a second claim implementation, and don't make the claim path
fail closed or let a claim outlive its batch.
