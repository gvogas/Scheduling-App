# 0146. Sync and Retry responses report every outcome; requeue runs in chunks

**Date:** 2026-08-15 (Retry `failed`) · **Rules file:** `.claude/rules/wave.md`

## Context
A broken push, a bounded push and an empty queue all produced identical zeros, and the app said "everything was
already up to date" while edits sat undelivered. "Retry failed" exists because a job that died on a
`WaveValidationError` dies again, so the drain behind the requeue routinely dead-lettered it a second time in the
same call; reporting only `requeued` showed "1 client queued for Wave again" over a Settings row still reading
"1 client failed to sync". A serial requeue of a bulk backfill's few hundred dead jobs spent 12-20 s of the
callable's budget before the drain ran.

## Decision
The sync returns `pushedPending`, `pushedFailed` and `pushIncomplete`; Retry returns `failed` beside `pushed`,
null meaning unknown. `tallyUpsert` counts only committed outcomes. `requeueDeadJobs` runs `REQUEUE_CHUNK`-sized
concurrent batches with a per-job catch; the transactions touch distinct documents, so there is nothing to
serialize for. `waveRetryFailedJobs` binds `WAVE_FULL_ACCESS_TOKEN` because its drain pushes to Wave.

## Consequences
Response fields are additive only; an older build ignores unknown ones. Rendering null as zero recreates the
silent-success bug.
