# 0145. Wave push is event-driven; the daily rider is only a drain

**Date:** 2026-08-13 (owner call), 2026-09-13 (daily pull deleted) · **Rules file:** `.claude/rules/wave.md`

## Context
The `waveSyncWorker` scheduler drained `waveSyncQueue` every 5 minutes: up to five minutes of latency, 288
invocations on an idle day, and one of six Cloud Scheduler jobs where only 3 are free per billing account.
`waveScheduledImport` was its own daily export until 2026-08-13.

## Decision
`waveUpsertCustomer` enqueues and drains in one invocation; the drain cannot throw and sits below the
`shouldEnqueueClientWrite` gate. `runWaveDaily` rides `sendDailyJobDigest` and only drains, catching backed-off
and lease-expired jobs. The interactive sync's push is bounded by `SYNC_PUSH_BATCH_LIMIT` /
`SYNC_PUSH_BUDGET_MS`, sized against the client's `kWaveSyncTimeoutSeconds`, not the 300 s function timeout.

## Consequences
A throwing drain re-runs the whole handler under `retry: true` for something a retry cannot fix. A drain above
the gate re-enters on `upsertCustomer`'s own `wave.*` write-back. A polling worker is not the fix for latency. Pinned by `wave_callables.test.js` ("pushes without a poll" / "is the drain
safety net"); the rider call sits in `functions/notifications.js`.
