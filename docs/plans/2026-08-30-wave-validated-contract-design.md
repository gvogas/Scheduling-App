# Wave sync: the validated contract

**State: PHASE 1 COMPLETE — BUILT, DEPLOYED AND CONFORMANCE-REPLAYED.
PHASE 2 IS NOW UNBLOCKED and is the next thing to write.** Owner-approved
through three review sections. Phase 1 is
`functions/wave/customer_contract.js`, recording `wave.problems` without
changing what enqueues; deployed 2026-08-30 (`fe9edc51`, report-only).

**The production replay RAN 2026-09-09** — the last open step of Phase 1, and
the input §7 step 2 was waiting on. `functions/scripts/audit-wave-contract.js
--verbose` against prod (`schedulingapp-88727`):

```
Scanned 724 clients.
0 would be REFUSED by Wave (blocking).
1 sync fine but carry advisory problems.
  advisory  phone:NOT_DIALABLE: 1
```

**The report is CLEAN: not one client on file would dead-letter.** 724 tracks
the 714 the address dry run saw on 2026-08-28 and the 720 the token backfills
saw on 2026-09-06, so the scan reached the whole collection. The single advisory
is the already-analyzed `2wcEiCNztsWYUYNXYBEm` — a person's NAME typed into the
`phone` box, which Wave has synced as that customer's phone number, and which is
advisory for exactly that reason (blocking it would strand a customer Wave
accepts). It is documented at the rule itself in `customer_contract.js`;
nothing about it is new and nothing needs fixing.

So §7's gate — *"enforce, once the report is clean and the contract has earned
trust against real data"* — is **met**. Phases 2-4 are still unwritten, which
is now a choice rather than a dependency. The implementation plan for Phase 1
is a separate document.

Rearchitects the Wave customer sync around a single module that owns *"what
Wave will accept"*. Motivated by two owner complaints — **it keeps breaking**
and **the code is unwieldy** — and by three production incidents that share one
root cause.

Current state of the code is `CLAUDE.md`, `.claude/rules/wave.md` and
`docs/CLOUD_FUNCTIONS.md`, never this document.

---

## 1. Why

### The three incidents were one incident

| Date | Trigger | Outcome |
|---|---|---|
| 2026-08-15 | `provinceCode: "CA-NY"` — a province prefixed with an unconditional `CA-` | Permanent dead-letter |
| 2026-08-15 | `waveCustomerId` pointing at a customer deleted in Wave | Permanent dead-letter |
| 2026-08-30 | `name: ""` — `composeStored`'s business branch blanked a business named only by its own phone | Permanent dead-letter |

Each is the same shape. **The app sends a value Wave refuses, discovers it only
at push time, and has no way back.** `WaveValidationError` is non-retryable by
design, so "Retry failed" re-sends the identical payload into the identical
refusal — the code comments in `wave/callables.js` say so explicitly.

The outbox itself — leases, transactional claims, backoff, reclaim — is the
genuinely hard part of this feature and **has never been what broke.**

### Wave is being used as the validator

That is the architectural inversion at the root of both complaints. It is why
it keeps breaking, and it is why the code is unwieldy: `.claude/rules/wave.md`
is 275 lines because the constraints live in prose rather than in something
that enforces them.

### A fourth incident is already latent

`capped()` (`wave/mappers.js`) is applied **only** on the import path
(`fromWaveCustomer`). **The push path caps nothing.** Two fields are permitted
by `firestore.rules` at a length Wave refuses:

| Field | `firestore.rules` | Wave (`IMPORT_FIELD_CAPS`) | Dead-letters at |
|---|---|---|---|
| `name` | 225 | 200 | 201–225 |
| `address` | 533 | 500 | 501–533 |

The app's own input fields are not the vector — `TextLimits.personName` caps
the name box at 200, and every other `TextLimits` value is at or below Wave's
cap. The vector is **legacy data**: docs written under the old
`"<typed name> <phone>"` shape, which is precisely why the rules cap is 225.
Any such doc dead-letters permanently on its next push with `TOO_LONG`, and
nothing in the system would say why.

### The failure is invisible

