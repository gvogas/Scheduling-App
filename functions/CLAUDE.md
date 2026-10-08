# Cloud Functions (functions/)

Root context `../CLAUDE.md`. Per-function reference: `docs/CLOUD_FUNCTIONS.md`; release runbook: `docs/DEPLOYMENT.md`.

## Wiring

- Keep `index.js` a thin re-export of 32 functions under their original names; `docs/DEPLOYMENT.md` uses that count as a deploy abort check, so update it with any add or remove. (ADR-0030)
- Add a function to its domain module and re-export it from `index.js`; shared guards go in `security.js`, shared secrets in `params.js`, never back in `index.js` or a feature module. (ADR-0135)
- Define each secret once: `params.js` owns `GOOGLE_MAP_API_KEY`, `APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`; never re-`defineSecret` one or re-export it from a feature module.
- Every function carries a JSDoc block (`require-jsdoc` + `valid-jsdoc`; see `code-quality.md`). Run `cd functions && npm run lint` (eslint-config-google, 80-char lines) before any deploy.

## Module map

| Area | Modules (key exports) |
|---|---|
| Guards | `security.js`: `assertPayloadShape`, `requireString`, `optionalString`, `requireNumberInRange` (rejects `NaN`/`Infinity`), `requireDocId`, `readSessionToken`, `enforceDurableRateLimit`, `assertAdmin`, `hasControlChar`, `isReauthStale`, `assertFreshReauth`, `assertAdminCall`, `assertActiveCall`, `shortHash`, `APP_CHECK` |
| Accounts | `account.js` (`deleteAccount`) + `account_policy.js`; `employee_accounts_admin.js` (`createEmployeeAccount`, `deleteEmployeeAccount`, `resetEmployeePassword`); `employee_accounts_self.js` (`completeEmployeeSetup`, `completePasswordReset`, `changeEmployeeEmail`); `account_operation.js` (`withAccountOperation`) |
| Bridge | `bridge.js` (`syncUsersByUid`), `bridge_reconcile.js`, `bridge_policy.js` |
| Clients | `clients.js` (`deleteClient`), `client_propagation.js` (`propagateClientEdits`), `client_job_count.js` (`recountClientJobs`, pure `clientsToRecount`), `client_buildings.js` (`syncClientBuilding`), `recount_claim.js`, `client_address_utils.js`, `client_name_utils.js` |
| Search / actions | `indexed_search.js` (`searchClients`, `searchHistory`, `findAppointmentConflicts`; the token hit is a PREFILTER re-verified by `recordMatchesQuery`, `mayReadHistoryDoc` re-checks a non-admin against `employeeIds`, `blocksProposedWindow` applies the daily-window rule), `search_tokens.js` (hand-mirror) — see `.claude/rules/search.md`; `appointment_actions.js` (`restoreAppointmentStatus`) |
| Images | `maintenance.js` (`validateUploadedImage`, `purgeExpiredHistory`) + `maintenance_policy.js`, `image_magic.js`, `appointment_images.js` (`cascadeDeleteAppointmentImages`, `recountAppointmentPictures`) — see `.claude/rules/images.md` |
| Push | `notifications.js`, `notification_*.js`, `travel_*.js`, `widget_payload_utils.js`, `apns_client.js`, `live_activity_*.js` — see `.claude/rules/notifications.md` |
| Time | `time_utils.js`, `day_slice_utils.js` |
| Shared leaves | `admin_firestore.js` (`adminFirestore()`), `appointment_scan.js` (`scanAppointmentWindow`), `firestore_errors.js`, `params.js` |
| Flags | `feature_flags_policy.js` (pure), `feature_flags.js` (lazy `firebase-admin/remote-config`, 60 s per-instance cache) |
| Places | `places.js` (`placesAutocomplete`, `placesGetDetails`, `placesReverseGeocode`) |
| `wave/` | see `.claude/rules/wave.md`. `callables.js` (admin callables only), `triggers.js`, `sync_run.js` (ONE owner of import/drain and `readWaveBusinessIdCached`), `customers.js` (push), `customers_import.js` (pull, `BATCH_LIMIT`), `customer_queries.js` (leaf with `readBusinessId`, requires nothing — keeps push/pull acyclic), `retry_policy.js` (pure) |

