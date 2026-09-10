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

Loaded when working on the Wave sync. Root context: `../../CLAUDE.md`;
functions overview: `../../functions/CLAUDE.md`. Client-side client rules —
the sync badge, `clients/{id}.name` as Wave's customer name — are in
`clients.md`.

- **Wave Accounting** (`functions/wave/*`): admin callables (`waveBootstrap`,
  `waveImportCustomers` — App Check + `assertAdmin` + `enforceDurableRateLimit`).
  **`waveImportCustomers` is a TWO-WAY sync despite its name** (2026-08-04): it
  drains the outbox to Wave via `drainForSync` and only then imports. The name
  is historical and **stays** — renaming a deployed callable deletes the one
  every shipped build calls, so the cost of the accurate name is a broken
  "Sync with Wave" button on every phone until it updates. This outlived the
  `#compat-1.37.1` shim it was first tagged with: the constraint was never
  specific to 1.37.1.
  **Customer sync is THREE FILES, and the third is what keeps the other two
  acyclic.** `wave/customers.js` keeps the App → Wave push (`upsertCustomer`,
  `writeSyncSuccess`); `wave/customers_import.js` owns the Wave → App pull
  (`importCustomers`, `importOneCustomer`, `buildWaveIdIndex`, `BATCH_LIMIT`);
  and `wave/customer_queries.js` is a LEAF holding what both need —
  `readBusinessId` and the `LIST_CUSTOMERS`/`LIST_CUSTOMERS_SINCE` documents.
  It requires nothing, so it cannot participate in a cycle. `customers.js`
  still re-exports `importCustomers`, so **no call site changed** —
  `sync_run.js`, `callables.js` and the jest suite all still
  `require("./customers")`.
  Those three lived in `customers.js` until 2026-08-19, which forced the pull
  half to require the push half back at RUN time (a `pushHalf()` shim) and made
  `customers.js` export three internals under a comment saying they were not
  public. Put anything both halves need in the leaf; **never** add a require
  from `customers_import.js` back to `customers.js`, and never re-introduce a
  lazy require to dodge one — whichever file loaded second would see a
  half-built `exports`.
  **AN IMPORT MUST NEVER TOUCH A CLIENT WITH AN UN-PUSHED OUTBOX JOB.** This is
  the invariant, and push-before-pull is only half of it. `importCustomers`
  overwrites every mapped field of a linked client with Wave's values AND
  stamps `wave.lastSyncedHash` from them — so a queued edit isn't merely
  overwritten, it is marked *synced*: the pending job then hashes the clobbered
  doc, matches, returns `noop`, and the edit is gone with the row reading
  "synced" and nothing logged. Ordering alone does not prevent it, because the
  drain is bounded AND its query only takes jobs already due — a job backed off
  after a transient Wave error is invisible to the drain and still live
  milliseconds later. Every caller of `importCustomers` therefore passes
  `skipClientIds` from **`listOutstandingClientIds`** (`worker.js`, covers
  `queued`, `inflight` AND `dead` — the prose here said "queued AND inflight"
  until 2026-09-10, which is not what the query says; a dead job's client has
  an un-pushed edit too, so protecting it is correct);
  the param is injected rather than read inside
  `customers_import.js` because `worker.js` already requires that module and
  reaching back would close a cycle. Both callers need it — the daily
  the daily `runWaveDaily` most of all, since it runs unattended.
  **The import is hash-gated, and `updated` counts REAL changes only.** It
  skips any linked client whose stored `wave.lastSyncedHash` already equals
  `mappedFieldsHash(fromWaveCustomer(node))` (counted as `skippedUnchanged`).
  That equality is exact, not a heuristic — both sides hash the same
  `toWaveCustomerInput` projection, which is the identity
  `shouldEnqueueClientWrite`'s Rule 2 already depends on to stop an import
  feeding every client back into the outbox. Without the gate the import
  re-wrote all ~650 clients every run: ~650 writes AND ~650
  `waveUpsertCustomer` invocations per press that all conclude "nothing to
  do", and the app reported "650 clients updated in the app" after a sync that
  changed nothing. **The `hasCreatedAt` half of the condition is
  load-bearing** — the update branch is the only thing that backfills a missing
  `createdAt`, and the clients list orders by it, so skipping a doc without one
  hides it from the list forever.
  **The import is also a DELTA when `since` is supplied** (2026-08-04): Wave
  filters `modifiedAtAfter` server-side, so it returns only changed customers.
  `LIST_CUSTOMERS_SINCE` is a **separate document** from `LIST_CUSTOMERS`, not
  one query with a nullable variable — a server reading an omitted variable as
  `modifiedAtAfter: null` would give a full import that imports nothing and
  reports success. **`importCustomers` stays stateless about the watermark; the
  whole read → decide → import → advance sequence has ONE owner,
  `importWithWatermark` (`wave/sync_run.js`)**, called by both the interactive
  sync and the unattended daily import. It was hand-copied in both before, and
  each omission fails silently in its own direction; the unattended copy — the
  one where a mistake is invisible — was the untested one. The decisions
  themselves are the pure `resolveImportWindow` / `watermarkPatch`, in
  `wave/import_schedule.js` beside `isImportDue` because the two cadences
  interact.
  **THE WATERMARK ADVANCES ONLY OVER A WINDOW THAT WAS FULLY COVERED.** Three
  things break it, all silent, all handled: a throw (leaves both stamps, next
  run redoes the window), a run with `skippedPending > 0` (those clients were
  deliberately protected from the clobber, so their Wave-side change would be
  invisible to every later delta — the watermark is HELD), and an unknown
  `skippedPending` (treated as not-covered, since holding is free and advancing
  wrongly loses data). It is the run's START minus an overlap, never its end.
  **A delta-only failure retries once as a FULL import** — without that, a bad
  `modifiedAtAfter` makes every interactive sync fail identically until the
  7-day resync ages the window out, and only the admin-facing path breaks. **A
  failed watermark WRITE is logged, not thrown**: the import already committed,
  and failing there would report a successful sync as an error and discard the
  push counts with it.
  A periodic full pass runs every 7 days: not for deletes
  (the import never deletes a local client) but as the backstop for `modifiedAt`
  itself, which we trust Wave to bump and cannot verify. That interval is
  shorter than both cadences, so the SCHEDULED import normally goes full every
  time and the delta mostly benefits the interactive sync — accepted, since a
  weekly job paying 7 Wave pages costs nothing. `buildWaveIdIndex`
  (`wave/customers_import.js`) is built lazily so a no-op delta costs zero
  Firestore reads. Full detail:
  `docs/CLOUD_FUNCTIONS.md`.
  **Wave rejects INLINE STRING ARGUMENTS — every string must travel as a
  GraphQL variable** (`GRAPHQL_VALIDATION_FAILED: Inline argument of type
  String is not allowed`). Confirmed against the live API 2026-08-04. Inline
  `Int`/`Boolean` are accepted; only `String` is refused. Every query in
  `wave/customers.js` already parameterises, so this only bites a query
  written by hand — write the variable in from the start rather than
  discovering it as a 400.
  The push is best-effort (bounded by `SYNC_PUSH_BATCH_LIMIT` /
  `SYNC_PUSH_BUDGET_MS`, with the `waveUpsertCustomer` trigger having already
  pushed each edit as it was made and the daily sweep retrying the rest) and its
  failure must never fail the import. Those two bounds are sized against
  `kWaveSyncTimeoutSeconds` (`wave_service.dart`, hand-mirrored) and NOT
  against the 300 s function timeout: a callable cannot be cancelled, so past
  the client's deadline the admin has already been told the sync failed and
  will tap again.
  **A zero counter must never be reported as success.** The response carries
  `pushedPending` (a `count()` taken AFTER the drain), `pushedFailed`
  (`drained.dead` — dead-lettered jobs are not `queued`, so the pending count
  misses them and they never retry) and `pushIncomplete` (the drain or the
  count threw). Without all three, a broken push, a bounded push and an empty
  queue produce identical zeros, and the app says "everything was already up to
  date" while edits sit undelivered. Response fields are additive only.
  `drainQueue`'s `created`/`updated`
  counters come from `tallyUpsert`, folded from each `upsertCustomer` status
  and incremented only where `done` is (a committed outcome), so a superseded
  job can't be counted in two drains; `linked` counts as an **update**, since
  that path patches a customer a crashed attempt already created.
  the read-only `waveGetConnection` (admin + App Check; no secret, but
  durably rate-limited — `wave-connection`, 60/hour, added once it stopped
  being a single-document read: it also runs two `count()` aggregates on
  `waveSyncQueue` so Settings can show the outbox depth), `waveSetImportSchedule`
  (admin + App Check; no secret, but durably rate-limited like every other
  admin write callable — `wave-schedule`, 20/hour — writes the `importSchedule`
  field on `wave/connection`), `waveRetryFailedJobs` (admin + App Check + the
  `WAVE_FULL_ACCESS_TOKEN` secret + durable rate limit — `wave-retry`,
  10/hour — admin-only recovery for dead-lettered outbox jobs: `requeueDeadJobs`
  puts them back in the queue, then a best-effort drain pushes them so the
  admin sees the result of the press rather than waiting for the next client
  edit or the daily sweep. **The requeue runs its per-job transactions in
  `REQUEUE_CHUNK`-sized concurrent batches, not one at a time** — the shape
  that produces dead jobs is a bulk backfill, a few hundred of them, and a
  serial round trip each spent 12-20 s of the callable's budget before the
  drain behind it had run at all. The transactions touch distinct documents,
  so there is nothing to serialize for, and the per-job catch still keeps one
  stubborn job from aborting the recovery.
  **The response carries `failed` (`drained.dead`) beside `pushed`, and it is
  not optional** (2026-08-15): the very reason this action is manual — a job
  that died on a `WaveValidationError` dies again — means the drain behind the
  requeue routinely dead-letters it a SECOND time inside the same call, leaving
  the outbox's dead count exactly where it was. Reporting only `requeued` made
  the app announce "1 client queued for Wave again" as a success over a
  Settings row still reading "1 client failed to sync", which is the same
  silence `pushedFailed` was added to the sync response to end. Null-is-unknown
  like `pushed` — the drain threw, or never ran — and the app must never render
  that as "nothing failed"), the `waveUpsertCustomer`
  `clients` trigger, and the daily `runWaveDaily` — which is NOT its own
  export: `waveScheduledImport` was deleted 2026-08-13 and this now rides
  `sendDailyJobDigest` as an isolated rider (server-triggered, so no App
  Check/rate limit).
  **THE PUSH IS EVENT-DRIVEN, NOT POLLED** (2026-08-13, owner call). The
  `waveSyncWorker` scheduler — `every 5 minutes`, drain the `waveSyncQueue`
  outbox — is **DELETED**. `waveUpsertCustomer` now enqueues the job AND
  drains it in the same invocation, so an edit reaches Wave in seconds rather
  than up to five minutes, an idle day costs zero invocations instead of 288,
  and one of the six Cloud Scheduler jobs (only 3 are free per billing account)
  goes away. Two properties there are load-bearing and must not be
  "simplified": the drain is wrapped so it **cannot throw** — the job is
  already durably queued, so a failure is a delay, not a loss, and a throw
  would re-run the whole handler under `retry: true` for something a retry
  cannot fix — and it sits **below** the `shouldEnqueueClientWrite` gate, which
  is what stops `upsertCustomer`'s own `wave.*` write-back from re-entering the
  drain in a cycle (the hash is unchanged by that write, so the re-fire returns
  at the top).
  **`runWaveDaily` therefore drains BEFORE its due check, unconditionally.**
  That is the safety net for the two states an event-driven push structurally
  cannot catch: a job sitting on its `nextAttemptAt` backoff, and a job left
  `inflight` by a dead instance (reclaimed by `drainQueue`'s lease pass) —
  neither produces a client write to ride on. It must run even when
  `importSchedule` is `off`, which is the DEFAULT and governs the PULL only;
  gating the push on it would mean a default install never pushes
  automatically at all. It also re-establishes push-before-pull on the
  unattended path, and reads `skipClientIds` AFTER the drain. Pinned by
  `wave_callables.test.js` ("pushes without a poll" / "is the drain safety
  net"). Don't reintroduce a polling worker to "fix" a sync latency
  complaint — check the trigger's drain and the daily sweep first.
  `importCustomers` still only re-runs when the configured cadence is due.
  **`wave/connection` is READ through ONE owner: `readWaveConnection` /
  `connectionFieldsOf`** (`wave/sync_run.js`, 2026-09-07). The doc-get and the
  field coercion were spelled out at eight sites across the callables, the
  daily rider and `sync_run.js` itself, and `importSchedule` was coerced twice
  with only ONE copy applying the unknown-value fallback — so the same stored
  value read as `off` in one place and as itself in another.
  `readWaveConnection` returns the `ref` beside the coerced fields because most
  callers need it next (to update the cadence, or to hand `importWithWatermark`
  the document it advances); `connectionFieldsOf` is the same coercion over a
  snapshot already in hand, which is what the bootstrap transaction needs.
  `readWaveBusinessId` is now a projection of it, not a second read.
  **All five Wave callables open with `assertAdminCall`** (2026-09-07), like
  every other admin callable — the hand-spelled auth/`assertAdmin`/payload
  opening is gone. It changes the opening and not one allowlist key, so it
  breaks no build in the fleet; see `.claude/rules/security.md` for why the
  composed guard exists.
  **Auto-import cadence:** `importSchedule` on `wave/connection` is one of
  `off`/`weekly`/`monthly` (`WaveImportSchedule` enum client-side; `SCHEDULE_VALUES`
  server-side, with `SCHEDULE_SET` its membership form — owned beside it in
  `import_schedule.js`, because two `new Set(SCHEDULE_VALUES)` are two chances
  for the validator and the coercion to disagree). The `isImportDue` helper (`wave/import_schedule.js`, pure/jest-testable)
  treats **off or any unknown value as never-run**; a due import stamps
  `lastAutoImportAt` and a failed one leaves it unchanged (retried next day). The full-access
  Wave token lives in Secret Manager (`WAVE_FULL_ACCESS_TOKEN`) only — **no
  OAuth**. The Connect target is chosen **server-side**: `waveBootstrap` resolves
  the business from the `WAVE_BUSINESS_NAME` secret when the client sends no
  `businessId`/`businessName`, so the business name never ships in the app and
  `_connect()` passes no selector. (Business resolution is fully server-side via
  the internal `listBusinesses` helper — there is no `waveListBusinesses`
  callable; the in-app business picker was removed.) The app
  cannot read the rules-locked `wave` collection directly, so the Settings Wave
  section calls `waveGetConnection` on mount to show persistent "Connected to X"
  status — this is the **only** Wave read path; never read the collection
  client-side. **Import invariant:** `importCustomers`
  (`wave/customers_import.js`) MUST write
  `createdAt`/`updatedAt` on every client doc (new docs get both; re-runs backfill
  `createdAt` only when missing) — the clients list/search order by `createdAt`
  and Firestore **excludes any doc missing the orderBy field**, so a timestampless
  import is silently invisible in-app. **Outbox invariant:** the job claim AND the
  outcome write are both transactional — `commitOutcome` writes
  `done`/`queued`/`dead` only while the job is still `inflight` with the same
  `claimedAt`, so a client edit that re-enqueues mid-dispatch isn't clobbered.
  The reclaim pass enforces the same rule with a single read+write transaction
  (it has no Wave call to span), so neither path may ever do an unconditional
  `update`.
  **A `waveCustomerId` pointing at a customer that no longer exists in Wave
  must RELINK, never dead-letter** (2026-08-15, found in prod). Wave reports a
  missing `customerPatch` target as a top-level GraphQL error — so it arrives
  as `WaveApiError('graphql')`, which the retry taxonomy correctly calls
  non-retryable — or, equivalently, as a `NOT_FOUND` **inputError**. Both
  dead-lettered, and both were unrecoverable in a way ordinary dead-lettering
  is not: **the offending value is STORED on the doc**, so every later push and
  every "Retry failed" press re-sent the same missing id and failed
  identically. Two clients sat like that with the Settings row reading
  "2 clients failed to sync" and no way to clear it. `upsertCustomer` now
  routes both shapes (`isStaleCustomerLink` / `hasNotFoundInputError`,
  `wave/customers.js`) into the create path with the identity search FORCED on
  — the same route a crashed create takes, and the reason a spurious NOT_FOUND
  relinks rather than minting a duplicate customer. **`writeSyncSuccess` needed
  the matching exception**: it sets `waveCustomerId` only on a doc that is
  still unlinked, which is what keeps it idempotent, so the healed link would
  never have persisted. `replacesLink` is that exception and is conditioned on
  the stale id still being the one on the doc — a link established concurrently
  is newer and unproven-dead, so it wins. Keep the predicates narrow
  (a structured `NOT_FOUND`, never a text match on Wave's message): this is the
  one path here that REWRITES a client's Wave identity.
  **Import invariant: the customer's number lands in the app's ONE `phone`
  field** (2026-08-19). `importedPhone` (`wave/mappers.js`) resolves it the way
  the app does — Wave's `phone`, else Wave's `mobile`, else a number lifted out
  of the customer NAME — renders it "(514) 555-1234" when it is NANP, and
  always writes `mobile: ''`. Full reasoning, and why only the phone half of
  the name lift is taken, in `clients.md`.
  **Mapper invariant: NEVER send a value outside a Wave ENUM's vocabulary —
  omit the field instead** (2026-08-15). `provinceCode` and `countryCode` are
  GraphQL enums, so a value they don't know is NOT an `inputErrors` entry the
  worker can report against that one field: GraphQL refuses to coerce the whole
  `$input` variable and answers with a **top-level** error, which arrives as
  `WaveApiError(graphql)`, is non-retryable by design, and dead-letters the job.
  Nothing recovers it — "Retry failed" re-sends the identical payload into the
  identical refusal — so one stray address field costs that client every future
  sync, permanently and silently. `toProvinceCode`/`toCountryCode`
  (`wave/mappers.js`) therefore test MEMBERSHIP against `ISO_COUNTRY_CODES` and
  `SUBDIVISION_CODES` rather than shape: both doc blocks always claimed they
  "omit rather than guess", but `/^[A-Z]{2}$/` accepts any two letters, so a
  province typed into the country box ("ON", "QC") shipped as a country code.
  The province prefix follows the client's **resolved country** too — it was an
  unconditional `CA-`, so a New York client was sent as `CA-NY`, a subdivision
  of nowhere. Resolve country BEFORE province in `toWaveCustomerInput`; the
  province reads against it. Apply the same rule to any new enum-typed field.
  **And `sanitizeError` is not a diagnostic** — it flattens every transport
  failure to `WaveApiError(graphql)`, which is correct for the job's
  `lastError` and the client's `wave.syncError` (the app reads those), but it
  left the REASON recorded nowhere in the system. `describeWaveError`
  (`wave/retry_policy.js`) is the log-only companion the dead-letter
  `logger.error` carries as `errorDetail`: GraphQL `extensions.code`, the error
  `path` and the `at "input.address.countryCode"` field fragment, plus
  `Expected type`. It takes **only** the quoted run following `at` — the same
  message quotes the offending VALUE immediately before it, and that is
  customer data. Keep new detail extraction on that side of the line.
  **The customer contract owns "will Wave accept this client?"**
  (`wave/customer_contract.js`, 2026-08-30). `buildCustomerPayload` returns
  either a payload plus its hash, or structured `problems` — each naming the
  CLIENT DOC field an admin edits, never a Wave payload path, because the UI
  points at an input with it. Every rule traces to a dead-letter: a blank
  `name` (2026-08-30), a field past Wave's cap (latent — `firestore.rules`
  permits `name` at 225 and `address` at 533 where Wave caps at 200 and 500,
  and the push path capped NOTHING, since `capped()` is called only by
  `fromWaveCustomer`), an unusable email or phone.
  **Do NOT "fix" the length gap by lowering the rules caps.** The 225 exists
  because a cap below a stored value makes that doc permanently un-updatable
  with an opaque `permission-denied` — see the root `CLAUDE.md`. The contract
  refuses the doc and keeps it editable, which is the whole point.
  **A problem is `blocking` or `advisory`, and only `blocking` decides `ok`.**
  Two different questions were competing for one verdict: "Wave will refuse
  this" (never enqueue — the push would dead-letter permanently) and "Wave
  accepts this, but the data is wrong" (report it, surface it, push anyway).
  Collapsing them costs a real failure in each direction — treating every
  problem as blocking strands a client Wave is happy with, treating none as
  blocking puts the permanent dead-letter back. `problemsPatch` records BOTH,
  because an advisory does not stop the push but the admin must still see it,
  and the audit reports the two separately and deliberately does NOT gate on
  `ok`, or it would hide the very case that produced the split.
  **Write a contract rule from an OBSERVED rejection, never a plausible one.**
  The first production run is the evidence: 714 clients, 1 refusal — a client
  storing the literal string "a contact's name" in `phone`, which Wave had
  SYNCED with that string as the customer's phone number. The rule would have
  blocked a client Wave accepts, which is the one outcome the loose contact
  rules exist to avoid. It is now `NOT_DIALABLE`/advisory, deliberately not
  `INVALID_PHONE`: that name asserts something about Wave's opinion, and Wave's
  opinion is that it is fine. Every other rule traces to a real refusal; that
  one traced to a guess. The documented LENGTH caps stay — those are not
  guesses. The email rule stays too and is still unproven; treat it the same
  way if real data ever contradicts it.
  **The caps are READ from `IMPORT_FIELD_CAPS`, never restated.** `mappers.js`
  owns them and `test/core/validators/text_limits_test.dart` pins that map as
  TEXT against the `firestore.rules` caps; `PAYLOAD_CAPS` looks each one up by
  field name (`importCap`) and adds only the payload PATH and the two
  deliberate deviations — `provinceCode`/`countryCode` are GraphQL enums, so a
  length is meaningless, and `mobile` borrows `phone`'s cap because the IMPORT
  folds Wave's mobile into the one `phone` field while the PUSH sends both. A
  second hand-written list is exactly the contract-versus-reality drift this
  module exists to close, and it would drift silently. `importCap` THROWS at
  require time rather than returning undefined: `overLongProblems` compares
  `value.length <= rule.cap`, which is false for an undefined cap, so a field
  renamed in `mappers.js` would not leave one field unchecked — it would report
  EVERY client `TOO_LONG`, and in Phase 2 that is every client refused.
  **PHASE 2 ENFORCES IT** (2026-09-10; Phase 1 was report-only). `statePatch`
  replaces `problemsPatch` and writes `wave.problems` plus, when something
  BLOCKS, `wave.syncState: 'blocked'` — the fourth state, separate from
  `error` because the remedy differs: an `error` may retry, a `blocked` client
  never will until its data is edited. Every key it writes is DOTTED, and that
  is load-bearing (below). `wave.problems` is not a mapped field, so the hash
  is unchanged and `shouldEnqueueClientWrite` stops the re-fire — the same
  protection mark-pending relies on.
  **Three enforcement points, one implementation.** At ENQUEUE
  (`waveUpsertCustomer`) a refused client never becomes a job, and
  `cancelCustomerUpsert` removes one an EARLIER edit left queued — the worker
  re-reads the LIVE doc, so that job would push what was just refused. It
  deletes only while the job is still `queued`; an `inflight` job is claimed by
  a live dispatcher and deleting it would break `commitOutcome`'s claim
  invariant, so it is left for the second point. At DISPATCH `upsertCustomer`
  returns `{status: 'blocked'}` and writes the state rather than throwing
  `WaveValidationError`, because throwing is what dead-letters permanently. At
  IMPORT the same contract decides, so the pull cannot write a client the push
  could never send back.
  **The IMPORT must never clobber the verdict.** `importOneCustomer` wrote the
  whole `wave` sub-map as a nested object, and a nested map under `merge: true`
  REPLACES the stored one — so an import erased `wave.problems` and reset a
  blocked client to `synced`, silently re-arming the permanent dead-letter.
  The update branch writes DOTTED keys and re-runs the contract over the fields
  being written (the import has just put Wave's values on the doc, so stored
  problems describe the OLD one). The create branch may nest: there is no
  prior state to preserve.
  **"Retry failed" no longer lies.** `requeueDeadJobs` asks the contract about
  each dead job's client: a refused one is DELETED and the reason written onto
  the client, counted as `blocked` rather than `requeued`. Requeuing it would
  dead-letter it again inside the drain behind that same call, which is exactly
  why the press appeared to do nothing while reporting success. A MISSING
  client doc is requeued, never treated as refused — the dispatcher already
  treats one as a clean skip, and blocking would put a reason on a client that
  does not exist. `blocked` rides the callable response and the notice; it is
  additive and is NOT a failure.
  **`toWaveCustomerInput` stays EXPORTED, and a test is what holds the
  boundary.** The design proposed making it private to the contract; ~50
  `wave_mappers.test.js` cases drive it directly, including `null`/`undefined`
  inputs the contract refuses outright and which cannot be expressed through
  `buildCustomerPayload`, so re-pointing them would couple the mapping layer's
  tests to the contract's verdicts and delete coverage doing it.
  `__tests__/wave_contract_is_sole_producer.test.js` reads the source back
  instead — a new production call site outside `mappers.js` and
  `customer_contract.js` is a test failure. It also pins that the enqueue gate
  runs BEFORE the enqueue. Verified to fail on a planted violation, not just to
  pass.
  **Surfaces.** `WaveSyncBadge` renders `blocked` and the reasons as visible
  TEXT (they were a `Semantics` label only), `WaveProblemList` owns the
  sentences so the badge and the Settings list cannot word one failure two
  ways, and `WaveBlockedList` lists refused clients from
  `watchBlockedClients()` — a `clients` query on `wave.syncState`, admin-only
  by the existing read rule, needing the `wave.syncState` + `name` composite
  index. A refused client is absent from BOTH outbox counters, so that list is
  the only place it appears.
  **SHIP THE APP BUILD BEFORE DEPLOYING ENFORCEMENT**, which inverts the usual
  order. `_badgeConfig` renders nothing for a state it does not know, so the
  moment the backend writes `blocked` every shipped build shows those clients
  no badge at all — strictly less signal than the `error` they show today.
  Index first, then the app, then the backend.
  `functions/scripts/audit-wave-contract.js` replays the contract over
  production, read-only. Run it after any change to the contract, the mappers,
  or `ClientNamePolicy`. Design:
  `docs/plans/2026-08-30-wave-validated-contract-design.md`; Phases 2-4 plan:
  `docs/plans/2026-09-10-wave-validated-contract-phases-2-4.md`.
