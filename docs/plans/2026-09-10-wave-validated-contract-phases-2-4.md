# Wave validated contract — Phases 2-4 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status (2026-09-13): PHASE 2 COMPLETE — shipped in 1.61.0+90 and deployed
2026-09-13 02:07Z (`38c8225b`), in the inverted order below. Phase 3 COMPLETE
(its own plan, archived at `docs/archive/2026-09-11-wave-validated-contract-phase-3.md`). Phase 4
BUILT 2026-09-13 and NOT deployed — Tasks 10-12 below, with the deploy notes
under Task 12.** The "nothing deployed" paragraph below is the
build-time state. Phase 1 was complete, deployed (`fe9edc51`, report-only) and
prod-replayed 2026-09-09 (**724 clients, 0 blocking, 1 advisory**). Design:
`docs/plans/2026-08-30-wave-validated-contract-design.md` §3-§7. Phase 1 plan:
`docs/archive/2026-08-30-wave-validated-contract-implementation.md`.

**Verified at build time:** analyzer clean, **1872 jest** (from 1848), eslint
clean, **139 Dart Wave tests** (from 115). Nothing here has been deployed and
the app build has not shipped — read the deploy-ordering section below before
either, because this phase INVERTS the usual backend-first rule.

### Deviation from this plan, and why

**Task 6.5 was not done as written.** The plan (and design §3.1) said to make
`toWaveCustomerInput` private to the contract, and to re-point
`wave_mappers.test.js` at `buildCustomerPayload().payload`. That suite drives
it ~50 times, including `toWaveCustomerInput(null)` and `(undefined)` — inputs
the contract refuses outright, so they cannot be expressed through
`buildCustomerPayload` at all. Re-pointing would have coupled the mapping
layer's unit tests to the contract's verdicts and deleted coverage doing it.

The boundary is enforced by `__tests__/wave_contract_is_sole_producer.test.js`
instead, which reads the source back — a production call site outside
`mappers.js` and `customer_contract.js` fails the suite, as does an enqueue
that does not consult the contract first. It was verified to FAIL on a planted
violation before being accepted, because a guard that passes vacuously is worse
than none.

### Findings fixed beyond the plan