- Settings shows `wave_outboxFailed(count)` — a bare number. No client, no
  reason. The widget's own comment: *"The counter this acts on is the only
  trace a dead-lettered job leaves."*
- `WaveSyncBadge` renders a red "Sync error" chip. `wave.syncError` **is** on
  the doc, but the badge exposes it only as a `Semantics` label — screen-reader
  only. A sighted admin sees a colour and nothing else.
- `describeWaveError` returned `""` for `WaveValidationError` — the one class
  whose reason arrives structured. Fixed 2026-08-30; that fix is a prerequisite
  of this work, not part of it.

---

## 2. Scope

**In scope.** Customer sync reliability and maintainability.

**Out of scope, by owner decision.**

- **Invoicing.** `autoInvoice` and `billingTerms` are editable in the client
  edit sheet, round-trip to Firestore, and are consumed by nothing. They stay
  as they are. Not fixed, not removed, not wired up here.
- **The `p7b-wave-invoices` branch** (5,877 lines, unmerged since 2026-08-21 —
  a Wave invoice read path feeding dashboard revenue and AR aging). **Left
  alone; it may be dropped.** This design plans nothing around it and takes no
  dependency on it. It does touch `functions/wave/`, so if it is ever revived
  it rebases onto this work rather than the reverse.
- **Performance and cost.** Not a stated problem. No optimisation work.

### Established constraints

- **The sync is genuinely two-way.** Clients are created *and* edited in both
  the app and Wave. The pull half stays.
- **The pull is manual by choice.** `importSchedule` is `"off"` in production
  because the owner presses "Sync with Wave" when they want it. The
  weekly/monthly cadence apparatus is therefore dead weight and comes out.
- Live data: ~700 real customers on real invoices. Every step must be safe on
  its own.

---

## 3. Architecture

### 3.1 The contract

**New module: `functions/wave/customer_contract.js`.** It owns the single
question *"will Wave accept this client?"* and is the **only** thing that can
produce a Wave payload.

```
buildCustomerPayload(clientFields)
  → { ok: true,  payload, hash }
  → { ok: false, problems: [{ field, code, detail }] }
```

`toWaveCustomerInput` becomes private to this module. Nothing else can
construct a payload, so nothing can construct one that skipped validation.
That is the whole mechanism — it is enforced by module boundary, not by
discipline.

Every rule traces to a real incident or a live gap:

| Rule | Origin |
|---|---|
| `name` non-empty after composition | the 2026-08-30 blank-name dead-letter |
| every field within Wave's cap | the latent 201–225 `name` gap (§1) |
| enum fields omitted unless a vocabulary member | the 2026-08-15 `CA-NY` incident |
| `email` well-formed if present | `INVALID_EMAIL` |
| `phone` in a shape Wave accepts | `INVALID_PHONE` |

The existing `toProvinceCode`/`toCountryCode` membership tests and
`IMPORT_FIELD_CAPS` move in as contract rules rather than being rewritten —
they are already correct, they are just not applied on the push path.

### 3.2 Three enforcement points, one implementation

1. **At enqueue** (`waveUpsertCustomer` trigger). A client that cannot produce
   a valid payload **never becomes a queued job**. It becomes a `blocked` state
   on the client doc carrying structured reasons.
2. **At dispatch** (the worker). Last line of defence. If Wave rejects
   something the contract passed, that is by definition a **contract gap** —
   logged as "needs a new rule", not as a mystery.
3. **At import** (Wave → app). The same contract decides whether an incoming
   customer is representable, so the pull cannot write a client the push could
   never send back.

### 3.3 Deliberately not mirrored into Dart, and no caps are changed

This codebase has already paid for hand-mirrored twins:
`ClientNamePolicy` ↔ `client_name_utils.js` is the pair that produced the
2026-08-30 bug. A third twin is a third thing to drift. The trigger runs
within seconds of a save, so the admin sees the problem almost immediately
regardless.

**The rules caps stay where they are.** An earlier draft of this design
proposed lowering `clients.name` from 225 to 200 to match Wave. That would have
caused an incident: `CLAUDE.md` records why the 225 cap exists — docs written
under the old shape are still in the collection, and *a cap below a stored
value makes that doc permanently un-updatable with an opaque
`permission-denied`*. The same reasoning covers `address` at 533.

