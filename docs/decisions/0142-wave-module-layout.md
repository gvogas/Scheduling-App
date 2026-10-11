# 0142. Wave module layout: an acyclic leaf, one outbox require path, one connection reader

**Date:** 2026-08-19 (customer split), 2026-09-07 (connection reader), 2026-09-13 (outbox split, Wave Phase 4 Task 10) · **Rules file:** `.claude/rules/wave.md`

## Context
Until 2026-08-19 the pull lived in `customers.js` with the push, which forced the pull half to require the push
half back at RUN time (a `pushHalf()` shim) and made `customers.js` export three internals under a comment
saying they were not public. The outbox was later split into five modules; both
`jest.mock("../wave/worker")` suites (`wave_callables.test.js`, `wave_triggers.test.js`) intercept by the
`./worker` path. The `wave/connection` doc-get and field coercion were spelled out at eight sites across the
callables, the daily rider and `sync_run.js`.

## Decision
Three customer files: push in `customers.js`, pull in `customers_import.js`, shared reads in the leaf
`customer_queries.js`, which requires nothing; `customers.js` re-exports `importCustomers`, so
`sync_run.js`, `callables.js` and the jest suite still `require("./customers")`. `worker.js` re-exports the outbox modules and every production
caller requires `./worker`. `readWaveConnection` / `connectionFieldsOf` own the connection read;
`readWaveConnection` returns the `ref` because the sync hands it to `importWithWatermark`; `connectionFieldsOf` is the
same coercion over a snapshot in hand, for the bootstrap transaction. File roles: `customers.js` holds
`upsertCustomer`/`writeSyncSuccess`; `customers_import.js` holds `importCustomers`, `importOneCustomer`,
`buildWaveIdIndex`, `BATCH_LIMIT`; the leaf holds `readBusinessId` and `LIST_CUSTOMERS`/`LIST_CUSTOMERS_SINCE`.
Outbox: `enqueue.js` (enqueue decision, enqueue, cancel), `dispatch.js` (`drainQueue`), `outbox_core.js` (claim,
lease, outcome guard), `outbox_queries.js` (counts, requeue, protect-list), leaf `outbox_keys.js`.

## Consequences
A require back from `customers_import.js` (even a lazy one) makes whichever file loads second see a half-built
`exports`. A direct submodule require silently escapes the jest mock.
