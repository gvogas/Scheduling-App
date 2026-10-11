# 0141. Wave callables: a kept name, one admin guard, a server-side business

**Date:** 2026-08-04 (two-way sync), 2026-09-07 (`assertAdminCall`) · **Rules file:** `.claude/rules/wave.md`

## Context
`waveImportCustomers` became a two-way sync on 2026-08-04: it drains the outbox via `drainForSync` before it
imports. The name was first tagged with the `#compat-1.37.1` shim, but the constraint outlived it: renaming a
deployed callable deletes the one every shipped build calls, breaking "Sync with Wave" on every phone until it
updates. The five Wave callables each hand-spelled their auth/`assertAdmin`/payload opening until 2026-09-07.
`waveGetConnection` gained a durable limit once it stopped being a single-document read (two `count()`
aggregates on `waveSyncQueue` for the Settings outbox depth). The in-app business picker was removed, and there
is no `waveListBusinesses` callable, so the business name never ships in the app.

## Decision
Keep the name. Open every Wave callable with `assertAdminCall`. Rate-limit `wave-connection` 60/hour and
`wave-retry` 10/hour. Resolve the business server-side from `WAVE_BUSINESS_NAME` via `listBusinesses`; the
token is `WAVE_FULL_ACCESS_TOKEN` in Secret Manager, no OAuth. `waveGetConnection` is the app's only Wave read.

## Consequences
The `assertAdminCall` switch changed no allowlist key, so it broke no build. An in-place rename, or a client read of the
rules-locked `wave` collection, breaks shipped builds; a rename needs the two-step (new name alongside, a build
calling it, then drop the old).
