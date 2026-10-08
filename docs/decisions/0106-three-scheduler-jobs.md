# 0106. Three scheduled functions: riders instead of new timers

**Date:** 2026-08-13 · **Rules file:** `.claude/rules/notifications.md`

## Context
Cloud Scheduler bills per job beyond the first three; the repo had six. `sendOverdueJobPrompts`
(`every 15 minutes`) was folded into `sendUpcomingJobReminders`, `waveScheduledImport` into
`sendDailyJobDigest` (as `runWaveDaily()`), and `waveSyncWorker` was deleted.

## Decision
The overdue sweep rides the 5-minute reminder timer; running it three times as often is safe because the
per-recipient ledger (`appointmentOverduePrompts/{id}_{endMs}_{employeeDocId}`, create-fails-if-exists),
never the cadence, guarantees at-most-once. Ledgers release a claim with zero delivered pushes, keyed per
assignee so a late-registering token is retried without re-notifying anyone, and write `expiresAt` +7 d
for a console TTL. Every rider sits in its own `try`, below the digest. The log label
`sendOverdueJobPrompts failed` stays: it is a stable search tag.

## Consequences
A fourth scheduled function starts costing money; reach for an existing sweep first.
