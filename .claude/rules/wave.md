---
paths:
  - "functions/wave/**"
  - "functions/scripts/*wave*"
  - "lib/features/wave/**"
  - "lib/features/settings/**"
  - "test/features/wave/**"
  - "test/features/settings/**"
---

# Wave Accounting integration

Loaded when working on the Wave sync (`functions/wave/*`). Root context: `../../CLAUDE.md`; functions overview:
`../../functions/CLAUDE.md`; reference: `docs/CLOUD_FUNCTIONS.md`. Client-side client rules — the sync badge,
`clients/{id}.name` as Wave's customer name — are in `clients.md`.

## Callables and the app boundary

- Never read the rules-locked `wave` collection client-side: the Settings Wave section calls `waveGetConnection` on mount for "Connected to X", the app's ONLY Wave read path. Keep the full-access token in Secret Manager (`WAVE_FULL_ACCESS_TOKEN`) only — no OAuth. (ADR-0141)
- Resolve the Connect business server-side: `waveBootstrap` reads the `WAVE_BUSINESS_NAME` secret when the client sends no `businessId`/`businessName`, so `_connect()` passes no selector and the name never ships in the app. (ADR-0141)
- Open all five Wave callables (`waveBootstrap`, `waveImportCustomers`, `waveGetConnection`, `waveSetImportSchedule`, `waveRetryFailedJobs`) with `assertAdminCall`, App Check enforced. Durably rate-limit (`enforceDurableRateLimit`) all but `waveSetImportSchedule` (`waveBootstrap` only on its not-yet-connected path): `wave-connection` 60/hour, `wave-retry` 10/hour. (ADR-0141)
- Never rename `waveImportCustomers` in place, though it is a TWO-WAY sync (drains the outbox via `drainForSync`, then imports) — renaming a deployed callable deletes the one every shipped build calls; a rename needs the two-step. (ADR-0141)
- Keep `waveSetImportSchedule` deployed as an accepted-and-ignored no-op (`#compat-1.61.0`, the 1.61.0 picker still calls it): the `schedule` allowlist key stays; no `wave/connection` read, no write, no rate limit; it logs `WAVE-SCHED ignored a retired cadence call`. Remove it only once that line is quiet AND no build ≤ 1.61.0 remains, in its own deploy (`docs/DEPLOYMENT.md` §4a). (ADR-0147)
- Pass every GraphQL string as a variable — Wave refuses inline `String` arguments (`GRAPHQL_VALIDATION_FAILED`); inline `Int`/`Boolean` pass. (ADR-0148)

## Module layout

- Put code both customer halves need in the leaf `wave/customer_queries.js`, which requires nothing; never require `customers.js` from `customers_import.js`, even lazily — the second-loaded file sees a half-built `exports`. (ADR-0142)
- Require the outbox through `./worker` (it re-exports `enqueue.js`, `dispatch.js`, `outbox_core.js`, `outbox_queries.js`, `outbox_keys.js`) from every production caller — the `jest.mock("../wave/worker")` suites intercept by that path, so a direct submodule require silently escapes the mock. (ADR-0142)
- Read `wave/connection` only through `readWaveConnection` / `connectionFieldsOf` (`wave/sync_run.js`); `readWaveBusinessId` is a projection, not a second read. (ADR-0142)

## Outbox and push

