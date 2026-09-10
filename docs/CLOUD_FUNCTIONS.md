# Cloud Functions Reference

Map of every Cloud Function in `functions/` — what it does, how it's
triggered, who calls it, and its security posture. Generated 2026-07-05,
refreshed 2026-09-07 (release 1.59.0+88 — **the export list is unchanged at 29**,
and all 29 are now DEPLOYED. This pass changed no signature: the five Wave
callables opened with a hand-spelled auth/`assertAdmin`/payload preamble and now
open with the composed `assertAdminCall`, which changes the opening and not one
allowlist key, and every `wave/connection` read went through the new
`readWaveConnection`/`connectionFieldsOf` pair in `sync_run.js` — eight
hand-copied coercions, one of which applied the unknown-cadence fallback and one
of which did not. `firestore.rules` gained the `appointments/{id}/fieldNotes`
grants. Previously refreshed 2026-09-05 (release 1.58.0+87 — **the export list was unchanged at 29**;
this pass hardened three guards rather than adding any. `assertActiveCall` now
resolves the caller's uid so a bridge-row field cannot shadow it,
`matchPhoneInName` gained the whole-field branch its Dart twin already had (a
Wave customer named by a 7- or 11-digit number was importing undialable), and
the callables that log a caller now log `shortHash(uid)` rather than the raw
Auth uid. Previously refreshed 2026-09-04 (release 1.57.0+86 — **the export list GREW 25 -> 29**,
the first change since 2026-08-13. Four callables were added: `searchClients`,
`searchHistory` and `findAppointmentConflicts` (`indexed_search.js`), which move
client search, appointment-history search and the pre-save conflict check off
capped client-side scans onto indexed queries; and `restoreAppointmentStatus`
(`appointment_actions.js`), the Undo behind the mobile "mark complete". Two new
composite indexes serve them (`clients` searchTokens+name, `appointments`
historySearchScopes+status+startTime) and **both must be READY, and
`functions/scripts/backfill-search-tokens.js` must have run, before the app
build that calls them ships** — an unbackfilled document is invisible to the
search that replaced the scan. Also here: `placesAutocomplete` moved from the
in-memory limiter to `enforceDurableRateLimit`, and a self-service composed
guard `assertActiveCall` joined `assertAdminCall` in `security.js`. Rules gained
bounded `searchTokens` / `historySearchScopes` list fields and a
`locationSharingEnabled` bool on `/users`; the crew-signal rules removed on
2026-09-03 stay removed.)
Previously refreshed 2026-09-02 (release 1.56.0+85 — **the export list is unchanged at 25
and no row below moved**. The security-relevant change is that every ADMIN-ONLY
callable now opens with the composed `assertAdminCall(req, allowedKeys)`
(`security.js`) instead of re-deciding auth → `assertAdmin` →
`assertPayloadShape` at each site — `deleteClient`, `createEmployeeAccount`,
`deleteEmployeeAccount` and all three `places.js` callables, six in all.
It returns the caller's uid, which every one of them needs next for its
rate limiter. It exists because on 2026-09-01 three of those `assertAdmin` gates
turned out to be DELETABLE with the whole suite green — on the callables that
mint and delete real Firebase Auth accounts. The composition and its ORDER are
proved against the real `assertAdmin` in `assert_admin.test.js`; the callable
suites stub the COMPOSER, because stubbing `assertAdmin` alone intercepts
nothing (the composer holds a module-internal reference) and every gate
assertion would pass vacuously — the same shape that hid the original gap. NOT
for a self-service callable: `changeEmployeeEmail` keeps
`resolveEmailChangeCaller`. Two other server-side changes:
`assertPayloadShape`'s 4 KB cap now measures BYTES
(`Buffer.byteLength`) rather than UTF-16 code units, which accented and CJK
text could exceed by 3-4x under a constant and an error code that both said
bytes; and `notifyAppointmentChanges` additionally stamps the server-owned
`startedAt`/`completedAt` job time record on the status transition and pushes
an assignee's On-my-way / Running-late signal to active admins not on the job.
Rules WIDENED — the crew branches now admit an assignee's `fieldNotes` and
their photo writes to the `images` subcollection.)
Previously refreshed 2026-09-01 (release 1.55.0+84 — **the export list is unchanged at 25
and no row below moved**. Three server-side changes, all inside existing
functions: `waveUpsertCustomer` now records `wave.problems` from the new
customer contract (report-only — see below the summary table);
`notifyAppointmentChanges` wraps its per-recipient loop so one transient
failure no longer drops recipients 2..N on a function registered WITHOUT
`retry: true`; and all three `places.js` callables abort their upstream
request at 8 s, deliberately under the client's own 10 s callable timeout, so
an abandoned lookup stops burning a billed Places call and its rate-limit
slot. `runWaveDaily` also guards its connection read, making its documented
"never throws" contract true on its own terms. Rules unchanged; one composite
index RESTORED — see `sendUpcomingJobReminders`.)
Refresh entries older than 2026-09-01 were moved to
`docs/archive/CLOUD_FUNCTIONS_refresh_history.md` on 2026-09-06.

**Every callable now enforces App Check** (`enforceAppCheck: true`); the
earlier `TODO(pre-ship)` carve-outs were retired in 1.25.1
(`grep -rn "enforceAppCheck: false" functions` returns nothing).

- **Project:** `schedulingapp-88727` · **Region:** `us-central1` (except
  `validateUploadedImage`, pinned to `us-east1` by its Storage bucket)
- **Runtime:** Node.js 24, 256 MB, `maxInstances: 10` global
  (`setGlobalOptions` in `index.js`)
- **Wiring:** `index.js` is a thin re-export surface; implementations live in
  domain modules. Shared callable guards (`assertPayloadShape`, `requireString`,
  `optionalString`, `requireDocId`, `requireNumberInRange`, `readSessionToken`,
  `enforceDurableRateLimit`, `assertAdmin`, `assertAdminCall`,
  `assertActiveCall`, `assertFreshReauth`, `shortHash`) live in
  `security.js` — put a new
  one there, never back in a feature module. **`assertActiveCall` spreads the
  bridge row FIRST and the authenticated uid LAST** (`{...data, uid:
  req.auth.uid}`, 2026-09-05): built the other way round, a `uid` field on the
  `usersByUid` row shadowed the uid the platform verified, so every caller that
  scopes on `profile.uid` — the rate limiter included — would key on a
  Firestore-writable value. Latent rather than exploitable (nothing writes that
  field), which is exactly why the ORDER has to be the thing that guarantees it (`optionalString` was a private copy
  in the retired `invites.js` and was carried verbatim into
  `employee_accounts.js` before being hoisted). The Wave stack is split four
  ways as of 2026-08-15: `wave/callables.js` (the admin callables only),
  `wave/triggers.js` (`waveUpsertCustomer` + the `runWaveDaily` rider — neither
  is a callable, which is why they no longer live in the file named for them),
  `wave/sync_run.js` (the one owner of `importWithWatermark` / `drainForSync` /
  `readWaveBusinessIdCached`) and the pure, `deps`-free `wave/retry_policy.js`
  (the dead-letter taxonomy). Export NAMES are unchanged by that split.
- **Three internal modules exist only to be HAND-MIRRORS of a Dart rule**, and
  are worth knowing about because a divergence is silent in production and is
  caught only by tests that share worked examples: `appointment_image_ids.js`
  (↔ `appointmentImageDocId`, the derived subcollection doc id — it has zero
  production inbound requires, being used by the backfill script and its jest
  suite alone, so the invariant is pinned by tests and never exercised by a
  deployed path), `client_name_utils.js` (↔ `ClientNamePolicy`, which decides
  whether a client's stored `name` is a phone number or a business name — the
  value Wave syncs verbatim as its customer name), and `image_magic.js`
  (↔ `hasValidImageMagic`; these two had drifted 3 bytes vs 4, so a file the
  client accepted was deleted server-side). `day_slice_utils.js` is a fourth,
  documented with the multi-day work below — and as of 2026-09-04 it also
  mirrors `dailyWindowsOverlap`, the conflict rule `findAppointmentConflicts`
  applies (the callable shipped with a raw instant test and reproduced the
  phantom clash that rule exists to prevent; pinned by
  `__tests__/indexed_search_conflicts.test.js`). `search_tokens.js` is a fifth,
  mirroring `lib/core/search/search_tokens.dart`: the app WRITES the tokens and
  this side QUERIES them, so a divergence is a search that silently returns
  nothing, and the two suites share their worked examples value-for-value. Change either side of a pair and
  the other in the same commit.
- **Deploy:** `firebase deploy --only functions,firestore:rules,firestore:indexes,storage`
  (run `cd functions && npm run lint` first).

## Deployment status

> The authoritative record of what production runs is the **Deploy log** in
> `docs/DEPLOYMENT.md`, plus `functions_list_functions`. This section has been
> wrong before — verify against the live list rather than trusting it.


- **DEPLOYED 2026-08-22 (rules only): the images allowlist tightening.** `url`
  dropped from `appointments/{id}/images` — `storagePath`/`fileName`/`uploadedAt`
  only. Functions and storage were out of scope because neither changed;
  `firestore:indexes` stayed out for the same reason as the CONTRACT row below.
- **DEPLOYED 2026-08-22 (`cc008388` tree): the photo-subcollection CONTRACT
  step** — functions, `firestore:rules` and storage. 25/25 successful updates,
  0 creates, 0 deletions, so neither known abort fired. It DELETED
  `appointment_image_tokens.js` (an internal module, never an export, so the
  count did not move) and with it the only control that could revoke a legacy
  `url` photo link — which is what made the S1 prod count urgent. It came back
  zero. `firestore:indexes` was deliberately omitted: the only index change is a
  REMOVAL, which never applies without `--force`, so the target could only have
  produced a drift report and pulled the orphaned `signupCodes` TTL policy into
  scope.
- **DEPLOYED 2026-08-22 (`229b6e24`): the starting-password symbol class.**
  `createEmployeeAccount` had been failing outright since `1c89892a`; no
  allowlist, cap or response shape moved, so §4a had nothing to check.
- **DEPLOYED 2026-08-22 (`1c89892a`): simplified auth** — functions, rules and
  storage. No export change (25 → 25). The required pre-flight was re-queried
  at deploy time rather than trusted: zero `invited` users, verified two ways,
  so removing the mailbox guard exposed nobody.
- **DEPLOYED 2026-08-15 (`ccb703e0`, merged as `86bbc462`): the Wave stale-link
  relink — the second Wave deploy of that day and the one that actually
  unblocked the two dead-lettered upserts.** A `waveCustomerId` pointing at a
  customer DELETED in Wave came back as a top-level `NOT_FOUND`, which is
  correctly non-retryable, so every retry re-sent the same missing id;
  `upsertCustomer` now routes that shape into the create path with the identity
  search forced on, and `writeSyncSuccess`'s `replacesLink` carve-out lets the
  healed link persist onto an already-linked doc. `functions/wave/customers.js`
  only; no export, rules, index or payload change.
- **DEPLOYED 2026-08-15 (`c167fcbf`): the Wave enum-coercion fix.** `wave/` only,
  25 → 25. `toCountryCode`/`toProvinceCode` could emit values outside Wave's
  GraphQL ENUM vocabulary (a province typed into the country box; a US state
  prefixed `CA-`), which fails variable coercion and dead-letters the job
  permanently; both are membership tests now and an unrecognised subdivision is
  omitted. Also: transient-looking `graphql` errors are retryable, a
  rate-limited job gets a 20-attempt budget, the dead-letter log gains a
  PII-free `errorDetail`, and `waveRetryFailedJobs`' response gains a `failed`
  key. **A real but different bug from the relink above** — it was not what the
  two dead-lettered jobs were dying of.
- **DEPLOYED 2026-08-15 (`201b93b9`): the 2026-08-15 audit, 25 → 25 with no
  export change.** `waveUpsertCustomer` and `runWaveDaily` MOVED module
  (`wave/callables.js` → the new `wave/triggers.js`) while keeping their export
  names, so both deployed as UPDATES and neither known abort fired — the
  `retry: true` failure-policy abort only triggers on a newly *created*
  function. `wave/sync_run.js` (the one owner of `importWithWatermark` /
  `drainForSync`) and the pure `wave/retry_policy.js` were split out at the
  same time. Rules carried two WIDENINGS that fix live rejections (appointment
  `clientName` 200 → 401, client `address` 500 → 533), one tightening no
  shipped build can reach (an assignee can no longer put `done` over
  `cancelled`), and a new `clients.addressLine2` cap that is **an accepted
  risk** — the already-deployed import wrote that field uncapped, so a prod doc
  over 500 chars would now be un-updatable from the app. If an opaque
  `permission-denied` appears on an ordinary client save, check that field
  first. Full record: `docs/DEPLOYMENT.md`.
- **DEPLOYED 2026-08-14 (`9bda14cb`): the three-deletion swap, net 25 → 25.**
  Deleted `waveSyncWorker`, `waveScheduledImport` and `sendOverdueJobPrompts`;
  added `waveRetryFailedJobs`, `cascadeDeleteAppointmentImages` and
  `recountAppointmentPictures`, plus `firestore.rules` and `firestore:indexes`.
  **The count was unchanged, so it proved nothing** — the same trap the
  2026-08-11 row below describes; the export LISTS were diffed against live
  prod first. A **new** abort fired: `firebase deploy` refuses to create a
  `retry: true` function non-interactively (`Pass the --force option to deploy
  functions with a failure policy`), which is a *different* and earlier abort
  than the 2026-08-08 deletion one — nothing was released on that attempt.
  Resolved by splitting the deploy rather than whole-target `--force`. **Still
  outstanding from this deploy:** only the 3 orphaned Cloud Scheduler jobs
  (`gcloud` absent on the Windows box). The appointment-images backfill RAN on
  2026-08-15 (13 photos across 10 appointments) and both gating indexes reached
  `READY` the same day, so the app build is no longer blocked on either. Full
  sequence and the post-deploy verification: `docs/DEPLOYMENT.md`.
- **CLEARED 2026-08-11: the 2026-08-08 → 2026-08-11 gap has been deployed.**
  All 25 functions were updated together with `firestore.rules` and
  `storage.rules`, so prod now runs `changeEmployeeEmail`'s non-admin re-auth
  gate and its 20/hr → 5/hr budget, the travel-alert opt-out skipping the
  Routes call, the multi-day Live Activity skip and the crew-colour parse in
  `travel_utils.js`, the shared `day_slice_utils.js` day-scoping behind the
  widget payload and push text, the one `TERMINAL_STATUSES` owner in
  `time_utils.js`, plus the P5 self-service rules clause and
  `isValidAppointmentSpan`. Note the trap this gap illustrates: the function
  *count* never moved (25 throughout, `index.js` untouched), so a count check
  looked clean for three days while prod ran older bodies — check the deploy
  log, not the count.
- **29 functions defined and 29 DEPLOYED**, verified by NAME rather than by
  count on 2026-09-07 (`functions_list_functions` diffed against the 29
  `exports.` in `index.js`: zero missing, zero orphans). The 25 -> 29 deploy ran
  2026-09-06 with its `firestore:indexes` prerequisite READY and the
  `searchTokens`/`historySearchScopes` backfill already run; 2026-09-07 then
  redeployed all 29 unchanged alongside the `fieldNotes` rules grant. **The
  three-release backend debt spanning 1.56/1.57/1.58 is PAID** — see
  `docs/DEPLOYMENT.md`, which is the authority for what prod actually runs.
  Note the rollback asymmetry this creates: the old client-side scan path is
  unreachable in a shipped build (`firebaseFunctionsProvider` is non-nullable),
  so once the app build ships, roll back the APP, never the backend.
  Previously **25 defined and 25 deployed**, verified against
  `functions_list_functions` on 2026-08-22 (the CONTRACT deploy reported 25
  updates, 0 creates, 0 deletions) — an exact match, no orphans and no
  extras. **DRIFT OPEN as of 2026-08-25 (1.52.0+81): eight deployable modules
  changed in the 2026-08-25 audit and have NOT been deployed**, so prod is
  running older bodies. The count is still 25 and still matches, which is
  exactly the trap named below — a count check looks clean while the deployed
  code is behind. **The pending delta is NOT cosmetic** (re-measured 2026-08-28
  against `f0c341a7`, the last recorded deploy): `firestore.rules` **+36/-11**,
  a new 119-line `functions/client_address_utils.js`, and behaviour changes in
  `client_propagation.js` (+17), `day_slice_utils.js` (+44), `client_name_utils.js`
  and `wave/mappers.js` (-56). This bullet previously called it "dead-code
  removal plus a shared options constant" that could "ride the next deploy" —
  it carries a RULES change, so it takes the `docs/DEPLOYMENT.md` §4a/§4c
  checks and the documented ordering (backend BEFORE the app build), not a
  ride-along. The release runbook is `docs/DEPLOYMENT.md`. The retirement deploy has now RUN. P4c added `createEmployeeAccount`,
  `completeEmployeeSetup` and `deleteEmployeeAccount` and kept
  `createEmployeeInvite` / `redeemSignupCode` as the `#compat-1.37.1` shim;
  `changeEmployeeEmail` landed 2026-08-04 (26 → 27); **the shim was retired
  2026-08-08 (27 → 25)** once every device was on 1.40+, deleting those two
  callables. `revokeInvite` and `previewInvite` DID exist in code — P4b added
  them (`5f33ca63`) and P4c removed them (`b0e0fe4e`) — but they were never
  deployed to prod. (v2, Node.js 24, 256 MB; `us-central1`
  except `validateUploadedImage` in `us-east1`). The 2026-07-18 deploy shipped
  `placesReverseGeocode`, the travel-aware `sendUpcomingJobReminders` rebuild,
  and the codebase-audit fixes (overdue-sweep ordering, bounded travel-context
  query, client-data rule length caps).
- The 4 **push-notification functions** (`notifyAppointmentChanges`,
  `sendUpcomingJobReminders`, `sendDailyJobDigest`, `sendOverdueJobPrompts`)
  and the 2 **Wave auto-import cadence functions** (`waveSetImportSchedule`,
  `waveScheduledImport`) were **deployed 2026-07-11** together with the updated
  `firestore.rules`. The one-time Firestore **TTL policy** on `expiresAt` for
  the `appointmentReminders` / `appointmentOverduePrompts` ledgers was
  **enabled in the console 2026-07-11** — this list previously said it was still
  outstanding, which was wrong. Still outstanding: on-device push verification.
  TTL was extended to `liveActivityTokens`, `rateLimits`, and `signupCodes` on
  2026-07-20. **The `signupCodes` `fieldOverride` was removed from
  `firestore.indexes.json` on 2026-08-08** with the rest of the
  `#compat-1.37.1` shim. That was expected to drop the live TTL policy on the
  next `firestore:indexes` deploy — **it has not, and by now three such deploys
  have gone by** (2026-08-08, 2026-08-14, 2026-08-15). Each time the CLI reported
  the override as unmatched drift and **correctly refused to delete it without
  `--force`**, so the policy is still live. That is a safe resting state (the
  collection was verified **empty in prod** first, and rules deny all access),
  and it must never be "resolved" by passing `--force` — that flag deleted all
  five live TTL policies once already. A TTL policy is the only reaper for those
  docs, so dropping one over a non-empty collection strands them forever.
  **`appointmentRecountClaims.expiresAt` joined the list 2026-08-15** — the
  debounce marker behind `recountAppointmentPictures`, with a matching
  `allow read, write: if false` block in `firestore.rules`. A
  `fieldOverride` for the `appointmentSeriesNotices` claim
  ledger was added to `firestore.indexes.json` on 2026-07-21 (that ledger has no
  in-code reaper, so the TTL is its only cleanup). Every policy's **expiration
  offset normalized to `0`** — the
  code writes `expiresAt` as the absolute deletion instant, so a non-zero offset
  adds to it and silently doubles retention (the ledgers had been running at
  ~14 days, not 7). `liveActivityCards` has no policy yet: Firestore only offers
  collection groups that already hold documents, and no card marker exists until
  the feature runs on a device. Every one of these is also swept in-code, so TTL
  is storage housekeeping, not correctness. The iOS-native
  APNs key + Push/App-Groups entitlements were wired on the Mac 2026-07-11 (see
  `docs/archive/2026-07-08-push-notifications.md`).
- **Deployed 2026-07-18 (1.33.0):** the travel-aware `sendUpcomingJobReminders`
  rebuild went live. One console step still gates full travel-awareness — the
  **Routes API** must be enabled and added to the `GOOGLE_MAP_API_KEY`
  restriction; until that's verified the sweep logs Routes failures and delivers
  the 30-min fallback (never worse than the old behavior). See
  `docs/archive/2026-07-09-travel-time-notifications.md`.
- **Deployed 2026-07-19 (1.34.1):** the iOS Live Activity dispatch inside
  `notifyAppointmentChanges` / `sendUpcomingJobReminders`, the deep-audit fixes
  (deactivation now revokes Auth access + purges delivery state in
  `syncUsersByUid`; the `status == 'active'` gate in `firestore.rules` /
  `storage.rules`; Wave guard ordering; the travel-sweep estimate memo), and
  **two new composite indexes** — `liveActivityTokens (kind, employeeDocId)` at
  COLLECTION_GROUP scope and `liveActivityCards (phase, startTime)`. Those
  indexes are what make the Live Activity feature work at all; without them the
  registry queries fail `FAILED_PRECONDITION` and the best-effort catch turns it
  into a silent no-op. Remaining gate is on-device verification. Runbook:
  `ios/ScheduleWidget/LIVE_ACTIVITY_README.md`.
- **Pending deploy (1.38.0, 2026-07-31):** personal jobs and all-day blocks
  change three functions' *behaviour* with no signature, trigger, guard or
  secret change, so the export set stays at 21. `sendUpcomingJobReminders` —
  `selectTravelCandidates` skips `isAllDay` records (a midnight start otherwise
  fell inside the 90-min window at ~23:30 the night before and pushed a "time
  to leave" for a block with nowhere to leave for); the overdue sweep —
  `selectOverdueCandidates` skips `isPersonal` records, the server mirror of
  `AppointmentRecord.displayStatus`; and every push, digest and Live Activity
  card now names a job `clientName → title → generic`, since a personal job has
  no client. Nothing here needs a new index.
- `backfillLegacyClientNames` (a one-time migration completed `2026-06-29`,
  `fixed: 0`) was removed from the codebase 2026-07-05 and is **no longer in the
  deployed set** (confirmed 2026-07-10) — it was pruned by a full
  `firebase deploy --only functions`.

## Summary

| Function | Type | Trigger / event | Module | Called by / fired on | Secret | Guard |
|---|---|---|---|---|---|---|
| `placesAutocomplete` | callable | `onCall` | `places.js` | `google_places_repository.dart` (address field typing) | `GOOGLE_MAP_API_KEY` | App Check ✓ · admin · durable 20/min·uid |
| `placesGetDetails` | callable | `onCall` | `places.js` | `google_places_repository.dart` (address selected) | `GOOGLE_MAP_API_KEY` | App Check ✓ · admin · durable 40/15min |
| `placesReverseGeocode` | callable | `onCall` | `places.js` | live staff-location map (admin) | `GOOGLE_MAP_API_KEY` | App Check ✓ · admin · durable 120/hr |
| `deleteAccount` | callable | `onCall` | `account.js` | `account_deletion_service.dart` | — | App Check ✓ · reauth ≤5min · durable 5/15min |
| `createEmployeeAccount` | callable | `onCall` | `employee_accounts.js` | `firebase_employees_repository.dart` (invite sheet, roster row Reset password) | — | App Check ✓ · admin · durable 20/hr·uid |
| `completeEmployeeSetup` | callable | `onCall` | `employee_accounts.js` | `firebase_employees_repository.dart` → `auth_service.dart` (account setup screen) | — | App Check ✓ · authed (own doc) · durable 5/15min·uid |
| `deleteEmployeeAccount` | callable | `onCall` | `employee_accounts.js` | `firebase_employees_repository.dart` (pending-account row) | — | App Check ✓ · admin · durable 20/hr·uid |
| `changeEmployeeEmail` | callable | `onCall` | `employee_accounts.js` | `firebase_employees_repository.dart` (inside `updateEmployee`, when the email changed on a doc with a `uid`); `self_email_service.dart` (a person changing their own) | — | App Check ✓ · admin **or self** · non-admin also needs re-auth <5 min · durable 5/hr·uid |
| `waveBootstrap` | callable | `onCall` | `wave/callables.js` | `wave_service.dart` | `WAVE_FULL_ACCESS_TOKEN`, `WAVE_BUSINESS_NAME` | App Check ✓ · admin · durable 10/hr |
| `waveGetConnection` | callable | `onCall` | `wave/callables.js` | `wave_service.dart` (Settings mount) | — | App Check ✓ · admin · durable 60/hr |
| `waveSetImportSchedule` | callable | `onCall` | `wave/callables.js` | `wave_service.dart` (Settings cadence picker) | — | App Check ✓ · admin · durable 20/hr |
| `waveImportCustomers` | callable | `onCall` | `wave/callables.js` | `wave_service.dart` (`syncCustomers`, Settings "Sync with Wave") | `WAVE_FULL_ACCESS_TOKEN` | App Check ✓ · admin · durable 5/hr · 300s |
| `searchClients` | callable | `onCall` | `indexed_search.js` | `firebase_clients_repository.dart` (`searchClients`, the debounced clients/history search bar) | — | App Check ✓ · `assertAdminCall` (clients are PII) |
| `searchHistory` | callable | `onCall` | `indexed_search.js` | `firebase_appointments_repository.dart` (`searchHistory`, History screen + the technician's own History) | — | App Check ✓ · `assertActiveCall` · scope from role: `all:` for admin, own doc id for an employee |
| `findAppointmentConflicts` | callable | `onCall` | `indexed_search.js` | `firebase_appointments_repository.dart` (`findClashingAppointments`/`findBusyEmployees`, pre-save clash check + assignee picker) | — | App Check ✓ · `assertActiveCall` · a non-admin is narrowed to their own doc id |
| `restoreAppointmentStatus` | callable | `onCall` | `appointment_actions.js` | `firebase_appointments_repository.dart` (`restoreAppointmentStatus`, the mark-complete Undo) | — | App Check ✓ · `assertActiveCall` · admin **or assigned** · target must be `pending`/`in_progress` |
| `deleteClient` | callable | `onCall` | `clients.js` | `firebase_clients_repository.dart` | — | App Check ✓ · admin · durable 20/hr |
| `syncUsersByUid` | trigger | `onDocumentWritten users/{id}` | `bridge.js` | any `users` doc write | — | `retry: true` |
| `propagateClientEdits` | trigger | `onDocumentUpdated clients/{id}` | `client_propagation.js` | any `clients` doc edit | — | `retry: true` |
| `recountClientJobs` | trigger | `onDocumentWritten appointments/{id}` | `client_job_count.js` | a write that changes `clientId` | — | `retry: true` |
| `waveUpsertCustomer` | trigger | `onDocumentWritten clients/{id}` | `wave/triggers.js` | any `clients` doc write | `WAVE_FULL_ACCESS_TOKEN` | `retry: true` · 300s · enqueues **and pushes** |
| `validateUploadedImage` | trigger | `onObjectFinalized` (Storage) | `maintenance.js` | `appointments/*/images/*` upload | — | region `us-east1` |
| `notifyAppointmentChanges` | trigger | `onDocumentWritten appointments/{id}` | `notifications.js` | any appointment write | `APNS_AUTH_KEY` · `APNS_KEY_ID` · `APNS_TEAM_ID` | no `retry` (dupe push worse than missed); since 2026-09-01 also stamps `startedAt`/`completedAt` on the status transition (best-effort Admin-SDK update, its own re-fire is silent) and pushes the crew's On-my-way / Running-late signal to active admins not on the job |
| `waveRetryFailedJobs` | callable | `onCall` | `wave/callables.js` | `wave_service.dart` (Settings, requeue dead outbox jobs) | `WAVE_FULL_ACCESS_TOKEN` | App Check ✓ · admin · durable 10/hr |
| `cascadeDeleteAppointmentImages` | trigger | `onDocumentDeleted appointments/{id}` | `appointment_images.js` | any appointment delete | — | `retry: true` · **rethrows** |
| `recountAppointmentPictures` | trigger | `onDocumentWritten appointments/{id}/images/{imageId}` | `appointment_images.js` | any photo doc write | — | `retry: true` · absolute `count()` |
| `purgeExpiredHistory` | scheduled | `0 3 1 1,4,7,10 *` — quarterly, 1st of Jan/Apr/Jul/Oct 03:00 (Toronto) | `maintenance.js` | quarterly | — | `maxInstances: 1` · 1800s |
| `sendUpcomingJobReminders` | scheduled | `every 5 minutes` (Toronto) | `notifications.js` + `travel_utils.js` | timer | `GOOGLE_MAP_API_KEY` · `APNS_AUTH_KEY` · `APNS_KEY_ID` · `APNS_TEAM_ID` | `maxInstances: 1` · ledger · Routes API · **also carries the overdue sweep** |
| `sendDailyJobDigest` | scheduled | `0 18 * * *` (Toronto) | `notifications.js` | timer | — | `maxInstances: 1` · **also calls `runWaveDaily()`** |


`waveUpsertCustomer` also records **`wave.problems`** on the client doc —
the customer contract's verdict on whether Wave would accept it
(`wave/customer_contract.js`, added 2026-08-30). Structured
`[{field, code, detail}]`, naming the CLIENT DOC field an admin edits.
**Report-only in Phase 1**: nothing is blocked by it, the job is still
enqueued and `wave.syncState` is untouched. It rides the existing
mark-pending batch, so it costs no extra write, and it is not a mapped
field — the hash is unchanged, so `shouldEnqueueClientWrite` stops the
re-fire and this cannot loop. Replay it over production read-only with
`functions/scripts/audit-wave-contract.js`. Design:
`docs/plans/2026-08-30-wave-validated-contract-design.md`.

**Exactly three Cloud Scheduler jobs, and that is deliberate** — only 3 are free
per billing account. `sendOverdueJobPrompts` (was `every 15 minutes`) is merged
into `sendUpcomingJobReminders`, `waveScheduledImport` (was `every 24 hours`)
into `sendDailyJobDigest`, and `waveSyncWorker` (was `every 5 minutes`) is gone
entirely because the Wave push is event-driven now. **All three were deleted
from prod by the 2026-08-14 deploy (`9bda14cb`)**, and each still leaves an
orphaned Cloud Scheduler entry that must be deleted by hand — see
`docs/DEPLOYMENT.md`, "DONE 2026-08-14: a THREE-deletion deploy". Adding a
fourth scheduled function starts costing money.

## Auth & accounts

### `deleteAccount` — `account.js`
Self-service account deletion (Apple App Store Review Guideline 5.1.1(v)).
Deletes the caller's `users/{docId}` doc via `recursiveDelete` (the
doc **plus all its subcollections** — today that is `fcmTokens`, `presence`,
and `liveActivityTokens`) and their Firebase Auth user; the `syncUsersByUid`
trigger then clears the `usersByUid` bridge. Deliberately
does **not** touch shared business data (appointments, clients, images).
Requires a fresh re-auth: rejects `stale-auth` if the ID token's `auth_time` is
older than 5 minutes (checked before the rate limiter so a stale rejection
doesn't burn a slot). Durable-rate-limited 5 per 15 min per uid; refunds the
slot if the Auth delete fails server-side. Auth user is deleted **first**
(irreversible step), then the Firestore doc. App Check enforced.

## Employee accounts (admin invites, employee sets up)

Rebuilt by **P4c, 2026-08-02**, replacing the one-time signup-code flow in the
APP — and as of **2026-08-08 the signup-code flow is gone from the backend too**:
`invites.js`, `signup_code_utils.js`, `createEmployeeInvite` and
`redeemSignupCode` were deleted with the rest of the `#compat-1.37.1` shim.
`revokeInvite` and `previewInvite` were never deployed, but they DID exist in
code between P4b (`5f33ca63`) and P4c (`b0e0fe4e`).
**`redeemSignupCode` was the last unauthenticated callable in the
codebase**; every remaining one requires auth. All four callables
below share `APP_CHECK = {enforceAppCheck: true}`. Full design:
`docs/archive/redesign-subdocs/2026-08-02-p4c-HANDOFF.md`.

The shape: the admin creates the account and hands over an email + a generated
starting password; the employee signs in, replaces the password, and activates
themselves. **The security posture is weaker than the codes it replaced, with
the owner's sign-off.** Until 2026-08-21 the starting password was the shared
constant `Welcome123!`, so anyone who merely knew an employee's email could sign
in as that person between creation and first sign-in, and
`completeEmployeeSetup`'s `email_verified` guard was what stopped them finishing
setup. **Both went on 2026-08-21**: the password is now random per account, so
the address alone buys nothing — that is what pays for dropping the guard, and
neither should be restored without the other. **The residual risk is real, not
closed:** whoever holds the address *and* the generated password can still
activate the account first. Two things bound it — a pre-empted account is always
a plain `employee` now, and `firestore.rules` grants an `invited` user
**nothing** — and the rest is operational: the admin controls the window by
creating the account at the moment they hand the credentials over, not weeks
ahead.

### `createEmployeeAccount` — `employee_accounts.js`
Admin-only. Mints a Firebase Auth account on a **random per-account starting
password** plus an `invited` `users` doc that **already carries the real `uid`**,
and returns `{email, password}` (no `docId` — the client already has the row it
acted on). That response is the **only** time the password is legible: it is
deliberately not persisted anywhere, because a live plaintext credential in
Firestore is readable by every admin session, backup and export.
`generateStartingPassword()` draws 12 characters with `crypto.randomInt` from
an alphabet with no `0`/`O` and no `1`/`l`/`I`, because an admin reads it aloud,
and guarantees an uppercase, a lowercase, a digit **and exactly one symbol**.
The symbol class is load-bearing and was MISSING for two days: the Identity
Platform password policy configured console-side requires a non-alphanumeric,
the shared `Welcome123!` had been satisfying it by accident, and without it
every call died at `provisionAuthAccount` with
`PASSWORD_DOES_NOT_MEET_REQUIREMENTS` — account creation was down outright,
through four prod failures, with App Check and auth VALID on each (fixed
`229b6e24`, deployed 2026-08-22). `PASSWORD_SYMBOLS` is deliberately kept OUT
of `PASSWORD_ALPHABET` so a mint carries exactly ONE symbol — the admin
dictates the value aloud — and the set avoids bracket pairs, dash/underscore
confusion and URL- or shell-significant glyphs. It is drawn **once per call** and handed to whichever
path runs — new account or re-provision — so the value echoed back is always the
value Auth was actually set to. The duplicate lookup and the doc write share one
transaction, so two admins creating the same person can't both win.

**No role is read off the payload** (2026-08-21): the doc is always written
`role: "employee"`, hard-coded in `performCreateAccount`. Promotion is a
separate later edit on the employee edit sheet.

**`isAdmin` was in the `assertPayloadShape` allowlist as `#compat-1.47.0`
— ACCEPTED AND IGNORED — and was RETIRED 2026-08-29.** It is now refused like
any other unrecognised key. The carve-out existed because every admin build at
or below 1.47.0 sent `isAdmin` unconditionally on BOTH create and Reset
password, and `assertPayloadShape` throws `unexpected-field` on the first key
it does not recognise — so dropping it early would have failed both actions on
every device that had not updated. It was removed once the fleet was wholly on
1.53 and the current client sends no such key, which keeps the allowlist a
superset of every deployed build (`docs/DEPLOYMENT.md` §4a). Note what this
never was: a role check. `performCreateAccount` hard-codes `role: "employee"`
and has never read a role off the payload, so removing the key tightened the
surface without changing who can be minted.

Re-running it on a still-`invited` person **re-provisions**: it refreshes the
doc's editable fields and issues a fresh random password — that IS the
"never signed in / lost the password" path. It refuses `already-exists /
email-exists` once the person has finished setup, resolving the target **by
`uid`, not by email** (`users.email` is admin-editable and never synced back to
Auth, so an email-only check can clear a doc that is not the account Auth hands
back). The rotation itself is deferred to `resetProvisionedPassword`, which runs
only after the transaction has claimed the person as still-`invited` — that
**narrows** the window in which a concurrent setup gets its chosen password
reverted, but cannot close it, since the Auth call sits outside both
transactions.

If the Firestore write fails after the Auth account was created, the Auth
account is deleted — but only if *we* just minted it. **A rollback that itself
fails is `logger.error`-ed with the uid**, because the resulting Auth-account-
with-no-doc is invisible to every admin surface *and* permanently bricks that
email (the pre-flight refuses an Auth account no doc claims), so it can only be
cleared from the Firebase console.

Durable-rate-limited 20/hr per admin uid; the payload is validated
(`assertPayloadShape`/`requireString`, plus explicit `colorValue` and `jobTitle`
allowlists — this Admin SDK write bypasses rules, so those checks ARE the
enforcement) **before** the limiter, while `assertAdmin` stays above it.
Transactional core exported as `performCreateAccount` for jest.

### `completeEmployeeSetup` — `employee_accounts.js`
The employee's own activation — authed, but **not** admin: it resolves the
caller's doc by `where("uid", "==", req.auth.uid)` and can only ever touch that
one. Flips `status` to `active` and stamps the setup profile. Refuses
`failed-precondition / setup-not-pending` when the doc isn't `invited`, so a
replayed call (or two devices finishing at once) can't rewrite a consent record;
`not-found / account-not-found` when there's no doc for the uid.

**It no longer checks `email_verified`** (guard removed 2026-08-21, along with
the `failed-precondition / email-not-verified` error it raised). **The CLIENT
still maps that error**, deliberately: `AuthService._mapSetupError` turns it
into `AuthFailureSetupNotAvailableYet` so that a backend rolled back under a
shipped app build (§3 below) tells the person setup is unavailable instead of
"Something went wrong", and stops filing a Crashlytics non-fatal on every
retry by someone who cannot succeed. That mapping is old-backend
compatibility only — retire it once no pre-simplified-auth backend can be
live — and its presence is NOT evidence this callable still raises the error. That check
existed to price the shared-`Welcome123!` window — knowing the address was enough
to sign in, so finishing setup was made to require the MAILBOX — and it was
removed only because the starting password became a random per-account secret in
the same change. Don't re-derive it from an old copy of this page, and don't drop
a comparable check elsewhere on the strength of this precedent alone.

**The caller must have already changed the password.** The server cannot see a
password, so "you must replace the starting password" is true only because
`AuthService.completeAccountSetup` calls `User.updatePassword` first and this
callable is unreachable until that succeeds. Swap the order and an interrupted
setup leaves an *active* account still on the password the admin read out.
Nothing server-side verifies the rotation happened — and that is still true
after 2026-08-21, when the app gained
`AuthService._refuseIfStillTheStartingPassword`: it reauthenticates with the
typed password and refuses when that SUCCEEDS (proving it is unchanged), which
stops an employee retyping what the admin gave them, but it runs on the CLIENT.
A caller reaching this callable directly still activates an un-rotated account,
with `enforceAppCheck: true` the only thing in the way.

The patch is built by the pure `buildActivationPatch`: it stamps
`termsAcceptedAt`/`locationConsentAt` **only when the flags are actually sent
`true`** (a consent record for someone who never saw the checkbox would be a
false one), and never writes an empty `name` — it composes from the submitted
halves falling back per-half to the stored ones, because `watchAllUsers` orders
by `name` and Firestore excludes docs missing the orderBy field. Rate-limited
5 per 15 min per uid: setup runs once per person, and a handful of retries
covers a fumbled password.

### `deleteEmployeeAccount` — `employee_accounts.js`
Admin-only. Removes an account that has never been set up — the `users` doc and
the Firebase Auth account both. **Transactional, and refuses once the person has
set up** (`failed-precondition / account-not-pending`): from that point the
account is theirs and the no-delete invariant applies, so disable is the only
removal. A setup that commits first therefore makes this refuse rather than
delete a just-activated account; a missing doc is `not-found /
account-not-found`.

Doc first, Auth second. `auth/user-not-found` is swallowed so a partial earlier
run converges, but **any other Auth failure is logged with the uid and then
rethrown**: the doc is already gone at that point, so it leaves an Auth account
no admin surface can see and whose email `createEmployeeAccount` will then
refuse — recoverable only from the Firebase console, which is why the log is
the difference between a findable leftover and a silent one. Guard
order is the standard one (auth → `assertAdmin` → payload →
`enforceDurableRateLimit` 20/hr per admin uid → work), and an id containing `/`
is rejected up front because `.doc()` throws synchronously on it and would
surface as an opaque `internal`. No rules change: the deletes are Admin SDK.
Note `allow delete` on `/users` is withdrawn from this build's code path AND
from `firestore.rules` — the `#compat-1.37.1` grant that kept a 1.37.1 client
able to delete a users doc (orphaning its crew links) was retired 2026-08-08;
see docs/DEPLOYMENT.md. Transactional core exported as `performDeleteAccount`
for jest.

### `changeEmployeeEmail` — `employee_accounts.js`
Admin **or the person themselves** (the `self` branch landed with P5,
2026-08-10). Moves an employee's **sign-in identity** in Firebase Auth and on
their `users` doc together. It exists because nothing else joined those two:
`updateEmployee` writes Firestore alone, so an admin's email edit left the
person signing in at the old address while every admin surface showed the new
one — and it desynced the two stores `createEmployeeAccount` resolves against.
Added 2026-08-04; it is what re-enabled the email field in `edit_person_sheet`.

Refuses `failed-precondition / account-has-no-auth` for a doc carrying no `uid`
— there is nothing to join, and that doc's email is written directly by the
client under the rules. An email equal to the stored one is a no-op `{ok:true}`.

**Order is Auth FIRST, Firestore second, with a revert.** Auth owns sign-in and
is the only store that can genuinely refuse a duplicate, so it must never be
the one left behind; a `auth/email-already-exists` becomes `already-exists /
email-exists`. If the doc write then fails, the Auth email is set back and a
**failed revert is `logger.error`-ed with the uid and docId — never the
addresses, which are PII**: that state is the exact desync this function
prevents and nothing in-app can find it.

A cheap doc-level uniqueness pre-flight runs before Auth so the common conflict
costs no Auth write plus rollback; `performChangeEmail`'s transaction is the
authoritative check and re-tests **both** halves — that the doc still holds the
email we read (`aborted / email-changed` otherwise, which the client surfaces as
"try again") and that no other doc holds the new one. Guard order is the
standard one (auth → payload → identity → freshness → `enforceDurableRateLimit`
**5/hr** per caller uid → work), with the same `/`-in-docId rejection as the
delete. The payload is validated before a slot is consumed so a burst of
malformed submissions can't exhaust a legitimate caller's window, and the
identity guard sits above the limiter so a non-entitled caller can't burn one
either. The budget is the same on both branches — this rewrites a sign-in
identity, so a compromised session must not be able to walk the roster.

**A NON-ADMIN caller additionally requires a fresh re-auth** —
`assertFreshReauth` (`security.js`, shared with `deleteAccount`) rejects a
caller whose `auth_time` is over **5 minutes** old, so a direct call cannot skip
`SelfEmailService`'s re-authenticate-then-call ordering. **The gate keys on
`isAdmin`, not on `isSelf`**, and the two are separate fields on
`resolveEmailChangeCaller`'s result for exactly this reason: an admin editing
their OWN roster row is `isSelf` but still arrives through `updateEmployee`,
which has no re-auth step — keyed on self-ness, that save was rejected whole
(name, phone, colour and availability with it, since `_changeAuthEmail` runs
before the Firestore write) as an opaque `stale-auth`. `isSelf` routes the
notification and nothing else. The **admin branch is deliberately not gated**,
so that residue is real and stated — an unattended admin session can still
rewrite a colleague's address, bounded by the identity guard and the budget
above; closing it needs a re-auth prompt on the admin save path first.

**The identity guard is `resolveEmailChangeCaller`, not `assertAdmin`** — it has
to tell an admin from a person editing their own row. Pure over the caller's
`usersByUid` bridge data, so it is jest-tested without Firestore. An **active
admin** may move any doc; an **active employee** may move their OWN; everything
else is refused `permission-denied / not-admin` — a disabled account (whose Auth
credential outlives the status flip until `syncUsersByUid` revokes it), an
invited account mid-setup, an unknown role, a missing bridge doc, or an employee
naming somebody else's docId. Widening this callable past admins must never
widen WHICH doc a caller can reach.

**Who gets notified depends on who acted.** `isSelf` reports whether the caller
IS the target, independent of role, so an admin editing their own row counts as
self. An admin edit pushes the EMPLOYEE (`notifyEmailChanged`); a self edit
pushes the ACTIVE ADMINS (`notifyAdminsOfSelfEmailChange` → the shared
`sendToActiveAdmins` in `notification_utils.js`, excluding the person who made
the change). **The admin notice carries the NAME, never the address** — it lands
on every admin's Lock Screen and an email is PII. Both are best-effort and run
after the commit: the change is already durable in both stores, so a push
failure must not hand the caller an error for something that worked.
Transactional core exported as `performChangeEmail` for jest.

On success it pushes the employee a `kind: "emailChanged"` notification naming
the new address, via `notifyEmailChanged` → the shared `sendToEmployee` (now
exported from `notification_utils.js`, so the token fetch, the role + active
gate and stale-token pruning keep one owner). It runs **after** the commit and
swallows every failure — the change is already durable in both stores, so a
push problem must not surface as a failed save. Recipients use
`TIMED_RECIPIENT_ROLES` so an admin whose own email is being changed is told
too. Tapping it just opens the calendar (`_handlePushTap` treats a missing
`appointmentId` as "no appointment to open"), and **it is a courtesy, not a
guarantee**: an employee with no live FCM token learns when their old address
stops signing them in, so the admin should still tell them directly.

## Maps / Places proxies

### `searchClients` — `indexed_search.js`
Server-side client search, replacing a capped client-side scan. Queries
`clients.searchTokens` with `array-contains-any` over at most 10 query tokens,
reads `SEARCH_READ_LIMIT` (**200**, `orderBy("name")`) and warns at the cap,
re-verifies each hit with `recordMatchesQuery` against the full stored
document, ranks and returns 25. **Admin-only** via
`assertAdminCall`: clients are PII, and the old scan was already admin-gated by
the rules it read through. The prefilter/verify split is load-bearing — a prefix
token matches strictly more than the query does, so returning the raw token hits
would widen the answer.

### `searchHistory` — `indexed_search.js`
The same shape for terminal-status appointments, but **scoped by role in the
query rather than after it**. `assertActiveCall` resolves the caller;
`historyScope` picks a token prefix — `all:` for an admin (optionally narrowed
to a named employee), `emp:<their own doc id>:` for an employee — and refuses an
employee who asks for someone else's scope. That is why
`appointments.historySearchScopes` stores every token once per scope instead of
storing plain tokens plus an `employeeIds` filter: the scope is baked into the
token, so the query itself cannot return another person's jobs.

### `findAppointmentConflicts` — `indexed_search.js`
The pre-save clash check and the assignee picker's dimming. Chunks
`employeeIds` at 30 (the `array-contains-any` limit), runs the chunks through
`Promise.all`, caps each at 500 docs and warns at the cap. **The clash rule is
`dailyWindowsOverlap` from `day_slice_utils.js`, not a raw instant test** — an
appointment's two stored times describe a DAILY window, so a 9-5 run across a
week must not block a 7 pm job inside it. It shipped with the instant test and
reproduced exactly that phantom clash; `__tests__/indexed_search_conflicts.test.js`
pins it now. It keeps the fail-closed half too: a document whose stored times do
not parse blocks unconditionally, so a legacy or console-written row can never
quietly vanish from a booking check. A non-admin caller's `employeeIds` are
narrowed to their own doc id, so a technician cannot probe the roster's diary.

### `restoreAppointmentStatus` — `appointment_actions.js`
Undo for the mobile "mark complete". Runs in a transaction: the document must
currently be COMPLETED, the caller must be an admin or assigned (`mayRestore`),
and `previousStatus` must be `pending` or `in_progress` — never a terminal
value. It clears the server-owned `completedAt` with the status write, so an
undo cannot leave a finish time on a reopened job. **It is a callable rather
than a rules grant on purpose**: every employee `allow update` disjunct requires
the current status NOT be terminal, so reopening is precisely what the rules
exclude, and widening them would let an assignee reopen any job they are on at
any age.

### `placesAutocomplete` — `places.js`
Proxies Google Places API (New) autocomplete so the billing-sensitive
`GOOGLE_MAP_API_KEY` (Secret Manager) never ships in the app binary. App Check +
auth + **`assertAdmin`** required — the address field is only surfaced on the
admin-only appointment form, so gating on admin stops a non-admin (or
invited-but-inactive) principal from scripting the billable API. Fires on
address-field typing, so it's the **highest-volume, highest-cost** function —
the Places API bills separately per request. Rate-limited **durably** at 20/min per uid
(`enforceDurableRateLimit`, 2026-09-04). It used the in-memory limiter until
then, chosen to keep a Firestore round-trip off a keystroke-debounced path — but
an in-memory bucket is per function INSTANCE, so with `maxInstances: 10` the
documented 20/min was really up to 200/min for one caller, and the cap on the
highest-cost function in the project was not a cap. The trade is one Firestore
transaction per lookup where there were none; keep the GCP Maps Platform billing
alert regardless.

### `placesGetDetails` — `places.js`
Proxies Places details for a selected address (one billable call per address the
user actually picks). Same guards as autocomplete (App Check + auth +
`assertAdmin`). Uses the durable Firestore rate limiter (40 per 15 min) — lower
volume, but each call is more expensive, so a hard cap matters.

### `placesReverseGeocode` — `places.js`
Backs the live staff-location map: turns a lat/lng into a human-readable
address. Callable — App Check + auth + `assertAdmin` + durable Firestore rate
limiter (120 per hour per uid; a tap-driven, not keystroke-driven, surface, so
a generous hourly cap suffices). Validates `lat`/`lng` are numbers in their
valid ranges and `locale` is an allowlisted value (`en`/`fr`); rounds
coordinates to 5 decimal places before the upstream call so GPS jitter can't
multiply request volume. Calls the classic Geocoding API (not Places v1, which
has no reverse-geocode mode) with `GOOGLE_MAP_API_KEY`, and returns only the
top result's `formatted_address` (or `null` on `ZERO_RESULTS`) — never logs
coordinates or resolved addresses. **Deployed to prod 2026-07-18.**

**All three Places callables abort upstream at 8 s** (`UPSTREAM_TIMEOUT_MS`,
`fetchPlacesJson`, 2026-09-01). Node's `fetch()` has no default timeout, so a
slow upstream held the function open indefinitely: the CLIENT gave up at 10 s
(`_callableTimeout`, `google_places_repository.dart`) and reported
`deadline-exceeded` while the function carried on, still spending a billed
upstream call and the rate-limit slot it had already consumed, for an answer
nobody was waiting for. **The budget must stay UNDER the client's** so the
server gives up first and the work is never orphaned — raise the two together
or that stops being true; a jest test asserts the ordering. The transport-error
log carries `timedOut`, which is what separates "the upstream is slow" from
"the network broke" in Cloud Logging. This surfaced as a production Crashlytics
cluster on the live map, where a recycled roster row re-requested a failed cell
immediately; the client half is `kReverseGeocodeFailureCooldown`
(`maps_providers.dart`). **The fan-out itself is NOT fixed** — N staff still
issue N concurrent lookups on open, and batching needs an endpoint that does
not exist yet.

## Images

### `validateUploadedImage` — `maintenance.js`
Storage `onObjectFinalized` trigger. For every upload under
`appointments/{id}/images/`, reads the first 8 bytes and deletes the object
server-side unless it's real JPEG (`FF D8 FF`) or PNG (`89 50 4E 47`) — the
Storage rule trusts client `contentType`, so this closes that gap. Deployed to
`us-east1` (follows the Storage bucket region).

## Maintenance (scheduled)

### `purgeExpiredHistory` — `maintenance.js`
Quarterly on the 1st of Jan/Apr/Jul/Oct at 03:00 America/Toronto
(`0 3 1 1,4,7,10 *`). Deletes `done`/`cancelled` appointments whose `startTime`
is older than 2 years, **and** their Storage images. Images are deleted before
the Firestore doc so a Storage failure keeps the doc for the next run's retry
rather than orphaning PII bytes. Non-terminal appointments are never touched.
1800s timeout — the real max for a **scheduled** trigger (a higher value is
rejected at deploy, not silently clamped) — so a quarter of newly-expired
history clears in one run; the loop commits page-by-page, so any leftovers (a
timeout, or a full page whose image deletes all fail) carry to the next run —
~3 months away at this cadence.
**Its orchestration lives in `maintenance_policy.js`** (extracted 2026-08-04),
taking `db`/`deleteImages`/`now` injected: `maintenance.js` resolves a Storage
bucket at load and throws on `require()` outside the emulator, so the only
unattended irreversible deletion in the codebase had **no test at all** until
that split. `functions/__tests__/maintenance_policy.test.js` now pins the three
rules that destroy data if they regress — the status gate (live work is never
purged at any age), the images-before-doc ordering, and the loop's termination
on a page that made no progress.

## Push notifications (FCM)

All four live in `notifications.js` (thin trigger registrations); the logic —
diff/message/candidate helpers plus the injectable orchestration — is in
`notification_utils.js` (no admin/scheduler requires, so jest drives it with
mocked `{db, messaging, now, logger}`). Recipients are always filtered
server-side to `role == 'employee' && status == 'active'`; tokens live in
`users/{docId}/fcmTokens/{token}` (doc id = token, keyed by users **doc id**
so the send path needs no uid translation), and stale tokens are deleted on
send failure. Text is localized per token doc (`locale: 'en'|'fr'`) from an
inline EN/FR table; every message sets an APNs `sound` so delivery isn't
silent, plus a now-inert `android: {priority: 'high'}` (kept because it costs
nothing and FCM ignores it for an APNs-only fleet — the app has been iOS-only
since `android/` was deleted on 2026-08-05). **Deployed 2026-07-11**
— see Deployment status. Design: `docs/archive/2026-07-08-push-notifications.md`.

### `notifyAppointmentChanges` — `notifications.js`
`appointments/{id}` write trigger → assignment / reschedule / cancel /
unassignment pushes. Diffs before/after (`diffAppointmentForNotifications`):
one event per employee, priority `cancelled > removed > rescheduled >
assigned`; past appointments skipped. Deliberately **no `retry: true`** — a
duplicate push is worse than a rare missed one. **Which is exactly why every
recipient is isolated in its own try/catch** (2026-09-01): the per-recipient
loop had none, so one transient failure on the FIRST assignee threw out of the
whole handler and recipients 2..N were dropped permanently, with no retry
behind them to make it up. The five comparable fan-outs in this file already
carried the guard — this was drift, not a decision. The series-claim ordering
is deliberately left alone: a send that throws after `claimSeriesNotice`
committed still suppresses the sibling for its window, which is a separate
decision about claim semantics. **A repeat series collapses to
ONE push per (employee, kind)** via the Admin-SDK-only
`appointmentSeriesNotices` claim ledger (`claimSeriesNotice`): a "this and all
future" edit writes ~15 sibling docs in one batch, each firing this trigger, so
without the claim the tech got ~15 pushes. It **fails OPEN**. WRITES key the
claim on a fresh client-stamped **`seriesOpId`** (`_newSeriesOpId` in the
repository — one uuid per write op, shared by that batch, reused by nobody), so
a collision is definitive and needs no time window and two separate actions
both notify. DELETES have no fresh id (`before.seriesOpId` is stale), so they
fall back to `(seriesId, kind, employee)` + `SERIES_CLAIM_WINDOW_MS` (45 s) +
stale-takeover. Also updates/ends any live
"time to leave" card for the changed job, so it binds `APNS_SECRETS` and gets
`liveActivityDeps()`; the two Firestore-only sweeps below take `liveDeps()`
instead, because reading a secret param a function didn't bind logs a warning
on every invocation.

### Live Activity dispatch (no separate export)
The iOS Lock Screen card has **no function of its own** — it rides
`notifyAppointmentChanges` (update/end) and `sendUpcomingJobReminders` (start).
FCM cannot carry it: a Live Activity push needs `apns-push-type: liveactivity`
on topic `net.vogas.scheduling.push-type.liveactivity`, so `apns_client.js`
talks **directly to APNs over HTTP/2** with an ES256 provider JWT (cached, re-
minted at 50 min) built from `APNS_AUTH_KEY` / `APNS_KEY_ID` / `APNS_TEAM_ID`.
Every path is best-effort: missing secrets, no registered token, or any APNs
error degrades to the plain `leaveNow` push, which is unchanged. Targets resolve
through the Admin-SDK-only `liveActivityCards/{employeeDocId}` marker plus the
self-only `users/{docId}/liveActivityTokens` rows; both carry `expiresAt` for a
TTL prune (the rules cap a client-written `expiresAt` at `request.time + 31 d`,
just above the app's 30-day push-to-start TTL). Card text is built server-side
in EN/FR (`live_activity_utils.js`). The marker also stores the sweep's
`leadMinutes`/`travelMinutes`, because only the sweep ever has a Routes
estimate: a later reschedule rebuilds `leaveAt` from the new start minus that
lead (`_withLeaveAt`), and with no recorded lead the card renders "Starts at"
rather than labelling the job's own start time as the departure time.

Two **composite indexes are load-bearing** here: `liveActivityTokens`
`(kind ASC, employeeDocId ASC)` at **COLLECTION_GROUP** scope, and
`liveActivityCards` `(phase ASC, startTime ASC)`. Both queries are wrapped in
the feature's best-effort catch, so a missing index surfaces as
`FAILED_PRECONDITION` swallowed into "the card never appears" rather than an
error — deploy `firestore:indexes` alongside the functions. The travel→on-site
flip (`runOnSiteFlipPass`) runs on **every** sweep, not only when travel
candidates exist: a tech whose job has already started is by definition no
longer a candidate, and this pass is also what clears markers for
deleted/terminal jobs. EVERY terminal transition — done, cancelled, deleted,
and unassigned — ends the card server-side from the appointment write trigger
(`endCardOnTerminal`, generalized from the done-only `endCardOnCompletion` on
2026-07-21) — the client never ends cards off its own status write, since
`endAllActivities()` is device-wide.

### `sendUpcomingJobReminders` — `notifications.js` (+ `travel_utils.js`)
Every 5 min (Toronto). **Travel-aware "time to leave" sweep**
(`runTravelAwareReminderSweep`): queries `status in [pending, confirmed]`
(legacy alias) with `startTime` in `(now, now+90min]` on the existing
`(status, startTime)` index. **`selectTravelCandidates` skips `isAllDay`
records** — an all-day block stores a real midnight start, so it entered the
90-min window at ~23:30 the night before and fired a "time to leave" push for
something with no departure time. A *timed* personal job still gets its
reminder; only the all-day case is excluded (mirrors the `isPersonal` skip in
`selectOverdueCandidates`). Per (job, assignee) it picks a departure origin —
an intervening job's address → a fresh background-GPS presence doc
(`updatedAt` ≤ 25 min) → a recently-ended job's address (≤ 4 h) → none — via one
per-employee context query (bounded by `CONTEXT_QUERY_MAX` and by an `endTime`
ceiling of window + max-booking — narrowing that ceiling to the travel window
alone would drop a long intervening job that started inside the window but runs
past it). **That query needs `appointments (employeeIds CONTAINS, endTime ASC)`
— its OWN index, not the longer `(… endTime ASC, startTime ASC)` one**, because
it ends on `orderBy("endTime")` and Firestore appends `__name__` at the END, so
no prefix of the longer index puts `__name__` directly after `endTime`.
Deleting it as a "redundant prefix" on 2026-08-29 broke every travel-aware
reminder for two days, invisibly — this path is best-effort and falls through
to the fixed 30-minute kind. Restored 2026-08-31; see
`.claude/rules/firestore-indexes.md`.
plus a batched `getAll` of the presence docs, then calls Google Routes
API `computeRoutes` (`TRAFFIC_AWARE`) and fires at
`startTime − driveTime − 10min` (lead capped at 90 min). **Every failure path —
no origin, empty address, any Routes error — degrades to the fixed 30-min
`reminder` kind**, so it never regresses below the old behavior; the `leaveNow`
kind sets APNs `interruption-level: time-sensitive`. Needs the
`GOOGLE_MAP_API_KEY` secret (shared via `params.js`) and `timeoutSeconds: 120`;
requires the **Routes API** enabled and added to the key's API restriction.
Drive-time estimates are memoized per (job, assignee) for ~10 min so a job
sitting in the 90-min window isn't re-priced on all ~18 sweeps before it fires;
a cached estimate may only ever **defer** a Routes call, never trigger a send.
Fires one localized reminder per assignee, exactly-once **per recipient** via
the Admin-SDK-only
`appointmentReminders/{id}_{startMs}_{employeeDocId}` ledger (`create()` fails
if it exists; a reschedule changes the key → fresh reminder). Per-recipient
keying means an assignee whose token registers late is retried independently
without re-notifying an assignee already delivered (a per-occurrence ledger
would drop the late one for good). As in the overdue sweep, a claim that
delivered **zero** pushes (no live token registered yet, or the send threw) is
released so a later sweep retries while the job is still upcoming, and each
recipient's send is isolated so one transient failure can't abort the sweep.
Ledger docs carry `expiresAt` (+7 d) for the console-enabled Firestore TTL
policy.

### `sendDailyJobDigest` — `notifications.js`
Daily 18:00 Toronto. Groups tomorrow's (Toronto-midnight-bounded) jobs by
employee; one summary push per employee with ≥1 job. No ledger (runs once
daily; a rare crash-retry duplicate is accepted). Queries `status in
OPEN_STATUSES` (`pending`/`in_progress`/legacy `confirmed`, single-sourced from
`OPEN_LIKE`) — it previously hardcoded `["pending", "confirmed"]`, silently
dropping every `in_progress` job from the digest even though the pure grouping
filter excludes only `cancelled`; the query and filter now agree. **Each
employee's send is wrapped individually** — the sends run through one
`Promise.all`, so before that a single transient token read rejected the whole
map and cost every *other* employee tomorrow's schedule.

**The candidate query orders `startTime` DESC, and the direction is the whole
point of `DIGEST_SWEEP_MAX` (1000)** — fixed 2026-08-16. The floor is
`tomorrowStart − MAX_APPOINTMENT_SPAN_MS`, i.e. 15 days in the *past* (a run
that began days ago can still be on site tomorrow), so ascending made the cap
keep the OLDEST still-open jobs and discard the newest — tomorrow's, the only
ones this digest is about. Once >1000 open jobs fell in that window the 18:00
run read 1000 documents that had all started a week or more ago,
`groupTomorrowsJobsByEmployee` found no overlap, and **every crew got no digest
at all** — the exact silent omission the cap exists to prevent, inverted. The
comment above it justified ascending with reasoning imported from
`runTravelAwareReminderSweep`, whose window starts at `now`. Served by the
existing `(status, startTime DESC)` composite — no new index — and the list is
reversed in memory before grouping so each employee's jobs stay chronological.

**Reachability is checked before the widget-window read.** `_loadRecipient` +
`_canReachRecipient` run above `fetchEmployeeWidgetWindow`, the order
`handleAppointmentWrite` already established: otherwise an inactive,
wrong-role or tokenless employee cost a 200-doc query and a full widget-payload
build/JSON encode every day for a send that returns 0. Both reads land in the
same per-run cache, so asking costs nothing extra.

### The overdue sweep — `notifications.js` (rides `sendUpcomingJobReminders`)
**Not its own export.** `sendOverdueJobPrompts` was a standalone `every 15
minutes` scheduler until 2026-08-13; it is now `runOverduePromptSweep`, called
from `sendUpcomingJobReminders` in its own `try/catch` after the travel sweep.
The merge is a **cost** change, not a behaviour change — Cloud Scheduler bills
per job beyond the first three and this repo had six. Running three times as
often is free of side effects because the per-recipient ledger below, not the
cadence, is what guarantees at-most-once delivery. It takes `liveDeps()`, not
`liveActivityDeps()`: this half is Firestore-only and must not read the APNs
secrets.

The "job finished?" nudge: pushes assignees of a job
whose `endTime` passed within the last 2 h (`OVERDUE_LOOKBACK_MS`,
`notification_policy.js`) while its status is still open
(`pending`/`in_progress`/legacy `confirmed` — server mirror of the app's
display-only `overdue` state; nothing is ever stored). Queries `endTime ∈
(now−2 h, now]` — the eligibility rule itself, so the scan is its width and
not a superset — **ordered `endTime` DESC** on the `(status, endTime DESC)`
composite index (**added 2026-08-13; deploy `firestore:indexes` with it or the
sweep fails `FAILED_PRECONDITION` and prompts nobody**) so the
`OVERDUE_SWEEP_MAX` cap keeps the newest-overdue jobs rather than the ones
closest to aging out. It queried `startTime` until then, which needed a floor
of the lookback **plus the longest bookable span** — ~15 days, since a job that started
a fortnight ago can still have just ended — and so re-read every open job of
the past two weeks on each of the 96 daily runs to prompt the handful that had
actually ended. A doc with no `endTime` is now excluded by the filter rather
than read and dropped in code. At-most-once
**per recipient** via the
`appointmentOverduePrompts/{id}_{endMs}_{employeeDocId}` ledger; a claim that
delivered **zero** pushes is released (doc deleted) so a later sweep retries
that recipient, and each recipient's send is isolated so one transient failure
can't abort the sweep. **That isolation now covers building the ledger ref
itself**, which is composed from the employee doc id: a `/` in an `employeeIds`
element makes an invalid document path, and constructing it outside the `try`
threw before any per-recipient handler could catch — one malformed id
permanently killed every overdue prompt for the whole fleet. The scheduler body
is also wrapped and logged like its two siblings, so a sweep that dies is
visible instead of silent. Candidates are processed serially, which is why the
host function's **420s timeout** takes the larger of the two budgets the
separate schedulers carried (120 and 300) plus headroom — a backlog here must
not leave the newest overdue jobs unprompted, and it must not eat the travel
sweep's budget either.

## User → uid bridge

### `syncUsersByUid` — `bridge.js`
`users/{id}` write trigger that mirrors each user into `usersByUid/{uid}` so
security rules can resolve a caller's role from their auth uid alone (rules can
only `get` by full path, and `users` docs use generated ids). Suppresses the
bridge for `invited` users (no uid yet) and unknown statuses; handles uid
rotation (stale delete + new set in one batch). `retry: true` — all writes are
absolute, so retries converge.

It also owns **deactivation enforcement**, all of it strictly after the
auth-critical bridge write and each step independently idempotent: leaving
`active` disables the Firebase Auth account and revokes its refresh tokens, then
purges `presence/location`, the `fcmTokens` and `liveActivityTokens`
subcollections (`recursiveDelete`, so >500 rows can't fail partway), and the
`liveActivityCards/{docId}` marker. Entering `active` re-enables the account.
`auth/user-not-found` is swallowed — `deleteAccount` removes the Auth user
before the Firestore doc, so the trigger's later revoke is a no-op rather than a
retry loop. Without this the rules' `status == 'active'` gates would still be
reachable with a stale credential.

Deactivation used to additionally **rotate the Storage download tokens** on
every photo of every appointment the person was assigned to
(`rotateAssignedImageTokens`, `appointment_image_tokens.js`). **That module was
deleted at the photo-subcollection CONTRACT step**, together with the
`(employeeIds CONTAINS, endTime DESC)` composite it needed and this trigger's
raised `timeoutSeconds` (back on the 60 s default). It existed because
`ImageStorageService.uploadImage` persisted a `getDownloadURL()` link per photo
into `pictures[]`: that link's `firebaseStorageDownloadTokens` value is stable
per object and never expires, and fetching it serves the bytes over plain HTTPS
with **no auth and no `storage.rules` evaluation**, so revoking the credential
did not reach the links already on that person's device. The app no longer mints or stores one, the
subcollection rules now REJECT the field, and the prod count of legacy rows
that still carried one came back **zero** (2026-08-22,
`scripts/count-legacy-image-urls.js`), so there is nothing left for a rotation
to invalidate — photos are fetched through the SDK, where this branch's status
flip is the gate. Two things that does NOT cover: a URL captured under an older
build is still live on its object unless someone rotates it by hand, and the
`pictures[]` arrays themselves are cleared by
`scripts/clear-appointment-picture-arrays.js`, which is step 4 of the runbook
in `docs/DEPLOYMENT.md` and is the irreversible one.

The bridge's pure rules live in `bridge_policy.js` (`shouldHaveBridge`,
`bridgeBody`, `bridgeMatches`, `classifyBridgeRow`), shared with
`scripts/backfill.js` — the only script here that deletes, and until 2026-08-16
the only one with no test.

### The shared `functions/scripts/_*.js` trio
Every one-off script in that directory runs under `applicationDefault()`, so
nothing on the command line says which project it will write to. Three shared
modules exist because each of them prevents a specific way a bulk run goes
wrong, and each was hand-copied (and had drifted) before it was extracted:

- **`_flags.js`** — rejects any argument the script does not know, so a typo'd
  `--dryrun` fails loudly instead of reading as `false` and going LIVE. The
  flag LISTS stay local to each script; only the rejection rule is shared.
- **`_batch.js`** — the batched-write loop, so `--dry-run` cannot be forgotten
  at a call site.
- **`_project.js`** (2026-08-22) — `printTargetBanner(app, {dryRun})` and the
  `resolveProjectId` behind it, printed BEFORE the first read. Four scripts had
  no banner at all, including the irreversible
  `clear-appointment-picture-arrays.js`, and three more hand-rolled a weaker
  copy that stops at the two env vars — which prints `(unknown)` in exactly the
  credential setup the runbooks recommend (`GOOGLE_APPLICATION_CREDENTIALS`
  pointing at a service-account JSON, whose project `applicationDefault()`
  reads internally and never exposes on `app.options`). The banner goes blank
  precisely when credentials were supplied properly, which is the worst
  possible time. All ten scripts now print it.

## Client → appointment propagation

### `propagateClientEdits` — `client_propagation.js`
`clients/{id}` update trigger that propagates a client's edited `clientName` /
`clientPhone` / `address` to that client's **future** appointments (history is
left as it was at visit time). `address` follows the client only when the
appointment's stored address equals the client's *previous* address (a differing
one is treated as a per-appointment custom address). Requires the composite index
`(clientId ASC, startTime ASC)` on `appointments`. `retry: true` — writes are
absolute values. The page loop runs to **exhaustion on purpose and must not
gain a total cap** (truncating would leave stale denormalized `clientName` on
the future visits this trigger exists to keep correct), so instead each
page's batch commits while the next page is fetched — at most one commit
outstanding, settled through the same `Promise.all` that awaits the fetch —
and the success log carries a `pages` count, which is the only signal that a
client with several live series costs hundreds to low-thousands of reads per
edit. **Deployed** (verified live 2026-07-10).

### `recountClientJobs` — `client_job_count.js`
`appointments/{id}` write trigger that maintains the denormalized `jobCount` on
the client doc. Recomputes with a `count()` aggregate and writes the value
**absolutely** — never `FieldValue.increment`, because `retry: true` means a
retried event would double-count. Fires only when `clientId` actually changes
(create, delete, reassignment), so an ordinary title or time edit costs zero
reads; personal jobs carry no `clientId` and are skipped. Writes with `update()`
rather than `set({merge: true})` so a client removed out-of-band is never
resurrected as a count-only stub, and swallows Firestore `NOT_FOUND` for the same
case. The pure `clientsToRecount(before, after)` is exported for jest. Served by the
`(clientId ASC, dayIndex ASC)` composite — the run subtraction is a second
`count()` over `dayIndex > 1`, which the automatic single-field index on
`clientId` cannot serve. That index is deployed and LIVE; do not delete it.
**Deployed 2026-08-01** (`16332b3`).

A booking batch can land up to 16 writes carrying one `clientId` at once (a
multi-day run's day-documents, a repeat series' occurrences), so those are
DEBOUNCED through the shared `recount_claim.js` ledger
(`clientRecountClaims/{clientId}`, `RECOUNT_SETTLE_MS` 2 s) into one aggregate.
**The debounce is GATED on `mayShareABatch`** (2026-08-28): unconditionally it
also charged every ordinary single create or delete 2 s of billed wall-clock
plus a claim `create()` **and** `delete()` — taking the common path from 2
Firestore writes to 4 to save writes on the rare one. The gate reads the batch
markers off the document itself (`dayCount > 1`, or a non-empty `seriesId`), so
it needs no extra read, and it tests `seriesId` for merely being non-empty
rather than differing from the document's own id: the series ROOT is written in
the same `WriteBatch` as its siblings and carries its own id there.

### `deleteClient` — `clients.js`
Admin-only callable, the **only** delete path for a client in this build.
`allow delete` on `/clients` is withdrawn from this build's code path AND from
`firestore.rules` — the `#compat-1.37.1` grant (kept for 1.37.1's ungated
Delete button) was retired 2026-08-08, closing the orphaning hole; see
docs/DEPLOYMENT.md. The callable exists because rules cannot express
"only when this client has
no appointments" — there is no cheap way to count a foreign collection there.
Refuses with `failed-precondition / client-has-history` when a **live `count()`
aggregate** over `appointments where clientId == …` returns non-zero, and with
`not-found` when the doc is already gone. The count is deliberately NOT the
denormalized `jobCount`: that field is lazily backfilled by `recountClientJobs`,
so it can be stale, missing, or wrong on a client whose appointments were
reassigned out-of-band — deleting on a stale zero is exactly the orphaned-history
bug this gate exists to prevent. Guard order is auth → `assertAdmin` →
`assertPayloadShape`/`requireString` (plus a `/`-in-id reject, since `.doc()`
throws synchronously on one) → `enforceDurableRateLimit` (20/hr per admin uid) →
work. The pure `performDeleteClient(db, clientId)` is exported for jest.
Archive — not delete — is the normal way a client leaves the roster.
**Deployed 2026-08-03** (`ef3a9cf`), verified ACTIVE.

## Appointment photos → subcollection

Photos live in `appointments/{id}/images`. They were moved off the `pictures`
array on each appointment because every appointment read carried the whole
array (a download URL alone was ~215 of a ~290-byte entry) while only the
detail sheet ever renders one, and the calendar reads up to 1000 appointments
at a time. Phase 1 (2026-08-13) wrote both stores; **the CONTRACT step retired
the array**, so the two functions below are now the sole server-side owners of
a photo, and `pictureCount` on the parent is the only thing that knows a job
has any. See `.claude/rules/images.md`.

### `cascadeDeleteAppointmentImages` — `appointment_images.js`
`appointments/{id}` **delete** trigger that removes the whole `images`
subcollection. **This is not cleanup — it is the reason the feature needs a
server component at all: Firestore does NOT delete a subcollection when its
parent document is deleted.** Without it every appointment delete leaves photo
documents orphaned under a parent that no longer exists: invisible in the
console, unreachable by every query the app makes, and with nothing anywhere
reporting it. Covers all three delete paths — the client's single delete, its
series delete, and `purgeExpiredHistory` (Admin SDK deletes fire triggers too).
**It also deletes the Storage BYTES, and that half is not cleanup either.**
Until the CONTRACT step the client did it, enumerating `appointment.pictures` to
know which objects to remove; that array is gone, and a client that no longer
reads the photos cannot list what to delete — so without this every appointment
delete orphans its photos in Storage, billed monthly and reachable by no query.
The prefix (`appointments/{id}/images/`) comes from the appointment id rather
than from any stored path, so it also sweeps bytes whose document link never
landed. **ORDER: bytes first, documents second**, the same rule
`purgeExpiredHistory` follows — the documents are the last thing pointing at
those objects, so dropping them before the bytes are gone loses the trail on a
failure. Uses `deleteFiles({prefix})` for the bytes and `recursiveDelete` for
the documents, the same Admin-SDK bulk writer `syncUsersByUid` already uses for
`liveActivityTokens`. **RETHROWS** on either half, deliberately unlike the
best-effort cleanup elsewhere in this codebase: a swallowed error leaves exactly
the permanent invisible orphans it exists to prevent, and rethrowing is what
makes `retry: true` mean anything. `retry: true` is safe because both halves are
idempotent — a second pass finds nothing. The pure
`purgeAppointmentImages(id, {db, deleteImages})` is exported for jest.
Removing ONE photo from a job that still exists stays client-side; only the
whole-appointment delete is here.

### `recountAppointmentPictures` — `appointment_images.js`
`appointments/{id}/images/{imageId}` write trigger maintaining the denormalized
`pictureCount` on the parent. Exists because `AppointmentCard` shows a photo
indicator and renders on every range-query surface, so it cannot afford a
subcollection read per card; ~15 bytes against ~290 per photo entry. Recomputes
with a `count()` aggregate and writes **absolutely** — never
`FieldValue.increment`, same rule and same reason as `recountClientJobs` under
`retry: true`. Writes with `update()` rather than `set({merge: true})` so an
appointment deleted in the window is never resurrected as a count-only stub; a
Firestore `NOT_FOUND` there is the **normal** path, not an error, because
`cascadeDeleteAppointmentImages` has just removed the photos. `pictureCount` is
function-owned: `firestore.rules` rejects a client UPDATE that touches it and
`AppointmentRecord.toMap()` must never emit it. **The one exception is the
create**, which may write it as exactly 0 — since the CONTRACT step this counter
is the only thing that knows whether a job has photos, and the detail sheet
skips its subcollection read on a 0, so "absent" would otherwise be a third
state meaning "nobody has counted yet" on every job until its first photo.
It also **warns past `PICTURE_COUNT_WARN_CAP` (100)**: the array's rules cap
guarded the parent document's 1 MB ceiling and a subcollection has none, so the
cap was not reinstated — but the app reads at most that many photos
(`AppointmentImagesStore.scanLimit`, the same number), and anything beyond is
simply absent with nothing else to say so. **No loop risk** — this triggers
on the subcollection and writes the parent, a different path. The parent write
does re-fire `notifyAppointmentChanges`, which produces no events for a
count-only change and returns before any Firestore work. The pure
`recountPictures(id, {db, logger})` is exported for jest.

## Wave Accounting

Admin-only integration syncing the `clients` collection to Wave customers. The
full-access Wave token lives in Secret Manager (`WAVE_FULL_ACCESS_TOKEN`); the
target business is resolved server-side from `WAVE_BUSINESS_NAME`. The app never
reads the rules-locked `wave` collection directly. The integration's invariants
(import timestamps, outbox transactionality, cadence) live in the Wave bullet of
CLAUDE.md; the original ultra-review findings are archived at
`docs/archive/WAVE_REVIEW_FINDINGS.md`. (An older `WAVE_INTEGRATION_PLAN.md` was
deleted in `39feb0f` — don't restore the pointer.)

All four Wave callables run the guards in the documented order — auth →
`assertAdmin` → `assertPayloadShape` → rate limit. `assertAdmin` above the
payload check keeps a non-admin from distinguishing `unexpected-field` from
`wave/not-admin`; the limiter stays below both so a rejected caller can't burn a
legitimate admin's slots.

### `waveBootstrap` — `wave/callables.js`
Admin-only, idempotent get-or-create of the `wave/connection` doc. An
already-connected doc short-circuits (not rate-limited); the not-yet-connected
path makes live Wave calls (`whoami` + `listBusinesses`) and is rate-limited
10/hr. Business is chosen server-side — the app sends no selector.

### `waveGetConnection` — `wave/callables.js`
Admin-only read of `wave/connection` — the **only** Wave read path for the app
(the Settings Wave section calls it on mount to show "Connected to X"). No
secret. **Durably rate-limited at 60/hour per admin uid** (`wave-connection`) —
a higher ceiling than the write callables because this one is called on every
Settings mount, but it is a limiter like all the rest, so don't "fix the gap"
by adding a second one.

### `waveSetImportSchedule` — `wave/callables.js`
Admin-only setter for the automatic-import cadence — writes the `importSchedule`
field (`off` | `weekly` | `monthly`) on `wave/connection`. Validates the value
against the shared `SCHEDULE_SET` (the membership form of `SCHEDULE_VALUES`,
owned beside it in `import_schedule.js`) and requires an already-bootstrapped
connection. No secret. **Durably rate-limited at 20/hour per admin uid** (added
2026-08-04) — every other admin write callable is, and the audit flagged this as
the lone exception. The limiter sits AFTER the payload validation so a burst of
malformed submissions can't exhaust a legitimate caller's window.

### `waveImportCustomers` — `wave/callables.js`
Admin **two-way** sync behind Settings › "Sync with Wave" (2026-08-04). The
callable keeps its original, now-inaccurate name because renaming a deployed
callable deletes the one **every** shipped build calls — a constraint that
outlived the `#compat-1.37.1` shim it was first tagged with, and that any
future rename still has to solve (deploy both names, then drop the old one
once no build calls it).

**Push, then pull, in that order.** `drainForSync` first drains pending
`waveSyncQueue` jobs to Wave, then `importCustomers` (`wave/customers_import.js`
— the pull half was split out of `wave/customers.js`, which keeps the push half
and re-exports `importCustomers`, so no call site changed) pulls Wave customers
back (paginates ~650 customers over ~7 Wave pages). The order is the correctness
rule: the outbox holds edits the app already accepted, so importing first would
overwrite them with the Wave rows they are on their way to replace.

**Ordering is not sufficient on its own.** The import overwrites every mapped
field of a linked client with Wave's values *and* stamps `wave.lastSyncedHash`
from them, so a client edit still in the outbox is not just overwritten — it is
marked synced, and the pending job then hashes the clobbered doc, matches, and
no-ops. The drain is bounded and its query only takes jobs already due, so a job
backed off after a transient Wave error survives it. Both this callable and
`runWaveDaily` therefore pass `importCustomers` a `skipClientIds` set
from `listOutstandingClientIds` (`wave/worker.js`, covering `queued` and
`inflight`); skipped clients are counted as `skippedPending`. The set is
injected rather than read inside `wave/customers_import.js` because `worker.js`
already requires that module and reaching back would close a cycle.

The push half is **best-effort and bounded** — `SYNC_PUSH_BATCH_LIMIT` (20) and
`SYNC_PUSH_BUDGET_MS` (20 s), with the `waveUpsertCustomer` trigger having
already pushed each edit as it was made and the daily sweep retrying the rest —
so a drain failure is logged and swallowed rather than failing the
import the admin actually pressed the button for. Both bounds are sized against
the *client's* deadline (`kWaveSyncTimeoutSeconds`, 120 s, in
`wave_service.dart`), not the 300 s function timeout: a callable can't be
cancelled, so past that deadline the admin has already been told the sync failed
and will tap again.

Response adds `pushedCreated` / `pushedUpdated` / `pushedPending` /
`pushedFailed` / `pushIncomplete` to the existing import summary — **additive
only**, since 1.37.1 parses the import half by name and ignores the rest. The
last three exist because a bounded push, a dead-lettered job and a thrown drain
all leave the counts at zero, which the app would otherwise render as "already
up to date": `pushedPending` is a `count()` of still-queued jobs taken AFTER the
drain, `pushedFailed` is `drained.dead` (dead-lettered jobs aren't `queued`, so
the pending count misses them and they never retry), and `pushIncomplete` flags
a drain or count that threw. The two success counts come from `drainQueue`'s
`created`/`updated`, which `tallyUpsert` (`wave/worker.js`) folds from each
`upsertCustomer` status; `linked` counts as an update, not a create, because
that path patches a customer a crashed earlier attempt had already created.

**The import is hash-gated.** A linked client whose stored
`wave.lastSyncedHash` already equals `mappedFieldsHash(fromWaveCustomer(node))`
is skipped (`skippedUnchanged`), so `updated` counts only real changes. The
equality is exact — both sides hash the same `toWaveCustomerInput` projection,
the identity `shouldEnqueueClientWrite`'s Rule 2 already relies on. Before the
gate, every run re-wrote all ~650 clients: ~650 writes plus ~650
`waveUpsertCustomer` invocations that each concluded "nothing to do", and the
app's notice read "650 clients updated in the app" after a sync that changed
nothing. The `hasCreatedAt` half of the condition is load-bearing — the update
branch is the only `createdAt` backfill, and the clients list orders by it.

**The imported number lands in the app's one `phone` field** (2026-08-19).
Wave models a customer's number in `phone` and `mobile`, and this business
additionally names a person BY their number, so an import that mirrored Wave's
shape routinely left the number where nothing could dial it. `importedPhone`
(`wave/mappers.js`) resolves it the way the app does — Wave's `phone`, else
Wave's `mobile`, else a number lifted out of the customer NAME — renders it
"(514) 555-1234" when it is a NANP number, and always writes `mobile: ''`. The
name itself is still mirrored verbatim: it is Wave's customer identity, so only
the phone half of the lift is taken. Since these resolved fields are what
`mappedFieldsHash` sees, a reshaped number does not enqueue a push back; Wave
keeps its own spelling until that client is next edited in-app.

Writes `createdAt`/`updatedAt` on every client doc it does write (the
list/search order by `createdAt`, and Firestore excludes docs missing the
orderBy field). Rate-limited 5/hr; 300s timeout.

**Delta import (2026-08-04).** Introspection against the live API, via a
one-off script (since deleted — its findings are recorded here) established
that `business.customers` accepts `modifiedAtAfter: DateTime` /
`modifiedAtBefore`, and that `CustomerSort` offers `MODIFIED_AT_ASC/DESC`
alongside `CREATED_AT_*` and `NAME_*`. The filter is the better lever than the
sort — it runs server-side, so Wave returns only what changed instead of us
paging everything and stopping early.

`importCustomers` therefore takes an optional `since` (ISO-8601). Present → the
`LIST_CUSTOMERS_SINCE` document; absent → the full `LIST_CUSTOMERS`. Both
documents (and `readBusinessId`) live in the leaf `wave/customer_queries.js`,
which both halves require at module scope, so the split adds no second copy of
the query and needs no lazy require-back. These are
**two separate documents on purpose**: omitting a variable to make an argument
"not present" is valid GraphQL, but relying on that against a third-party
server risks it being read as `modifiedAtAfter: null` — a full import that
imports nothing and reports success. Both must keep passing strings as
variables; Wave refuses inline `String` arguments (see `functions/CLAUDE.md`).

The watermark lives on `wave/connection` (`customerDeltaSince`,
`lastFullImportAt`) and `importCustomers` (`wave/customers_import.js`) stays
stateless about it. The whole
read → decide → import → advance sequence has **one owner**,
`importWithWatermark` in `wave/sync_run.js`, used by both the interactive sync
and the daily `runWaveDaily`; the decisions are the pure `resolveImportWindow` /
`watermarkPatch` in `wave/import_schedule.js`, placed beside `isImportDue`
because the two cadences interact.

- **The watermark is the run's START minus `DELTA_OVERLAP_MS` (5 min).** From
  the end, it would drop anything edited mid-run; without the overlap, anything
  edited in the same second the query went out, and no slack for clock skew
  against Wave.
- **It advances only over a window that was fully covered.** A throw leaves
  both stamps (the next run redoes an idempotent window). So does a run that
  reported `skippedPending > 0`: those clients were deliberately protected from
  the clobber and therefore not imported, so advancing would hide any Wave-side
  change to them until the next full pass. An *unknown* `skippedPending` is
  treated as not-covered for the same reason — holding is free, advancing
  wrongly loses data.
- **A delta-only failure retries once as a full import.** Otherwise a bad
  `modifiedAtAfter` is sticky: the watermark stays put, every interactive sync
  rebuilds the same failing query, and nothing self-heals until the 7-day
  resync ages the window out — while the scheduled path keeps working, so the
  breakage is admin-facing only.
- **A failed watermark WRITE is logged, not thrown.** The import already
  committed; failing there would report a successful sync as an error and throw
  away the push counts the notice exists to surface.
- **A full pass is forced every `FULL_RESYNC_INTERVAL_MS` (7 days).** Not for
  deletes — the import has never deleted a local client and still doesn't, so a
  customer removed in Wave keeps its doc either way. It is a backstop for
  `modifiedAt` itself: we are trusting Wave to bump it for every field we map
  and cannot verify that. Note this interval is shorter than both import
  cadences, so a scheduled run whose last full pass was a cadence ago goes full
  — in practice the delta mostly benefits the interactive sync, which is
  accepted.
- **A watermark ahead of now is refused**, not honoured — otherwise a clock or
  data fault makes every subsequent run import nothing, forever.

`buildWaveIdIndex` (`wave/customers_import.js`) is now built **lazily**, so a
delta run that finds nothing
changed costs one Wave call and zero Firestore reads instead of ~650 document
reads to resolve nothing. When a delta does have work, it still reads the whole
`clients` collection — a targeted `whereIn` lookup over just the changed wave
ids would avoid that, and is the remaining optimisation here.

**`totalCount` on a delta summary is the size of the queried set** — the number
of changed customers, not the roster size. Don't render it as "you have N
clients".

### `waveUpsertCustomer` — `wave/triggers.js`
`clients/{id}` write trigger. When a client's Wave-mapped fields change, marks
the doc `wave.syncState: pending` and enqueues a `customerUpsert` job on the
`waveSyncQueue` outbox (deterministic job id → burst edits collapse to one job).
Both writes land in one batch. `retry: true` — idempotent and hash-guarded.

**It then PUSHES that job immediately** (2026-08-13), which is what replaced the
deleted `waveSyncWorker` scheduler. It binds `WAVE_FULL_ACCESS_TOKEN` and runs a
bounded `drainQueue` (`batchLimit` 20, 180 s budget, 300 s function timeout)
after the enqueue commits. Two properties are load-bearing:

- **The drain must never throw.** The job is already durably queued, so a drain
  failure is a delay, not a loss — and throwing would re-run the whole handler
  under `retry: true` for something a retry cannot fix. It is caught and logged
  at `warn`.
- **It cannot loop.** `upsertCustomer` writes `wave.*` back onto the client doc,
  which re-fires this trigger — but `mappedFieldsHash` is unchanged by that
  write, so `shouldEnqueueClientWrite` returns false at the top and the re-fire
  never reaches the drain.

A disconnected install still enqueues (the outbox is durable) but does not
drain; the connection gate is the cached `readWaveBusinessIdCached`, which is
what keeps that case off a Firestore read per client edit.

Draining here rather than on a 5-minute poll is both cheaper and faster: an idle
day costs zero invocations instead of 288, it frees a Cloud Scheduler slot (only
3 are free per billing account), and an edit reaches Wave in seconds instead of
up to five minutes. Needs the same `waveSyncQueue` composite indexes the worker
did: `(status ASC, nextAttemptAt ASC)` and `(status ASC, claimedAt ASC)`.

### `waveRetryFailedJobs` — `wave/callables.js`

Admin-only recovery for **dead-lettered** outbox jobs, called from Settings
(`wave_service.dart`). A `dead` job is terminal — no drain picks it up again —
so without this the client's data diverges from Wave permanently, and the only
way back was editing the client again to mint a fresh job, which an admin would
have to know to do and would only think to do if they noticed the error badge.

**Deliberately explicit, never an automatic requeue on a timer.** A job that
died on a `WaveValidationError` will die again, so a timer would spin forever
re-reporting the same failure. The admin presses this once they have fixed the
data or the outage has passed.

Guard order is the standard one — auth → `assertAdmin` → `assertPayloadShape`
(empty key set; it takes no payload) → `enforceDurableRateLimit`
(`wave-retry`, **10/hour per admin uid**) → work. Refuses with
`failed-precondition / wave/not-connected` when no business id is stored.

`requeueDeadJobs()` is the durable part; the `drainQueue` that follows is
**best-effort and must not fail the call**, so the press has a visible effect
without the requeue being reported as a failure when only the push behind it
broke. Returns `{requeued, scanned, pushed, failed}` — `pushed` and `failed`
are both null when nothing was requeued or the drain threw.

**`failed` (`drained.dead`) is what keeps the press honest, and it is the same
class of omission `pushedFailed` fixed on the sync response.** The reason this
callable is deliberately manual — a job that died on a `WaveValidationError`
dies again — is exactly what makes the drain behind the requeue dead-letter it
a second time *inside this call*: the queue's dead count is unchanged, the
Settings row still reads "1 client failed to sync", and an app that sees only
`requeued` announces "1 client queued for Wave again" as a success over it. The
count was right; the sentence over it was the lie. `waveRetryNotice`
(`wave_sync_notice.dart`) composes from both counts and the section surfaces it
with `notices.error` when `failed > 0`.

**What it could NOT fix, until 2026-08-15: a dead-letter whose cause is stored
on the doc.** Both prod cases were a `waveCustomerId` pointing at a customer
deleted in Wave; `customerPatch` answers `NOT_FOUND`, which is correctly
non-retryable, so every press re-sent the same missing id and dead-lettered
again. `upsertCustomer` now relinks instead (see `functions/CLAUDE.md`).
The general shape to watch for: this callable can only help a job whose failure
was about the *moment*, never one about the *payload* — anything permanent has
to be healed at the source or it comes straight back.

Related: `listOutstandingClientIds` (`wave/worker.js`) protects `queued`,
`inflight` **and `dead`** client ids from being overwritten by an import — a
dead job's edit is the one *most* at risk, because unlike the other two it will
not self-heal without this callable.

### `runWaveDaily` — `wave/triggers.js` (rides `sendDailyJobDigest`)
**Not its own export.** `waveScheduledImport` was a standalone `every 24 hours`
scheduler until 2026-08-13; the daily Wave maintenance is now `runWaveDaily`,
rider 3 on `sendDailyJobDigest` — in its own `try/catch`, strictly after the
digest has sent, which is the whole safety argument for merging. Same cost
reasoning as the overdue sweep: it is one of the two merges that took Cloud
Scheduler from six jobs to three. The host binds `WAVE_FULL_ACCESS_TOKEN` and
carries the 540 s timeout this work needs on its own.

Its `connection` read is inside a try (2026-09-01). That was the one `await`
here outside one, so the "never throws" contract in its own docstring was not
true on its own terms: a transient `unavailable` there rejected out of a rider
whose HOST had already finished its real work. The caller's catch is
belt-and-braces and stays.

It does two things, and the first runs unconditionally.

**1. Drains the outbox (app → Wave), always** — before the cadence check, in its
own try/catch. This is the safety net under the event-driven push above, and it
exists because two states cannot produce a client write to ride on: a job that
failed and is sitting on its `nextAttemptAt` backoff, and a job left `inflight`
by an instance that died mid-dispatch (reclaimed by `drainQueue`'s lease pass).
**It runs even when `importSchedule` is `off`** — that setting governs the PULL,
and `off` is the default, so gating the push on it would mean a default install
never pushes automatically at all. Bounded to a 180 s slice so the import below
still has budget.

**2. Pulls (Wave → app), only when the cadence is due** — `isImportDue` in
`wave/import_schedule.js`, a pure jest-testable helper (`off` or any unknown
value never runs). Server-triggered, so no App Check / rate limit. A due run
stamps `lastAutoImportAt`; a failed run leaves it unchanged so the next day
retries.

The order is also the push-before-pull invariant: an import overwrites every
mapped field of a linked client AND stamps `wave.lastSyncedHash` from Wave's
values, so an un-pushed local edit underneath it is not merely overwritten but
marked *synced* — silently lost. It passes the same `skipClientIds` protect-list
as `waveImportCustomers`, read AFTER the drain so a job the drain completed is
not protected for nothing while anything it could not finish still is.
