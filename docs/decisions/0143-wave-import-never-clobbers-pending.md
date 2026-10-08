# 0143. The import never touches a client with an un-pushed outbox job

**Date:** 2026-09-13 (Wave Phase 4, Task 11) · **Rules file:** `.claude/rules/wave.md`

## Context
`importCustomers` overwrites every mapped field of a linked client with Wave's values AND stamps
`wave.lastSyncedHash` from them, so a queued edit was not merely overwritten but marked synced: the pending job
hashed the clobbered doc, matched, returned `noop`, and the edit was gone with nothing logged. Push-before-pull
did not prevent it: the drain is bounded and only takes jobs already due, so a job backed off after a transient
Wave error is invisible to it and still live milliseconds later.

## Decision
Every update to an existing client commits through `commitGuardedUpdates`, whose transaction reads the client's
`customerUpsert__<id>` job and skips the write while it is in `OUTSTANDING_STATUSES`. A concurrent enqueue writes
that job, aborting the transaction, and the retry sees it. A held or failed write counts as `skippedPending`.
`skipClientIds` from `listOutstandingClientIds` is only a prefilter that saves a transaction. Creates, and updates
to a doc created in the same uncommitted batch (`createdInBatch === batch`), stay batched.

## Consequences
Keying on "created this run" instead of the batch object reopens the hole after `flushIfFull` commits. The one
window left open: an edit whose trigger has not enqueued its job yet, a matter of seconds.