- Make the job claim AND the outcome write transactional: `commitOutcome` writes `done`/`queued`/`dead` only while the job is still `inflight` with the same `claimedAt`, and the lease reclaim pass is one read+write transaction. Never an unconditional `update` — it clobbers a client edit that re-enqueued mid-dispatch.
- Push on the event: `waveUpsertCustomer` (`clients` trigger) enqueues AND drains in one invocation. Keep that drain wrapped so it cannot throw (the job is durably queued; a throw re-runs the handler under `retry: true` for nothing) and BELOW the `shouldEnqueueClientWrite` gate, which stops `upsertCustomer`'s own `wave.*` write-back re-entering the drain. (ADR-0145)
- Never reintroduce a polling worker (`waveSyncWorker` is deleted) for a latency complaint — check the trigger's drain and the daily sweep first. Keep `runWaveDaily` ONLY a drain, riding `sendDailyJobDigest` rather than its own export: the net for jobs on `nextAttemptAt` backoff and `inflight` jobs of a dead instance (reclaimed by `drainQueue`'s lease pass), neither of which produces a client write. The pull runs only from "Sync with Wave". (ADR-0145)
- Keep the sync's push best-effort and bounded (`SYNC_PUSH_BATCH_LIMIT` 20, `SYNC_PUSH_BUDGET_MS` 20 s, `sync_run.js`); its failure never fails the import (the `waveUpsertCustomer` trigger and the daily sweep already cover it). Size the bounds against `kWaveSyncTimeoutSeconds` (120, `wave_service.dart`, hand-mirrored), not the 300 s function timeout — a callable can't be cancelled, so past the client deadline the admin has been told it failed and taps again. (ADR-0145)
- Never report a zero counter as success: the sync response carries `pushedPending` (a `count()` AFTER the drain), `pushedFailed` (`drained.dead` — dead jobs aren't `queued`, so the count misses them) and `pushIncomplete` (drain or count threw); `waveRetryFailedJobs` carries `failed` (`drained.dead`) beside `pushed`, since its drain routinely dead-letters the same job again. Null means unknown — never render it as "nothing failed". Response fields are additive only. (ADR-0146)
- Count `drainQueue`'s `created`/`updated` through `tallyUpsert`, incremented only where `done` is (a committed outcome), so a superseded job isn't counted in two drains; `linked` counts as an update (it patches a customer a crashed attempt created). (ADR-0146)
- Run `requeueDeadJobs`' per-job transactions in `REQUEUE_CHUNK` (25) concurrent batches, not serially; the per-job catch keeps one stubborn job from aborting the recovery. Its best-effort drain follows so the press shows a result — which is why `waveRetryFailedJobs` binds the `WAVE_FULL_ACCESS_TOKEN` secret. (ADR-0146)
- In `requeueDeadJobs`, ask the contract about each dead job's client: DELETE a refused one, write the reason onto the client and count it `blocked` (additive, NOT a failure), because requeuing it would dead-letter it again; requeue a job whose client doc is MISSING — the dispatcher already treats that as a clean skip. (ADR-0150)
- Re-evaluate a `blocked` client edited BACK to its last-synced values (`isBlockedRevertToSynced`, `enqueue.js`): Rule 2 returns false and nothing else would re-run the contract, so the trigger's `clearStaleBlock` writes `verdictPatch(…, {clearedState: 'synced'})` only if it now passes. The predicate excludes the Rule 1 (unmapped edit) case, so the verdict write's re-fire is inert. Pinned by `wave_triggers.test.js`. (ADR-0150)

## Import

- Never let an import touch a client with an un-pushed outbox job — it overwrites the edit AND stamps `wave.lastSyncedHash`, so the job returns `noop` and the edit vanishes reading "synced"; push-before-pull is not enough. Commit every update to an existing client through `commitGuardedUpdates` (`customers_import.js`), whose transaction skips while its `customerUpsert__<id>` job is in `OUTSTANDING_STATUSES` (`queued`/`inflight`/`dead`, `outbox_keys.js`); a held OR failed write counts `skippedPending`. `skipClientIds` (`listOutstandingClientIds`) is only a prefilter. (ADR-0143)
- Batch only creates and updates to a doc created in the SAME uncommitted batch (`createdInBatch === batch`) — keyed on the batch object, not "this run", since after `flushIfFull` commits an admin can edit the new client. (ADR-0143)
- Skip a linked client whose `wave.lastSyncedHash` equals `mappedFieldsHash(fromWaveCustomer(node))` (`skippedUnchanged`), so `updated` counts real changes; the equality is exact, both sides hashing the `toWaveCustomerInput` projection `shouldEnqueueClientWrite`'s Rule 2 relies on. Keep the `hasCreatedAt` half — the update branch alone backfills a missing `createdAt`. (ADR-0144)
- Write `createdAt`/`updatedAt` on every imported client (both on create; backfill `createdAt` only when missing) — the clients list and search order by `createdAt`, and Firestore excludes a doc missing the orderBy field.
- Keep `LIST_CUSTOMERS_SINCE` a separate document from `LIST_CUSTOMERS`, never one query with a nullable `modifiedAtAfter` — read as `null`, it imports nothing and reports success. (ADR-0144)
- Keep `importCustomers` stateless about the watermark: `importWithWatermark` (`wave/sync_run.js`) owns read → decide → import → advance, deciding via the pure `resolveImportWindow`/`watermarkPatch` (`wave/import_schedule.js`). (ADR-0144)
- Advance the watermark only over a FULLY covered window: hold it on a throw, on `skippedPending > 0` (those clients' Wave change would be invisible to every later delta) and on an unknown `skippedPending` (holding is free; advancing wrongly loses data). Set it to the run's START minus `DELTA_OVERLAP_MS` (5 min), never its end. (ADR-0144)
- Retry a delta-only failure once as a FULL import; log, never throw, a failed watermark WRITE — the import already committed. Run a full pass every 7 days (`FULL_RESYNC_INTERVAL_MS`) as the backstop for Wave's unverifiable `modifiedAt`; the import never deletes a local client. Build `buildWaveIdIndex` lazily, so a no-op delta costs zero reads. (ADR-0144)
- Land an imported customer's number in the ONE `phone` field with `mobile: ''` (`importedPhone`, `wave/mappers.js`; see `clients.md`). (ADR-0144)

## Refusals and dead-letters

- Relink, never dead-letter, a `waveCustomerId` for a customer Wave no longer has — the bad id is STORED, so every push and "Retry failed" fails identically. `upsertCustomer` routes both shapes (`isStaleCustomerLink`: a top-level `WaveApiError('graphql')` whose `details[].extensions.code` is `NOT_FOUND`; `hasNotFoundInputError`: a `NOT_FOUND` inputError; `wave/customers.js`) into the create path with the identity search FORCED on, so it relinks rather than duplicating. (ADR-0148)
- Let `writeSyncSuccess` overwrite a link only via `replacesLink`, and only while the stale id is still on the doc (a concurrent link is newer and wins). Keep both predicates structured, never a text match on Wave's message — this one path rewrites a client's Wave identity. (ADR-0148)
- Never send a value outside a Wave ENUM's vocabulary; omit the field — an unknown enum value is a top-level, non-retryable GraphQL error, a permanent dead-letter. `toProvinceCode`/`toCountryCode` (`wave/mappers.js`) test MEMBERSHIP in `SUBDIVISION_CODES`/`ISO_COUNTRY_CODES`, not shape; resolve country BEFORE province in `toWaveCustomerInput`, since the province prefix follows it. Same for any new enum field. (ADR-0148)
- Keep `sanitizeError` for the job's `lastError` and the client's `wave.syncError` (the app reads those); put the reason in `describeWaveError` (`wave/retry_policy.js`), logged as `errorDetail` on the dead-letter `logger.error`: `extensions.code`, `path`, the `at "…"` field fragment, `Expected type`. Take ONLY the quoted run after `at` — the value before it is customer data. (ADR-0148)

## Customer contract

- Let `wave/customer_contract.js` alone answer "will Wave accept this client?": `buildCustomerPayload` returns a payload plus hash, or `problems` naming the CLIENT DOC field an admin edits, never a Wave payload path — the UI points at an input with it. (ADR-0149)
- Don't "fix" the length gap by lowering the `firestore.rules` caps (`name` 225, `address` 533 vs Wave's 200/500): a cap below a stored value makes the doc permanently un-updatable (`clients.md`); the contract refuses it and keeps it editable. (ADR-0149)
- Mark each problem `blocking` or `advisory`; only `blocking` decides `ok`, spelled ONCE in `buildCustomerPayload` — everything else asks `ok`; never re-add a `blockingProblems` export. Record both severities; the audit reports them separately and deliberately does NOT gate on `ok` (gating would hide advisory-only clients). (ADR-0149)
- Write a contract rule only from an OBSERVED Wave rejection, never a plausible one (hence `NOT_DIALABLE` is advisory); the email rule is unproven. (ADR-0149)
- Read caps from `IMPORT_FIELD_CAPS` (`mappers.js`), never restate them; `importCap` THROWS at require time — an undefined cap reports every client `TOO_LONG`, which is blocking, so every client would be refused and the push stop. (ADR-0149)
- Keep `toWaveCustomerInput` exported (~50 `wave_mappers.test.js` cases drive it with inputs the contract refuses); `__tests__/wave_contract_is_sole_producer.test.js` holds the boundary — a production call site outside `mappers.js`/`customer_contract.js` fails it, and it pins the enqueue gate running BEFORE the enqueue. (ADR-0149)

## Enforcement (`blocked`)

- Write `wave.problems` and, when something blocks, `wave.syncState: 'blocked'` through `statePatch` — a state apart from `error`, which may retry, because a `blocked` client never will until its data is edited. `wave.problems` is not a mapped field, so the hash is unchanged and `shouldEnqueueClientWrite` stops the re-fire. (ADR-0150)
- Take verdict and patch from ONE evaluation: `verdictPatch(verdict, opts)` over the verdict in hand; `upsertCustomer` passes its own, never re-running the contract inside `writeSyncBlocked`'s transaction. (ADR-0150)
- Enforce at three points, one implementation. ENQUEUE: `waveUpsertCustomer` never queues a refused client, and `cancelCustomerUpsert` deletes an earlier job only while `queued` (the worker re-reads the live doc; an `inflight` job belongs to a live claim — `commitOutcome`'s invariant). DISPATCH: `upsertCustomer` returns `{status: 'blocked'}` and writes the state, never throws `WaveValidationError` (that dead-letters permanently). IMPORT: same contract, so the pull can't write what the push could never send. (ADR-0150)
- Re-run the contract in `importOneCustomer` over the fields it is about to write (stored problems describe the OLD doc; a blank-named Wave customer must not land `synced`), building `statePatch` and `clientSearchTokens` in `stageWrite()` BELOW the skip gates; the `mappedFieldsHash` above them is the gate's own hash and stays. (ADR-0150)
- Write ONE nested `wave` map via `waveStateFields(patch)` in both import branches, never dotted keys: `set(..., {merge: true})` does not split dots — it creates a literal `wave.syncState` field — while a nested map merges per leaf and erases no sibling. Dots are for `update()` only; the import test asserts no written key contains a dot. (ADR-0150)
- Ship any new `wave.syncState` value app-first — `_badgeConfig` (`wave_sync_badge.dart`) renders nothing for an unknown state. (ADR-0150)
- Run `functions/scripts/audit-wave-contract.js` (read-only) after any change to the contract, the mappers or `ClientNamePolicy`; `backfill-wave-blocked.js` rules are in ADR-0150.

## Settings UI

- Share ONE busy flag: `WaveSettingsSection._busy` includes `_retryBusy` — Retry drains the same queue as Sync.
- Let `WaveProblemList` own the problem sentences (badge and Settings can't word one failure two ways); `WaveBlockedList` is the only place refused clients appear — they are in neither outbox counter. (ADR-0150)