## Shared owners — import, never re-spell

- `security.js` composers and order: see `.claude/rules/security.md` (ADR-0040). `assertActiveCall` returns the profile (`role`/`docId`) and proves a live account, never access to a document, so per-doc scoping stays at the call site.
- `requireDocId`: a required id ≤128 chars with no `/` — the slash half is load-bearing, since `.doc()` throws synchronously and reaches the caller as an opaque `internal`. Throws `invalid-<key>`; `notification_policy.js`'s `toIdList` filters instead and does not use it. (ADR-0135)
- `recount_claim.js` (`claimRecount`/`releaseRecount`/`debounceRecount`) is the ONE claim-ledger owner for `recountClientJobs` and `appointment_images.js`'s `debouncedRecountPictures`. Never re-spell its release-BEFORE-aggregate order — wrong is silent. Don't fold in `claimSeriesNotice` (`notification_utils.js`): it claims and HOLDS for dedupe. Only the client adapter gates on `mayShareABatch` — ungated, a single create/delete pays a 2 s settle plus a claim create+delete (2 → 4 writes), while a photo write is always part of a batch. (ADR-0136)
- `client_address_utils.js` (`streetFromAddress`/`composeFullAddress`, hand-mirror of `AddressParser.streetOnly`/`composeFull`): `client_propagation.js` must not import from `wave/`. (ADR-0139)
- `time_utils.js` stays dependency-free (any require closes the `notification_utils` → `live_activity_dispatch` → `live_activity_utils` cycle) and owns `toMillis`, `formatBusinessTime`/`formatTimeOfDay`, `businessYmd`/`businessOffsetMs`/`businessMidnight`, `BUSINESS_TIME_ZONE`; never re-inline a `toMillis` or a bare `timeZone: "America/Toronto"`. (ADR-0137)
- `businessDayStartMs` (`(instant, offsetDays)`) owns "business-local midnight, n days out": a CALENDAR day with the zone offset re-resolved, never `n * 86400000`. (ADR-0137)
- Keep `Intl.DateTimeFormat`s at module scope (`YMD_FORMAT`/`OFFSET_FORMAT`) — a performance invariant (~100x per construction); add new constant-options formatters beside them. (ADR-0137)
- `day_slice_utils.js` (hand-mirror of `appointment_day_slice.dart`) requires only `time_utils.js`, owns `sliceForDay`/`dayCountOf`/`lastWorkDayMs`/`calendarDaysBetween` and the 14-day clamp, re-exports `MAX_APPOINTMENT_SPAN_DAYS`; its jest cases share the Dart suite's worked examples, so change both together. Keep new internals window-taking (`lastWorkDayOfWindow`/`dayCountOfWindow`), and keep `dayCountOf(c)` LAST in `travel_utils.js`'s Live-Activity condition — each `resolveWindow` formats through `Intl`. (ADR-0137)
- `notification_policy.js` holds pure push decisions (no `deps`, db or messaging), re-exported by name from `notification_utils.js`; a helper needing `deps` stays in `notification_utils.js`. Import the sweeps from `notification_sweeps.js` — a re-export from `notification_utils.js` is a require cycle. Travel decisions and constants (`PRESENCE_STALE_MINUTES`, module-private; `TRAVEL_SWEEP_MAX`, `CONTEXT_QUERY_MAX`) live in `travel_policy.js`, re-exported by `travel_utils.js`. (ADR-0138)
- `adminFirestore()` is the one lazy `require("firebase-admin/firestore")` that keeps a module jest-requirable. (ADR-0135)
- `scanAppointmentWindow(db, {...})` serves all three sweeps and THROWS on a missing ordering (`descending`/`loOp`/`hiOp` — backward sweeps keep the newest, the travel sweep the soonest) or warn contract (`logger`/`label`/`consequence`). Map records with `recordOf`. (ADR-0135)
- `sendToActiveAdmins` (beside `sendToEmployee`, both in `notification_utils.js`) is the admin fan-out: build a new one on it, never an inlined role/status query. Bounded by `ADMIN_FANOUT_MAX` (100) with warn-at-cap, and seeds `sendToEmployee`'s recipient `cache`. Never re-derive `sendToEmployee`'s token fetch, role/active gate or stale-token pruning. (ADR-0135)
- `reclaimDecision` stays pure in `wave/retry_policy.js` — all three outcomes destroy something. (ADR-0135)