So over-length is the **contract's** job, not the rules': a legacy doc past
Wave's cap becomes `blocked` with `NAME_TOO_LONG` / `ADDRESS_TOO_LONG` and a
"shorten this" action, which the admin can satisfy because the input field
already caps at 200. The doc stays editable throughout. This makes the design
strictly smaller — no Dart mirror **and** no rules change.

### 3.4 `worker.js` splits four ways

968 lines, along the seam its own section comments already mark:

| Module | Contents | Treatment |
|---|---|---|
| `outbox_core.js` | claim, lease, `commitOutcome`, reclaim | **Kept as-is.** Never broke. Isolated so it stops being edited by accident. |
| `dispatch.js` | `dispatchJob`, `resolveOutcome`, `tallyUpsert` | Moved |
| `outbox_queries.js` | counts, `listOutstandingClientIds`, `requeueDeadJobs` | Moved |
| `enqueue.js` | `shouldEnqueueClientWrite`, `enqueueCustomerUpsert` | Moved |

### 3.5 Deletions

The scheduled-import cadence: `import_schedule.js` (`isImportDue`,
`SCHEDULE_VALUES`), `importSchedule`'s weekly/monthly values,
`lastAutoImportAt`, `waveSetImportSchedule`, the `runWaveDaily` import rider,
and the Settings cadence control.

`runWaveDaily`'s **drain** survives — it is the safety net for a job on backoff
or left `inflight` by a dead instance, neither of which produces a client write
to ride on. Only the *import* half of the daily run goes.

`waveSetImportSchedule` is a deployed callable. Removing it is a breaking
change for any shipped build that calls it — it follows the
`docs/DEPLOYMENT.md` §4a retirement rule: neutralised server-side first, key
left accepted-and-ignored, removed only once no build in the fleet still
calls it.

---

## 4. Failure model

### 4.1 A fourth state

| State | Meaning | Remedy | Queue |
|---|---|---|---|
| `synced` | matches Wave | — | — |
| `pending` | queued, not yet pushed | wait | occupies a slot |
| `blocked` | **new.** Contract refused; never became a job | edit the client | never queued, never retried, never dead-letters |
| `error` | Wave refused, or transport failed | retry, or investigate | may retry |

`blocked` is separate from `error` because the remedy differs and the admin
must be able to tell which they are looking at.

### 4.2 Reasons become structured data

`wave.problems: [{ field, code }]` on the client doc. Codes are an **app-owned
vocabulary** (`NAME_EMPTY`, `NAME_TOO_LONG`, `EMAIL_INVALID`,
`PROVINCE_UNKNOWN`, …) with EN/FR ARB strings — **never** Wave's raw message,
which is customer data. This is the same line `sanitizeInputErrors` already
holds. `field` is what lets the UI point at the offending input.

### 4.3 Three surfaces

1. **Client detail.** The badge stops being a mood ring: *"Can't sync to Wave —
   name is too long (218 / 200)"*, with a **Fix** action opening the edit sheet
   on that field. The reason becomes visible text, not a `Semantics` label.
2. **Settings → Wave.** The count becomes a **list** — client name, one-line
   reason, tap to open. A count gives you a number; a list gives you an action.
3. **Save time.** No new gate here — the app's input caps are already at or
   below Wave's (§3.3), so the sheet cannot originate an over-length value. A
   legacy doc that already carries one is caught at enqueue and shown on the
   two surfaces above.

### 4.4 Retry stops lying

Today "Retry failed" requeues everything, and the drain behind it dead-letters
validation failures again inside the same call, leaving the count unmoved.

**Only transient failures are retryable.** Validation problems never enter the
retry pile — they surface as `blocked` and fixable. This deletes the "press the
button, nothing changes" experience rather than documenting it.

### 4.5 Auto-heal

The stale-link relink (`isStaleCustomerLink` / `hasNotFoundInputError`) already
exists, works, and stays untouched.