- **The import erased the verdict** (finding #1 below) — fixed with dotted
  `wave.*` keys plus a contract re-run over the merged fields.
- **The trigger's batch-commit fallback dropped it** (finding #2) — fixed.
- **`listOutstandingClientIds` doc drift** (finding #3) — corrected in
  `.claude/rules/wave.md`.
- **`requeueDeadJobs` had no way to report a dropped job**, so a press that
  cleared the queue of refusals would still have said "nothing to retry". Added
  a `blocked` counter through the callable response, `WaveRetryResult` and
  `waveRetryNotice`, under the repo's own rule that a zero counter must never
  be reported as success.
- **`drainQueue`'s summary gained `blocked`** for the same reason.

**Goal:** Turn the contract from a recorder into the boundary — the only
producer of a Wave payload, able to refuse a client before it becomes a queued
job, with the refusal visible and fixable in the app instead of buried in a
counter.

**Tech Stack:** Node 20 CommonJS, `firebase-admin`, `firebase-functions` v2,
Jest (ESLint `google`: 80 columns, double quotes, 2-space indent, JSDoc on
every function). Flutter/Dart with Riverpod 3 + freezed for the app half.

---

## Task 0: What enforcement actually buys — settle this BEFORE writing code

The replay came back with **zero blocking problems across 724 clients**. That
is the number this phase has to be honest about, because it reads two ways and
only one of them is true.

**It is not evidence the contract is toothless.** Every founding incident was
*fixed or repaired* before the replay ran — the `CA-NY` province at the mapper,
the stale link by the relink path, the blank name in prod by hand. A clean
report is exactly what a repaired backlog looks like.

**But it is also not a backlog waiting to be cleaned.** There is nothing to
clean. So enforcement's entire value is **prospective**, and the plan must be
sized to that rather than to a rescue.

### What the contract would have caught, honestly

| Incident | Caught by the contract? | Why |
|---|---|---|
| 2026-08-30 blank `name` | **Yes** — `EMPTY`, blocking | A shape the app can produce and Wave refuses |
| Latent 201-225 `name` / 501-533 `address` | **Yes** — `TOO_LONG`, blocking | Same class; still latent, still reachable from legacy data |
| 2026-08-15 `CA-NY` province | **No** | Fixed at the mapper — `toProvinceCode` omits a non-member, so the payload the contract sees is already valid |
| 2026-08-15 stale `waveCustomerId` | **No** | The contract is pure; it cannot know Wave's state. Owned by `isStaleCustomerLink` |

**Two of four.** Both are *shape* failures. The contract is a shape guard, and
this plan does not pretend otherwise.

### What it will still miss

State-dependent refusals (a customer archived or deleted in Wave, a business
mismatch), a real `INVALID_PHONE` (deliberately advisory — see the
`NOT_DIALABLE` rationale in `customer_contract.js`), any new enum-typed payload
field added without a membership test, and everything transport.

### The consequence for ordering — and it changes this phase

`wave.problems` is **already being recorded on every client write** and is
visible **nowhere**. One real client carries an advisory today
(`2wcEiCNztsWYUYNXYBEm`, `phone:NOT_DIALABLE`) and no admin can see it.

So the surfaces are worth more, sooner, than the enqueue block — and they do
not depend on it. This plan therefore does the **visibility half first**
(Phase 2A, Tasks 1-4) and the **refusal half second** (Phase 2B, Tasks 5-8),
rather than the design's implied order. Each half is independently shippable.

- [x] **Step 0.1:** Read this task and confirm the framing still holds against
      the current `wave.problems` data. **Done 2026-09-10 against the RECORDED
      2026-09-09 replay (one day old), not a fresh run** — the audit needs
      production credentials this box does not have. Re-run
      `node functions/scripts/audit-wave-contract.js --verbose` before
      DEPLOYING enforcement; a blocking problem that appeared since then is a
      client that stops syncing the moment this ships, and the sizing above
      changes with it.

---

## Findings that must be fixed before enforcement is sound

Three defects found while mapping the code. **The first makes enforcement
unsound**, so it is Task 2, not a footnote.

1. **The import erases `wave.problems` and un-blocks a blocked client.**
   `customers_import.js:65-70` writes the `wave` sub-map **wholesale**:
   ```js
   wave: {syncState: "synced", syncError: null, lastSyncedHash: hash,
     lastSyncedAt: now()},
   ```
   A blocked client that Wave touches comes back reading `synced`, with its
   problems gone and nothing logged — the same silent-clobber shape
   `skipClientIds` exists to prevent, on a different field.

2. **The trigger's fallback path drops the problems patch.**
   `triggers.js:157` re-enqueues after a failed batch commit with
   `enqueueCustomerUpsert(clientId, {payloadHash: hash})` and no
   `problemsPatch`. Rare, but it is the path where the doc changed and the
   record of what is wrong with it does not.

3. **Doc drift:** `listOutstandingClientIds` (`worker.js:779`) queries
   `status in ["queued", "inflight", "dead"]`, but `.claude/rules/wave.md`
   describes it as "`queued` AND `inflight`". Fix the prose in Task 8.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `functions/wave/customer_contract.js` | Gains `blockingProblems`, `statePatch`. | Modify |
| `functions/wave/customers_import.js` | Must not clobber `problems`/`blocked`. | Modify |
| `functions/wave/customers.js` | `upsertCustomer` builds through the contract. | Modify |
| `functions/wave/triggers.js` | Blocks at enqueue; fallback keeps the patch. | Modify |
| `functions/wave/worker.js` | `cancelCustomerUpsert`; requeue skips blocked. | Modify |
| `functions/scripts/backfill-wave-blocked.js` | Phase 3 backfill. | **Create** |
| `lib/features/wave/domain/models/wave_problem.dart` | `WaveProblem` + code vocabulary. | **Create** |
| `lib/features/clients/domain/models/client_record.dart` | Parse `wave.problems`. | Modify (freezed regen) |
| `lib/features/wave/widgets/wave_sync_badge.dart` | `blocked` state + reason text. | Modify |
| `lib/features/wave/widgets/wave_blocked_list.dart` | Settings failures list. | **Create** |
| `lib/features/clients/data/firebase_clients_repository.dart` | `watchBlockedClients`. | Modify |
| `lib/l10n/app_en.arb` / `app_fr.arb` | Problem-code strings. | Modify |
| `firestore.indexes.json` | `wave.syncState` + `name` composite. | Modify |

---

## Deploy ordering — READ THIS BEFORE SHIPPING ANY OF IT

The usual rule is backend-before-app (`docs/DEPLOYMENT.md`), because
`assertPayloadShape` rejects unknown keys. **This phase inverts it**, and the
reason is specific:

`WaveSyncBadge._badgeConfig` (`wave_sync_badge.dart:97`) renders
`SizedBox.shrink()` for any state it does not know. The moment the backend
starts writing `blocked`, every shipped build shows those clients **no badge at
all** — strictly less signal than today, where the same client eventually
dead-letters and reads "Sync error".

Correct order:

1. **Deploy the composite index** (`firestore:indexes`) and wait for READY.
   Additive; nothing reads it yet.
2. **Ship the app build** that renders `blocked` and the problem list. Inert
   until the backend writes one, so it is safe to ship early.
3. **Deploy the backend** enforcement (Tasks 2-4).
4. **Run the Phase 3 backfill.**

No new callable and no new payload key, so no `assertPayloadShape` allowlist
changes and no `#compat-` carve-out in this phase. Phase 4's
`waveSetImportSchedule` removal is the one that needs the §4a treatment, and it
gets its own deploy.

---

# PHASE 2A — Make the problems visible

## Task 1: `WaveProblem` in Dart

**Files:**
- Create: `lib/features/wave/domain/models/wave_problem.dart`
- Create: `test/features/wave/wave_problem_test.dart`

The `wave.problems` array is a **server-owned vocabulary**, and the badge's
existing `_reportedUnknownStates` comment records the lesson: a value added
backend-side must not ship as a blank space. Parse defensively and keep an
unknown code renderable.

- [x] **Step 1.1: Write the failing test.** `test/features/wave/wave_problem_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/wave/domain/models/wave_problem.dart';

void main() {
  group('WaveProblem.fromMap', () {
    test('parses a blocking problem with detail', () {
      final p = WaveProblem.fromMap(<String, dynamic>{
        'field': 'name',
        'code': 'TOO_LONG',
        'severity': 'blocking',
        'detail': <String, dynamic>{'length': 218, 'cap': 200},
      });
      expect(p, isNotNull);
      expect(p!.field, 'name');
      expect(p.code, WaveProblemCode.tooLong);
      expect(p.isBlocking, isTrue);
      expect(p.length, 218);
      expect(p.cap, 200);
    });

    test('an unknown code parses as unknown rather than dropping', () {
      final p = WaveProblem.fromMap(<String, dynamic>{
        'field': 'phone',
        'code': 'SOMETHING_NEW',
        'severity': 'blocking',
        'detail': null,
      });
      expect(p!.code, WaveProblemCode.unknown);
      expect(p.isBlocking, isTrue);
    });

    test('an unknown severity is NOT treated as blocking', () {
      final p = WaveProblem.fromMap(<String, dynamic>{
        'field': 'phone', 'code': 'NOT_DIALABLE', 'severity': 'weird',
      });
      expect(p!.isBlocking, isFalse);
    });

    test('returns null for a non-map entry', () {
      expect(WaveProblem.fromMap('nope'), isNull);
    });

    test('parseList tolerates a null field and drops junk entries', () {
      final list = WaveProblem.parseList(<dynamic>[
        <String, dynamic>{'field': 'name', 'code': 'EMPTY',
          'severity': 'blocking'},
        'junk',
      ]);
      expect(list, hasLength(1));
      expect(list.first.code, WaveProblemCode.empty);
    });
  });
}
```

- [x] **Step 1.2: Run it — expect a missing-file failure.**
      `flutter test test/features/wave/wave_problem_test.dart`

- [x] **Step 1.3: Implement.** A plain immutable class (not freezed — it is
      parse-only and has no `copyWith` need), with:
  - `enum WaveProblemCode { empty, tooLong, invalidEmail, notDialable, unknown }`
    and a `fromRaw` mapping the four server codes; anything else → `unknown`.
  - `WaveProblem({required String field, required WaveProblemCode code, required bool isBlocking, int? length, int? cap})`.
  - `static WaveProblem? fromMap(Object? raw)` — cast loosely
    (`(raw as Map?)?.cast<String, dynamic>()`, per the root `CLAUDE.md`
    convention), `isBlocking` is `severity == 'blocking'` **exactly** (an
    unknown severity is not blocking; the server decides, and guessing
    upward strands a client Wave accepts).
  - `static List<WaveProblem> parseList(Object? raw)` — tolerates null, drops
    unparseable entries.

- [x] **Step 1.4: Run the test — expect green.**

## Task 2: Carry `wave.problems` onto `ClientRecord`

**Files:**
- Modify: `lib/features/clients/domain/models/client_record.dart`
- Modify: `test/features/clients/...` (the existing `ClientRecord` suite)

`ClientRecord` is freezed. It flattens the `wave` sub-map into
`waveCustomerId` / `waveSyncState` / `waveSyncError` (`:69-71`, parsed at
`:115-117`). Follow that shape rather than introducing a nested model.

- [x] **Step 2.1:** Add a failing test to the existing `ClientRecord` suite:
      a doc whose `wave.problems` is a two-entry array parses to two
      `WaveProblem`s, and a doc with no `wave` key parses to `const []`.
- [x] **Step 2.2:** Add `@Default(<WaveProblem>[]) List<WaveProblem> waveProblems`
      beside `waveSyncState`, and parse it in `fromMap` with
      `waveProblems: WaveProblem.parseList(wave?['problems'])`.
- [x] **Step 2.3:** `dart run build_runner build --delete-conflicting-outputs`
      to regenerate `client_record.freezed.dart`.
- [x] **Step 2.4:** Confirm `toMap()` does **not** emit it. The whole `wave`
      map is server-only (`firestore.rules:592, 600` reject any client write
      touching `wave`), so emitting it would make every save fail
      `permission-denied`.
- [x] **Step 2.5:** `flutter test test/features/clients/` — green.

## Task 3: The badge stops being a mood ring

**Files:**
- Modify: `lib/features/wave/widgets/wave_sync_badge.dart`
- Modify: `test/features/wave/wave_sync_badge_test.dart` (6 tests today)
- Modify: `lib/features/clients/widgets/views/client_view_body.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`

Today the badge is icon + label, and `syncError` reaches the user **only**
through a `Semantics` label — screen-reader only (`:33-35`). The design's §4.3
calls that out as the defect.

- [x] **Step 3.1: ARB keys**, both files in lockstep, `@key` block in EN
      (`required-resource-attributes: true` fails the build otherwise). Bucket
      is `wave_` (all-lowercase prefix):

  | key | EN |
  |---|---|
  | `wave_syncBlocked` | `Can't sync to Wave` |
  | `wave_problemNameEmpty` | `The client needs a name` |
  | `wave_problemTooLong` | `{field} is too long ({length} / {cap})` |
  | `wave_problemInvalidEmail` | `The email address isn't valid` |
  | `wave_problemNotDialable` | `The phone number has no digits to dial` |
  | `wave_problemUnknown` | `This client has a problem Wave won't accept` |
  | `wave_blockedFixAction` | `Fix` |

  `wave_problemTooLong` takes typed placeholders (`field` String, `length` int,
  `cap` int). The `field` value is the **localized field label**, not the raw
  server field name — reuse the existing client-form labels
  (`clients_fieldName` etc.) so the sentence reads in French too.

- [x] **Step 3.2: Write the failing widget tests.** Extend
      `wave_sync_badge_test.dart`:
  - `blocked` renders the `wave_syncBlocked` label and error tone.
  - a `TOO_LONG` problem renders `Name is too long (218 / 200)` as **visible
    text**, not only in `Semantics`.
  - an advisory-only problem on a `synced` client still renders its reason
    (this is the `2wcEiCNztsWYUYNXYBEm` case — Wave took it, the data is still
    wrong).
  - an unknown code renders `wave_problemUnknown` rather than nothing.
  - overflow: pump at 260 logical px with `TextScaler.linear(2)` per the root
    `CLAUDE.md` testing rule, using a local `_harness` helper.

- [x] **Step 3.3: Implement.** `WaveSyncBadge` gains
      `List<WaveProblem> problems` (default `const []`) and a `'blocked'`
      case in `_badgeConfig` using `scheme.errorContainer`. Below the chip,
      render one line per problem. Keep the unknown-`syncState` warn path
      exactly as it is.

- [x] **Step 3.4:** Update the one call site,
      `client_view_body.dart:72-81`, to pass `problems: client.waveProblems`
      and to render when `waveSyncState.isNotEmpty` **or** `waveProblems`
      is non-empty.

- [x] **Step 3.5:** `flutter gen-l10n`, then
      `flutter test test/features/wave/ test/features/clients/`.

> **Scope note — the "Fix" action.** Design §4.3 wants the badge to open the
> edit sheet focused on the offending field. The edit sheet does not take a
> focus target today, so that is a sheet-API change. **Deferred out of this
> task**; the badge names the field in its sentence, which is what makes the
> problem actionable. Revisit once the list in Task 4 is in use.

## Task 4: Settings shows a list, not a number

**Files:**
- Modify: `firestore.indexes.json`
- Modify: `lib/features/clients/data/firebase_clients_repository.dart`
- Create: `lib/features/wave/widgets/wave_blocked_list.dart`
- Modify: `lib/features/wave/widgets/wave_settings_section.dart`
- Modify: `test/features/wave/wave_settings_section_test.dart` (22 tests today)

`wave_outboxFailed(count)` is a bare number whose own comment admits it is
"the only trace a dead-lettered job leaves". Replace it with the clients
themselves.

- [x] **Step 4.1: The index.** Add to `firestore.indexes.json`:
      collection `clients`, fields `wave.syncState` ASC + `name` ASC,
      `COLLECTION` scope. Needed because the query orders by `name`; a bare
      equality would ride the automatic single-field index.
      **Deploy it and wait for READY before the app build ships.**
      Never `--force` (it deletes prod TTL policies — root `CLAUDE.md`).

- [x] **Step 4.2: The query.** Add `watchBlockedClients()` to
      `FirebaseClientsRepository`:
      `where('wave.syncState', isEqualTo: 'blocked').orderBy('name').limit(50)`.
      `/clients` is `allow read: if isAdmin()` unconditionally
      (`firestore.rules:583`), so the WHERE constraint needs no rules clause —
      unlike the `users` collection. Log stream errors through
      `onError: (e, st) => logger.warn('WAVE-BLOCKED', e, st)` (a raw
      `Stream.listen` without `onError` becomes an app-level fatal —
      `.claude/rules/error-handling.md`).
      **Add `WAVE-BLOCKED` to the log-only tag registry** in that rules file.

- [x] **Step 4.3: Write the failing tests** in
      `wave_settings_section_test.dart`: the list renders one row per blocked
      client with its name and first problem sentence; tapping a row navigates
      to the client; an empty result renders nothing at all (not an empty
      state — the row is omitted at zero, matching `_OutboxRow`'s existing
      null/zero rule).

- [x] **Step 4.4: Implement** `WaveBlockedList` as a `ConsumerWidget` over an
      `autoDispose` `StreamProvider`, inserted under the existing
      `_OutboxRow` block in `_ConnectedStatus` (`wave_settings_section.dart:346-372`).
      Keep the `wave_outboxFailed` row: it counts **dead outbox jobs**, which
      after Task 6 are transient-only failures — a different thing from
      `blocked`, and both need to be visible.

- [x] **Step 4.5:** `flutter analyze` + `flutter test test/features/wave/`.

**Ship gate for 2A:** analyzer clean, full `flutter test` green, index READY.
This half writes nothing new server-side and changes no backend behaviour.

---

# PHASE 2B — Enforce

## Task 5: Stop the import clobbering problems and `blocked`

**Files:**
- Modify: `functions/wave/customers_import.js`
- Modify: `functions/__tests__/wave_customers_import_units.test.js`

**This is a prerequisite, not a cleanup.** With enforcement on, an import that
resets a blocked client to `synced` silently re-arms the exact permanent
dead-letter this project exists to end.

- [x] **Step 5.1: Write the failing test.** In
      `wave_customers_import_units.test.js`, drive `importOneCustomer` against
      an existing client whose stored `wave` is
      `{syncState: 'blocked', problems: [{field: 'name', code: 'EMPTY', severity: 'blocking', detail: null}]}`
      and assert the staged `batch.set` merge **preserves both** — it must not
      write `syncState: 'synced'` over a blocked client, and must not drop
      `problems`.

- [x] **Step 5.2: Run it — expect failure** (today the sub-map is written
      wholesale at `:65-70`).

- [x] **Step 5.3: Implement.** Two decisions, and the second is the subtle one:
  - Write the `wave` sub-map with **dotted keys**
    (`"wave.syncState"`, `"wave.lastSyncedHash"`, …) rather than a nested
    object, so a `merge: true` set leaves sibling keys alone. A nested object
    under `merge: true` still replaces the whole map.
  - **A blocked client must not be marked `synced` by the import.** But the
    import has just written Wave's own values over the doc, so the client-doc
    fields have changed and the stored problems may no longer describe it.
    Re-run the contract on the merged field set and write the resulting state:
    `problemsPatch(mergedFields)` plus `blocked`/`synced` from
    `blockingProblems(...)`. That keeps one owner for the verdict and cannot
    leave a stale `blocked`.
  - The `create` branch (`:114`) may write the sub-map wholesale — there is no
    prior state to preserve — but must still run the contract for the same
    reason.

- [x] **Step 5.4:** `cd functions && npx jest __tests__/wave_customers_import_units.test.js`

## Task 6: The contract becomes the only payload producer

**Files:**
- Modify: `functions/wave/customer_contract.js`
- Modify: `functions/wave/customers.js`
- Modify: `functions/wave/mappers.js`
- Modify: `functions/__tests__/wave_customer_contract.test.js`, `wave_customers.test.js`

Design §3.1: `toWaveCustomerInput` becomes private to the contract, so nothing
can build a payload that skipped validation. It is still public on
`mappers.js:482` and still called directly by `customers.js:263`.

- [x] **Step 6.1: Extend the contract's API.** Add and export:
  - `blockingProblems(problems)` → the blocking subset. One owner for the
    `severity === "blocking"` test, which `buildCustomerPayload` already spells
    inline at `:242` and three new call sites would otherwise re-spell.
  - `statePatch(clientFields)` → `{"wave.syncState", "wave.syncError", "wave.problems"}`,
    superseding `problemsPatch` as the single write shape. Keep
    `problemsPatch` as a thin wrapper **only if** something still needs
    problems without a state change; delete it otherwise (no dead code —
    `.claude/rules/code-quality.md`).

- [x] **Step 6.2: Write the failing test** in `wave_customers.test.js`:
      `upsertCustomer` on a client with a blank name resolves
      `{status: 'blocked', problems: [...]}` and **makes no GraphQL call**.

- [x] **Step 6.3: Implement in `customers.js`.** Replace
      `const mappedFields = toWaveCustomerInput(data)` (`:263`) with
      `buildCustomerPayload(data)`. On `ok: false`: write the blocked state
      onto the client doc and return a `blocked` status — **do not throw
      `WaveValidationError`**, which is what dead-letters the job.

- [x] **Step 6.4: `resolveOutcome` must treat `blocked` as terminal-but-not-dead.**
      In `worker.js:512`, a `blocked` outcome deletes the job and does **not**
      increment the dead counter. A blocked client is not a failed job; the
      Settings failure count must not include it, or Task 4's list and that
      counter double-count the same client.

- [x] **Step 6.5: Make `toWaveCustomerInput` private.** Drop it from
      `mappers.js`'s exports once `customers.js` no longer imports it. The
      contract's own tests and `mappers.js`-internal callers keep working;
      `wave_mappers.test.js` (89 tests) exercises it directly, so re-point
      those to `buildCustomerPayload().payload` or export it under a
      `@private`-documented test-only name. **Prefer re-pointing** — a
      test-only export is a hole in the module boundary this task exists to
      close.

- [x] **Step 6.6: A surviving `WaveValidationError` is now a contract gap.**
      Per design §4.6, its dead-letter log gains the payload's **field names**
      (never values — `describeWaveError`'s existing PII line) and says
      "contract gap: add a rule".

- [x] **Step 6.7:** `cd functions && npx jest` — all suites.

## Task 7: Block at enqueue, and cancel the job that is already there

**Files:**
- Modify: `functions/wave/triggers.js`
- Modify: `functions/wave/worker.js`
- Modify: `functions/__tests__/wave_triggers.test.js`, `wave_worker.test.js`

Design §3.2 point 1: a client that cannot produce a valid payload never becomes
a queued job.

**The design misses a case.** A client can be `pending` with a job already
queued and *then* be edited into a blocking state. The worker re-reads the live
doc, so that job would push the now-invalid document. Task 6 stops it
dead-lettering, but the job must not sit there either.

- [x] **Step 7.1: Write the failing tests** in `wave_triggers.test.js` (8 tests
      today, `jest.mock("../wave/worker")` at `:12` — extend that mock):
  - a client with a blocking problem writes
    `wave.syncState: 'blocked'` + `wave.problems` and calls **neither**
    `enqueueCustomerUpsert` nor `drainQueue`.
  - a client with only an advisory problem still enqueues and still records
    the problem (this is the severity split doing its job).
  - a client edited **out of** a blocking state re-enqueues and returns to
    `pending` — the §4.5 auto-heal, with no button press.
  - a client edited **into** a blocking state while a job is queued calls
    `cancelCustomerUpsert`.

- [x] **Step 7.2: Implement `cancelCustomerUpsert(clientId, deps)`** in
      `worker.js`, beside `enqueueCustomerUpsert` (`:244`). The job id is
      deterministic (`customerUpsert__<clientId>`), so it is a single known
      ref. **It must run in a transaction and delete only while the job is
      still `queued`** — an `inflight` job is claimed by a live dispatcher and
      deleting it out from under `commitOutcome` breaks the claim invariant
      (`.claude/rules/wave.md`: neither path may ever do an unconditional
      update). An `inflight` job is left alone; Task 6's dispatch-side check
      catches it a moment later.

- [x] **Step 7.3: Implement the trigger gate** in `triggers.js`, **after** the
      `shouldEnqueueClientWrite` gate at `:115` and before the batch at `:139`.
      Blocking → write `statePatch(after)` alone, cancel any queued job,
      return. Not blocking → today's path with `statePatch` replacing
      `problemsPatch`.

- [x] **Step 7.4: Fix the fallback path** (`:157`) so the re-enqueue after a
      failed batch commit still carries the state patch. Finding #2 above.

- [x] **Step 7.5:** Verify the no-loop property still holds: `wave.*` writes do
      not change `mappedFieldsHash`, so `shouldEnqueueClientWrite` returns
      false on the re-fire. Assert it in a test rather than reasoning about it.

- [x] **Step 7.6:** `cd functions && npx jest`.

## Task 8: Retry stops lying, and the docs stop drifting

**Files:**
- Modify: `functions/wave/worker.js` (`requeueDeadJobs` `:725`)
- Modify: `functions/__tests__/wave_worker.test.js`
- Modify: `.claude/rules/wave.md`, `docs/CLOUD_FUNCTIONS.md`

Design §4.4. Today "Retry failed" requeues everything and the drain behind it
dead-letters the validation failures again inside the same call, leaving the
count unmoved.

- [x] **Step 8.1: Write the failing test.** `requeueDeadJobs` over a dead job
      whose client is now blocking **deletes the job and marks the client
      blocked** instead of requeuing it, and does not count it as `requeued`.
      That is what makes the number move.
- [x] **Step 8.2: Implement**, keeping the existing `REQUEUE_CHUNK`
      concurrency and the per-job catch.
- [x] **Step 8.3: Rules-file updates** — `.claude/rules/wave.md` gains the
      `blocked` state, the enqueue gate, the cancel rule, the import
      preservation rule, and the ordering inversion. **Correct the
      `listOutstandingClientIds` description to `queued`, `inflight` AND
      `dead`** (finding #3). Per §7 these land in the same commit as the code,
      never after.
- [x] **Step 8.4:** `cd functions && npm run lint && npx jest`.

---

# PHASE 3 — Backfill

## Task 9: Surface the existing broken clients

**Files:**
- Create: `functions/scripts/backfill-wave-blocked.js`
- Create: `functions/__tests__/backfill_wave_blocked.test.js`

House style: `_flags.js` guard, `_project.js` target banner, `--dry-run`
printing the full change list, idempotent, paged with a cap and a warn (see
`backfill-search-tokens.js` and `audit-wave-contract.js`).

**Expect it to write nothing.** The 2026-09-09 replay found zero blocking
problems, so this is a no-op today and exists so the state is *derivable* from
the collection rather than only from the trigger.

- [ ] **Step 9.1:** Tests first — a blocking client gets `blocked` + problems;
      a clean client is left alone; `--dry-run` writes nothing (the
      lesson from the backfill whose dry-run wrote everything and then threw).
- [ ] **Step 9.2:** Implement, reusing `audit-wave-contract.js`'s `scanByName`
      paging.
- [ ] **Step 9.3:** Run `--dry-run` against prod, read the list, then run live.

---

# PHASE 4 — Refactors

Pure moves onto code already behaving. **Do not start these until 2B has been
deployed and has run quietly for several days.**

**Built 2026-09-13 by owner call, the same day 2B deployed.** The "several
quiet days" guard now applies to DEPLOYING Phase 4, not to building it.

**Verified after the build, observed rather than carried forward:** analyzer
clean; `flutter test` **3678 passed** (baseline 3686 on `ba2fdb05`, minus the 8
cadence tests deleted with it); functions eslint clean; jest **1927 passed / 94
suites** (baseline 1935 / 91).

## Task 10: Split `worker.js` four ways

814 lines (not the design's 968 — it has already shrunk). Two of the four cuts
are contiguous and two are not.

| module | source | contiguous? |
|---|---|---|
| `enqueue.js` | `:194-273` | **yes** — cleanest cut, do it first |
| `outbox_queries.js` | `:695-803` | **yes** |
| `outbox_core.js` | `:75-192`, `:306-395`, `:446-477` | no |
| `dispatch.js` | `:397-445`, `:478-693` | no |

- [x] **Step 10.1:** Move `enqueue.js` alone, re-export from `worker.js`, run
      the suite. One commit.
- [x] **Step 10.2:** Same for `outbox_queries.js`.
- [x] **Step 10.3:** The core/dispatch cut last — they interleave through the
      "drainQueue phases" block (`:275-611`) and share the `DrainContext`
      typedef (`:277-296`), which goes to `outbox_core.js` with `dispatch.js`
      importing it.
- [x] **Step 10.4:** `wave_worker.test.js` (2,218 lines, 60 tests) splits with
      the modules. **`wave_callables.test.js` and `wave_triggers.test.js`
      `jest.mock("../wave/worker")` by module path** — every moved export
      needs its mock re-pointed, or the mock silently stops intercepting and
      the assertions pass vacuously.

**As built, and where it deviates.**
- **A fifth, leaf module: `outbox_keys.js`** (`QUEUE_COLLECTION`,
  `OUTSTANDING_STATUSES`, `customerUpsertJobId`, `clientIdFromRefPath`).
  Task 11 needs the job id inside `customers_import.js`, and reaching it
  through `outbox_core.js` closes a cycle: `customers_import` → `outbox_core`
  → `retry_policy` → `customers` → `customers_import`.
- **One change, not four commits** — nothing here is committed; the
  orchestrator lands it.
- **No mock needed re-pointing, and that was PROVED rather than assumed.**
  Every production caller still requires `./worker`, so both mocks still
  intercept. Pointing `callables.js`'s `drainQueue` at `./dispatch` failed 2
  tests in `wave_callables`; pointing `triggers.js`'s `enqueueCustomerUpsert`
  at `./enqueue` failed 6 in `wave_triggers`. Both were restored.
- The test file became `wave_enqueue` / `wave_dispatch` /
  `wave_outbox_queries` over shared fakes in
  `__tests__/mocks/wave_outbox_fakes.js` (under the ignored `mocks/`, so jest
  does not collect it as a suite), plus a `wave_worker` test pinning that
  each re-export IS the owning module's function.

## Task 11: The import's transactional precondition

Design §5.1 — replace the `skipClientIds` protect-list with a per-write
transactional check.

**Price this before starting.** `importOneCustomer` stages onto a shared
`WriteBatch` (`BATCH_LIMIT = 500`, `customers_import.js:30`), staged at `:105`
and `:114`. A per-doc transaction means unwinding that batching in
`importCustomers`' page loop: one batched write per client becomes a
transaction (a read + a write) per client. On ~724 clients a full pass goes
from ~2 batch commits to ~724 transactions.

- [x] **Step 11.1: Decided YES — and the price above was overstated.** Only
      the UPDATE branch needs the check: `skippedUnchanged`,
      `skippedArchived` and `skippedPending` write nothing, and a create has
      no prior doc or job. So a steady-state full pass costs a handful of
      transactions, not ~724; ~726 is the worst case, every linked customer
      changed in Wave. From the code: once Task 12 removed the daily rider,
      full passes run ONLY in `waveImportCustomers` (`timeoutSeconds: 300`,
      client deadline `kWaveSyncTimeoutSeconds` 120 s), and they go full at
      most every `FULL_RESYNC_INTERVAL_MS` (7 days). `wave.md` records serial
      per-job transactions at ~40-60 ms (a few hundred requeues took
      12-20 s), so 726 at `GUARDED_UPDATE_CHUNK` = 25 concurrent is ~2-3 s,
      and ~44 s even fully serial — inside both deadlines. The transactions
      touch distinct client and job documents, so they contend only with a
      concurrent edit of the SAME client, and that retry is exactly the case
      the check exists for. The extra billed read per guarded write is
      negligible.
- [x] **Step 11.2:** `commitGuardedUpdates` (`customers_import.js`) runs each
      held update in a transaction that reads `customerUpsert__<id>` first
      and skips while it is `queued`/`inflight`/`dead`. Held or FAILED writes
      count as `skippedPending`, so the watermark hold still works. Creates,
      and updates to a doc created earlier in the same run, stay batched.
      `skipClientIds` survives as a prefilter, so `listOutstandingClientIds`
      keeps its caller; its at-cap log became a warn, because a truncated list
      now costs only transactions. Tests were written first and seen red, and
      disabling the check fails 4 of them. **Not closed:** an edit whose
      trigger has not yet enqueued its job, a window of seconds.

## Task 12: Delete the scheduled-import cadence

`importSchedule` is `"off"` in prod by owner choice, so the weekly/monthly
apparatus is dead weight (design §3.5).

**`waveSetImportSchedule` is a deployed callable with a live Dart caller
(`wave_service.dart:165`), and it is the only Wave callable with a non-empty
allowlist (`new Set(["schedule"])`).** It follows `docs/DEPLOYMENT.md` §4a:
neutralise server-side first, keep the key **accepted and ignored**, tag it
`#compat-1.59.0`, and remove it only once **both** halves hold — the current
client sends nothing, **and** no build at or below the last one that does
remains in the fleet. That is a separate deploy; it does not ride along with
the app build that stops calling it.

**Tagged `#compat-1.61.0`, not 1.59.0**: 1.61.0+90 is the newest shipped build
and still calls it (`dd8c4863:lib/features/wave/data/wave_service.dart`).

- [x] **Step 12.1:** Delete the cadence half of `import_schedule.js`
      (`DAY_MS`, `WEEK_MS`, `MONTH_MS`, `SCHEDULE_VALUES`, `SCHEDULE_SET`,
      `isImportDue`). **Keep the watermark half** — `DELTA_OVERLAP_MS`,
      `FULL_RESYNC_INTERVAL_MS`, `resolveImportWindow`, `watermarkPatch`
      (§5.2). The file is half-and-half; do not delete it whole. `DAY_MS`
      stayed after all: `FULL_RESYNC_INTERVAL_MS` is built from it.
- [x] **Step 12.2:** Remove `runWaveDaily`'s import rider (`triggers.js:295-336`).
      **The drain above it (`:274-293`) SURVIVES** — it is the safety net for a
      job on backoff or left `inflight` by a dead instance, neither of which
      produces a client write to ride on. `importWithWatermark`'s
      `extraPatch` went too — that rider was its only caller.
- [x] **Step 12.3:** Remove the Settings cadence control
      (`wave_settings_section.dart:20-25, 189-220, 323-346`),
      `wave_import_schedule.dart`, the `WaveConnection.importSchedule` field,
      `WaveService.setImportSchedule`, and the five `wave_autoImport*` ARB keys
      from **both** ARBs.
- [x] **Step 12.4:** Neutralise `waveSetImportSchedule` server-side; leave the
      export and the allowlist key in place with the `#compat-` tag. It
      returns `{schedule: "off"}` with no read, no write and no rate limit,
      and logs `WAVE-SCHED ignored a retired cadence call` — the signal for
      retiring it. `waveGetConnection` also stops returning
      `importSchedule`: 1.61.0's `WaveConnection.fromMap` defaults an absent
      value to `off`, so no carve-out is needed there.
- [x] **Step 12.5:** `import_schedule.test.js` (27 tests) loses its cadence
      half and keeps its watermark half (9 tests now, including one pinning
      that the module exports nothing else).

**Deploy (not done).** No new export (29), no index, no rules change, and
no allowlist key removed, so it is compatible with every shipped build. It
may deploy before or after the next app build. That build drops the picker,
and 1.61.0 still gets a success from the no-op. One cosmetic lie remains
for 1.61.0 admins: picking a cadence shows "Automatic import updated." and
then re-reads as Off. The deploy should still wait on the quiet-days guard
above, since Task 11 changes the import's write path.

---

## Verification

Run at the end of each phase, not only at the end:

```bash
flutter analyze                      # must print: No issues found!
flutter test                         # whole suite (CI runs the whole suite)
flutter gen-l10n                     # after any ARB change; check untranslated.json
cd functions && npm run lint && npx jest
```

Baselines to beat, **observed 2026-09-10 on this branch**, not carried from a
plan doc: **3590 Flutter tests**, analyzer clean. Re-measure the jest count
before Phase 2B rather than trusting the 1561 recorded on 2026-08-30 — a
recorded green is a claim, not a fact.

Before any deploy: `docs/DEPLOYMENT.md`, and clear
`AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` from the shell first. Never `--force`.
