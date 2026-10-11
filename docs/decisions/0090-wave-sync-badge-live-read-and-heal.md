# 0090. Wave sync badge reads the live doc; a no-op push heals sync state

**Date:** 2026-08-07 (live read), 2026-08-13 (inline drain) · **Rules file:** `.claude/rules/clients.md`

## Context
`wave.syncState` is function-owned: `waveUpsertCustomer` stamps `pending` after the save returns and, since
2026-08-13, enqueues and drains inline within seconds (the `waveSyncWorker` scheduler is deleted). Every
client surface but the detail is a one-shot read, and the edit sheet pops a `copyWith` carrying the pre-edit
sync state (`waveSyncState` is not the form's to write), so the badge sat on "Synced with Wave" while the
push was queued. Separately, two edits that put the mapped fields BACK left a job with nothing to push:
`shouldEnqueueClientWrite` rule 2 skipped the second write, and `upsertCustomer`'s noop short-circuit left
`pending` (or `error`) forever instead of `synced`.

## Decision
`ClientDetailView` watches `clientStreamProvider` (`autoDispose.family` over `ClientsRepository.watchClient`),
falling back to the handed-in record. That listener does not patch the search cache. The noop path calls
`healSyncState`, which re-reads and re-hashes inside the transaction and writes `syncState`/`syncError`
only, never `lastSyncedAt`. `tallyUpsert` counts `noop` as nothing.

## Consequences
An optimistic client-side `pending` would fork `mappedFieldsHash`'s projection into Dart. Trusting the
caller's hash can mark an edit synced while it still sits in the outbox. The heal's write re-fires the
trigger harmlessly (rule 1).