## Accounts and the bridge

- Account callables (`employee_accounts_*.js`), `syncUsersByUid` deactivation and `reconcileAuthAccess` are owned by `.claude/rules/employees.md`, which loads for those files and `bridge.js`. `syncUsersByUid` swallows `auth/user-not-found` (account deletion already removed it; a rethrow retries forever under `retry: true`). (ADR-0061, ADR-0062, ADR-0066, ADR-0067, ADR-0080)
- Call `reconcileAuthAccess` only when `authAccessChange(before, after)` is non-null, or a new invite gets disabled; only an `active` doc restores. (ADR-0061)
- `logger.error` the uid on both orphan paths (create rollback `deleteUser` failing; `deleteEmployeeAccount`/`performDeleteAccount` failing on Auth after the doc); never a bare `.catch(() => {})` — the leftover bricks that email. (ADR-0064)
- `buildActivationPatch` never writes an empty `name` — lists sort and display on it. (ADR-0073)
- Never reintroduce a code-based invite or an unauthenticated callable. (ADR-0063)
- Gate `isAssignedEmployee` (`firestore.rules`) and `isAssignedToAppointment` (`storage.rules`) on `status == 'active'`, never bridge existence (the bridge survives `disabled`); keep them in lockstep. (ADR-0080)
- Keep bridge rules in `bridge_policy.js` (`shouldHaveBridge`, `bridgeBody`, `bridgeMatches`, `classifyBridgeRow`), shared with `scripts/backfill.js`, whose `--prune-orphans` must never delete a `retained` row. Don't reintroduce a token-rotation pass without the write that needed it. (ADR-0061, ADR-0002)

## Other functions

- `deleteClient` (admin, the only client delete) refuses `client-has-history` on a live `count()`, never `jobCount`. `propagateClientEdits` compares the COMPOSED address, fans `clientName`/`clientPhone`/`address` onto FUTURE appointments only (pure `relevantClientChange`/`buildAppointmentPatch`), and needs `(clientId ASC, startTime ASC)`. (ADR-0139)
- `places*` open with `assertAdminCall` + durable rate limit (billable API, admin-only UI); keys in Secret Manager; `placesReverseGeocode` returns only the top `formatted_address` and never logs coordinates.
- `validateUploadedImage` deletes non-JPEG/PNG uploads under `appointments/*/images/*` by magic bytes.
- `restoreAppointmentStatus` is a callable, not a rules grant, because reopening a closed job is the move the employee disjuncts exclude (ADR-0045).

## Testing

- Put a bucket-at-load module's decisions in a pure sibling (`image_magic.js`, `maintenance_policy.js`): `onObjectFinalized` resolves the bucket at registration, so lazier handles don't help. `onCall`/`onDocument*`/`onSchedule` modules are safe to `require`. (ADR-0029)
- Jest tests live in `functions/__tests__/` only; don't recreate `functions/test/`. (ADR-0135)

## Scripts (`functions/scripts/`)

- Open with `bootstrapScript` (`_project.js`; `argv`, `{assertFlags}`), banner BEFORE the first read, passing the script's own `assertFlags` wrapper; `backfill.js` is the deliberate exception. (ADR-0140)
- Page by document id only through `scanByName` (`_scan.js`). (ADR-0140)
- Guard `main()` behind `require.main === module`. (ADR-0140)

## Elsewhere

- TTL policies and index exemptions: `.claude/rules/firestore-indexes.md` (never `--force`, offset `0`).
- Deploy via the `Deploy backend` workflow (`.github/workflows/deploy.yml`, from `main`). Fallback `firebase deploy --only functions,firestore:rules,firestore:indexes,storage` after clearing `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` (`docs/DEPLOYMENT.md` §5). Drop `firestore:indexes` only when `firestore.indexes.json` is unchanged — a missing index fails `FAILED_PRECONDITION`, which best-effort callers swallow. `storage:rules` is not a target; use `storage`.