Added: when an edit resolves a client's problems, `blocked` clears and
re-enqueues **automatically**. No button press.

### 4.6 A dead-letter becomes a signal

With the contract in front, a surviving `WaveValidationError` means Wave
refused something we believed valid — a contract gap. It logs loudly with
`errorDetail` plus the payload's field names, and that is the cue to add a
rule. Rare by construction, actionable when it happens.

---

## 5. The import half

### 5.1 The clobber invariant becomes structural

Today the import is protected by `skipClientIds`, a protect-list computed once
before the run and passed by every caller **as a convention**. `wave.md` admits
the race: a job backed off after a transient error, or enqueued mid-import, is
not in that list and is still live. The consequence is the worst in the
feature — the import overwrites the mapped fields *and* stamps
`wave.lastSyncedHash`, so a queued edit is not merely overwritten but marked
*synced*; the pending job then hashes the clobbered doc, matches, returns
`noop`, and the edit is gone with the row reading "synced" and nothing logged.

**Replace it with a per-write transactional precondition.** The job id is
deterministic (`customerUpsert__<clientId>`), so it is a single known ref: the
import's write of a client doc and the check "does this client have an
outstanding job" go in **one transaction**. If a job exists, the write is
skipped and counted.

This is strictly safer than the pre-computed list, costs one extra read on a
write the import was already making per document, closes the race the current
design documents but cannot prevent, and — the point — **a new caller cannot
forget it**, because it lives inside the writer rather than at the call site.

Note this adds a client transaction. The `CLAUDE.md` prohibition is on
*routine/concurrent* client `runTransaction` (the iOS plugin crash); this is
server-side `firebase-admin`, which is unaffected.

### 5.2 What stays

`importWithWatermark` stays — the delta is what makes the manual press fast —
and simplifies, since removing the cadence leaves it one caller instead of two.
The 7-day full-pass backstop stays.

---

## 6. Testing

The existing ~7,100 lines of Wave tests encode the scar tissue. **They move
with their modules; they are not rewritten.**

Added:

- **A table-driven contract suite** where every historical incident is a named
  case: `CA-NY`, blank name, 218-character name, stale link. A regression
  cannot return anonymously.
- **A conformance script** replaying the contract against a sample of real
  production clients, reporting what would be refused. This is how incident #4
  is found before customers find it — it would have caught both the
  2026-08-30 blank name and the 201–225 gap on day one. Read-only,
  `--dry-run`-shaped, in the `functions/scripts/` house style (`_flags.js`
  guard, `_project.js` target banner).

---

## 7. Migration — no flag day

Four steps, each independently safe and independently shippable.

1. **Report-only.** Ship the contract computing and recording `wave.problems`,
   but **not** blocking enqueue. Behaviour unchanged. Run across all ~700
   clients for several days and read what it flags.
2. **Enforce**, once the report is clean and the contract has earned trust
   against real data.
3. **Backfill.** Run the contract over every client, so existing broken ones
   surface as `blocked` with reasons instead of sitting in a counter.
4. **Refactors last** — the `worker.js` split and the cadence removal are pure
   moves with tests unchanged, landing on code already behaving.

**Step 1 is the risk control that matters:** we learn what the contract would
reject before it is able to reject anything.

### Mechanical notes

- The Settings failures list needs **no new callable**. Problems live on the
  client doc, so it is a `clients` query on `wave.syncState` — which needs a
  composite index, and the read must satisfy a `firestore.rules` clause via its
  WHERE constraints.
- `docs/DEPLOYMENT.md` ordering applies throughout: **backend before the app
  build**, because `assertPayloadShape` rejects unknown keys.
- `.claude/rules/wave.md` shrinks as rules become enforcing code. It is updated
  in the same commit as each change, never after.

---

## 8. What success looks like

- A client that cannot sync says **which field and why**, on the client and in
  Settings, without reading a log.
- "Retry failed" either fixes something or is not offered.
- A new field added to the client model cannot reach Wave unvalidated.
- `.claude/rules/wave.md` is materially shorter, because its rules are executable.
- The next incident is caught by the conformance script pre-deploy, not by a
  customer's missing invoice.
