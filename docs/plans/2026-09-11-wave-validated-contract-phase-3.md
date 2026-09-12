# Wave validated contract — Phase 3 (backfill) implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: TASKS 1-3 BUILT 2026-09-12 (17 jest tests, lint clean); Task 4, the live run, NOT started and still gated on the enforcement deploy.** Built as one file rather than three commits, with the plan's long comment blocks trimmed to the one-line rule; the rationale lives in `.claude/rules/wave.md`. Written 2026-09-11. Supersedes Task 9 of
`docs/plans/2026-09-10-wave-validated-contract-phases-2-4.md`, which was a
three-step stub. Phase 2 is built and merged to `dev` (`ca80dff5`, 1.60.0+89)
and **not deployed**.

**Goal:** Make a client's Wave contract verdict derivable from the `clients`
collection itself, so a client that was already broken before Phase 2 deployed
is visible in the app without waiting for somebody to edit it.

**Architecture:** One operator script,
`functions/scripts/backfill-wave-blocked.js`, replays the existing pure
contract (`functions/wave/customer_contract.js`) over every client and writes
the same `wave.*` patch the trigger writes — `verdictPatch`, no new verdict
logic. It is idempotent by comparing the derived verdict against the stored
one and skipping when they agree, which is what makes a re-run free and a
`--dry-run` honest. No function, rule, index or app change.

**Tech Stack:** Node 24, `firebase-admin`, jest. House helpers `_flags.js`,
`_project.js`, `_scan.js`, `_batch.js`.

---

## Correction to the superseded stub: it will NOT write nothing

Task 9 said "**Expect it to write nothing.** The 2026-09-09 replay found zero
blocking problems, so this is a no-op today."

**That is wrong, and the reasoning skipped a severity.** `verdictPatch` records
`wave.problems` for **both** severities — that is the whole point of the split
(`customer_contract.js`, the `WaveProblem` typedef). The same replay that found
zero blocking problems found **one advisory**: client `2wcEiCNztsWYUYNXYBEm`,
`phone:NOT_DIALABLE`, re-confirmed by the 2026-09-10 run recorded in
`docs/DEPLOYMENT.md` (`725 scanned / 0 blocking / 1 advisory`).

Nothing has written `wave.problems` to any document yet, because Phase 2 is not
deployed. So the expected live result is **1 patched, 0 blocked, 1 advisory** —
and that one client is the entire reason this phase exists, since it is a client
with no reachable phone number that no admin can currently see.

**Do not treat a patched count of 0 as success.** If the live run reports 0
patched against a non-zero advisory count from the audit, the idempotence
comparison is wrong, not the data.

### Second correction: there is no cap and no warn here

The stub also said "paged with a cap and a warn (see `backfill-search-tokens.js`
and `audit-wave-contract.js`)". **Neither of those has a cap**, and this one
must not either. The cap-and-warn rule in `CLAUDE.md` governs a *bounded read
window* in the app — a window that stops early and warns because it is serving
a screen. An operator script that must visit EVERY client is the opposite case:
a cap there would silently leave the tail of the collection unrecorded, which
is precisely the half-backfilled state this phase exists to remove, and the
warn would be reporting normal completion. `scanByName` (`scripts/_scan.js`) is
uncapped by design and terminates on a short page. Do not add a ceiling.

---

## Ordering — Phase 3 runs LAST, and the gate is not optional

From `2026-09-10-wave-validated-contract-phases-2-4.md`'s deploy-ordering
section, which is binding and inverts the repo's usual backend-first rule:

1. Deploy the composite index (`firestore:indexes`) and wait for `READY`.
   **Not done** — `firestore_list_indexes` on `clients` returned four
   composites on 2026-09-11 and `wave.syncState + name` is not among them.
2. Ship the app build that renders `blocked` and the problem list.
3. Deploy the backend enforcement.
4. **Run this backfill.** ← this plan

Running it before step 2 writes a `blocked` state that every shipped build
renders as **no badge at all** (`WaveSyncBadge._badgeConfig` returns
`SizedBox.shrink()` for an unknown state) — strictly less signal than today.

**Steps 1-3 are the owner's, not this plan's.** Tasks 1-3 below (write and test
the script) can be done at any time; **Task 4 is the live run and must not
start until step 3 is deployed.**

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `functions/scripts/backfill-wave-blocked.js` | Replay the contract, write the verdict patch, report. | **Create** |
| `functions/__tests__/backfill_wave_blocked.test.js` | Pin idempotence, dry-run, paging, the verdict shapes. | **Create** |
| `.claude/rules/wave.md` | Record the script and the two decisions below. | Modify |
| `docs/plans/README.md` | §7 prod-script list gains a row. | Modify |
| `docs/DEPLOYMENT.md` | Deploy-log row for the live run. | Modify (Task 4) |

Nothing else. **No CHANGELOG entry** — an operator script is not user-visible,
and the user-visible half shipped with Phase 2's `## [1.60.0+89]` entry.

---

## Two decisions this plan makes, and the evidence for each

These are the judgment calls. They are recorded here because a later reader
will otherwise re-litigate them.

### 1. A newly-blocked client's queued job is NOT cancelled

The trigger cancels one (`triggers.js:149`, `cancelCustomerUpsert`), so the
obvious symmetry says the backfill should too. It should not, for two reasons:

- **The dispatcher already refuses it.** `worker.js:807` re-runs the contract
  inside the dispatch transaction and writes `verdictPatch(contract)` — a
  queued job for a blocked client is refused one moment later regardless.
- **The queue is empty.** `drain-wave-queue.js --dry-run` reported `0 queued`
  on 2026-09-10 (`docs/DEPLOYMENT.md`).

Adding a transactional delete per client to a bulk script, to handle a case the
dispatcher handles and the data does not contain, is cost and risk for nothing.

### 2. A STALE `blocked` client is reported and left completely alone

A doc that reads `wave.syncState: "blocked"` while the contract now passes is
inconsistent. The backfill **skips it entirely** — it does not clear the
problems and it does not clear the state.

- It cannot clear the state: `verdictPatch` deliberately leaves `syncState`
  alone when nothing blocks, because "a clean client's state is owned by the
  push (`pending` → `synced` / `error`), and stamping it here would fight the
  worker for it" (`customer_contract.js`). Inventing `pending` here without
  enqueueing a job is worse than the inconsistency.
- It must not clear the problems **alone**, because that leaves the doc reading
  `blocked` with no reason attached — the Settings blocked list would show a
  client with an empty explanation, which is worse than a stale one.

So: count it, name it under `--verbose`, and leave it. **The remedy is a no-op
client write**, which re-fires `waveUpsertCustomer` and lets the trigger resolve
state and problems together in one batch, exactly as it does for a repair.

Expected count: **0**. It is only reachable when a contract RULE changes
severity — which has happened once already (`NOT_DIALABLE` was demoted from
blocking to advisory), so it is worth detecting rather than assuming away.

---

## Task 1: The pure verdict-to-patch decision

**Files:**
- Create: `functions/scripts/backfill-wave-blocked.js`
- Create: `functions/__tests__/backfill_wave_blocked.test.js`

- [ ] **Step 1.1: Write the failing tests for the comparison and the decision**

Create `functions/__tests__/backfill_wave_blocked.test.js`:

```js
"use strict";

// Pins `backfill-wave-blocked.js`. The properties that matter are the ones
// that make an unattended bulk write against /clients safe: a re-run writes
// nothing, `--dry-run` writes nothing, the paging loop terminates, and the
// patch is the same one the trigger writes rather than a second spelling.

// Import ONLY what this file asserts on. `functions` runs `eslint .` over
// `__tests__` with `eslint:recommended`, so `no-unused-vars` is an error — a
// destructured name reserved for a later task fails the lint, not the test.
// Task 2 extends this list when it adds the scan.
const {
  changeFor,
  sameProblems,
} = require("../scripts/backfill-wave-blocked");

const LONG_NAME = "x".repeat(201);

describe("sameProblems", () => {
  test("an absent stored field equals a derived empty list", () => {
    expect(sameProblems(undefined, [])).toBe(true);
    expect(sameProblems(null, [])).toBe(true);
  });

  test("compares TOO_LONG detail, not just the code", () => {
    const a = [{field: "name", code: "TOO_LONG", severity: "blocking",
      detail: {length: 201, cap: 200}}];
    const b = [{field: "name", code: "TOO_LONG", severity: "blocking",
      detail: {length: 225, cap: 200}}];
    expect(sameProblems(a, b)).toBe(false);
  });

  test("a severity change alone is a change", () => {
    const a = [{field: "phone", code: "NOT_DIALABLE", severity: "blocking",
      detail: null}];
    const b = [{field: "phone", code: "NOT_DIALABLE", severity: "advisory",
      detail: null}];
    expect(sameProblems(a, b)).toBe(false);
  });
});

describe("changeFor", () => {
  test("a blocking client gets blocked + problems + a cleared error", () => {
    const {patch, blocked} = changeFor({name: ""});
    expect(blocked).toBe(true);
    expect(patch["wave.syncState"]).toBe("blocked");
    expect(patch["wave.syncError"]).toBeNull();
    expect(patch["wave.problems"]).toEqual([
      {field: "name", code: "EMPTY", severity: "blocking", detail: null},
    ]);
  });

  test("an advisory-only client records the problem and NOT a state", () => {
    const {patch, blocked, advisory} =
      changeFor({name: "Acme", phone: "Contact Person"});
    expect(blocked).toBe(false);
    expect(advisory).toBe(true);
    expect(patch["wave.syncState"]).toBeUndefined();
    expect(patch["wave.problems"]).toEqual([
      {field: "phone", code: "NOT_DIALABLE", severity: "advisory",
        detail: null},
    ]);
  });

  test("a clean client with nothing stored is NOT a write", () => {
    // The idempotence rule that keeps a clean collection from costing 725
    // writes: an absent `wave.problems` and a derived `null` are the same.
    expect(changeFor({name: "Acme"}).patch).toBeNull();
  });

  test("a client repaired since the last write has its problems cleared", () => {
    const stored = {
      name: "Acme",
      wave: {syncState: "synced", problems: [
        {field: "name", code: "TOO_LONG", severity: "blocking",
          detail: {length: 201, cap: 200}},
      ]},
    };
    expect(changeFor(stored).patch).toEqual({"wave.problems": null});
  });

  test("a re-run over an already-recorded verdict writes nothing", () => {
    const first = changeFor({name: LONG_NAME});
    const stored = {
      name: LONG_NAME,
      wave: {
        syncState: first.patch["wave.syncState"],
        syncError: null,
        problems: first.patch["wave.problems"],
      },
    };
    expect(changeFor(stored).patch).toBeNull();
  });

  test("a stale blocked doc is reported and left completely alone", () => {
    // Reachable when a contract rule changes severity, as NOT_DIALABLE did.
    const stored = {
      name: "Acme",
      wave: {syncState: "blocked", problems: [
        {field: "phone", code: "NOT_DIALABLE", severity: "blocking",
          detail: null},
      ]},
    };
    const {patch, staleBlocked} = changeFor(stored);
    expect(staleBlocked).toBe(true);
    expect(patch).toBeNull();
  });

  test("a stale syncError on a current blocked doc is cleared", () => {
    const stored = {
      name: "",
      wave: {
        syncState: "blocked",
        syncError: "Wave refused it",
        problems: [
          {field: "name", code: "EMPTY", severity: "blocking", detail: null},
        ],
      },
    };
    expect(changeFor(stored).patch["wave.syncError"]).toBeNull();
  });
});
```

- [ ] **Step 1.2: Run the tests to verify they fail**

Run: `cd functions && npx jest backfill_wave_blocked`
Expected: FAIL — `Cannot find module '../scripts/backfill-wave-blocked'`.

- [ ] **Step 1.3: Write the script's pure half**

Create `functions/scripts/backfill-wave-blocked.js`:

```js
#!/usr/bin/env node
// One-off: records the Wave customer contract's verdict on every client, so a
// client that was already wrong before enforcement deployed is visible without
// waiting for somebody to edit it.
//
// It writes the SAME patch the trigger writes (`verdictPatch`) and derives no
// verdict of its own — a second spelling of "is this blocked?" is exactly the
// drift `customer_contract.js` exists to close.
//
// RUN THIS LAST. The app build that renders `blocked` must already be shipped
// and the backend enforcement deployed; see the deploy-ordering section of
// `docs/plans/2026-09-10-wave-validated-contract-phases-2-4.md`.
//
// Idempotent: a doc whose stored verdict already matches is skipped.
//
// Usage:
//   For prod:
//     $env:GOOGLE_APPLICATION_CREDENTIALS =
//       "C:\path\to\prod-service-account.json"
//     node functions/scripts/backfill-wave-blocked.js --dry-run --verbose
//     node functions/scripts/backfill-wave-blocked.js
//
//   For the local emulator:
//     $env:FIRESTORE_EMULATOR_HOST = "localhost:8080"
//     $env:GCLOUD_PROJECT = "schedulingapp-88727"
//     node functions/scripts/backfill-wave-blocked.js
//
// AN UNKNOWN ARGUMENT IS A HARD ERROR — see `_flags.js`.

"use strict";

const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {commitInBatches} = require("./_batch");
const {bootstrapScript} = require("./_project");
const {scanByName} = require("./_scan");
const {buildCustomerPayload, verdictPatch} =
  require("../wave/customer_contract");

/** Bare switches, matched EXACTLY — see `_flags.js`. */
const EXACT_FLAGS = ["--dry-run", "--verbose"];

const BATCH_SIZE = 400;
const PAGE_SIZE = 500;

/**
 * Rejects any argument that is not a flag this script knows.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/**
 * Whether two problem entries describe the same fault.
 *
 * `detail` is compared field by field rather than by identity: a name that
 * grew from 201 to 225 characters is still TOO_LONG, and a patch that never
 * updated the stored length would leave the UI quoting a stale number.
 * @param {!Object} a One stored problem.
 * @param {!Object} b One derived problem.
 * @return {boolean}
 */
function sameProblem(a, b) {
  const left = a.detail || null;
  const right = b.detail || null;
  if ((left === null) !== (right === null)) return false;
  if (left && (left.length !== right.length || left.cap !== right.cap)) {
    return false;
  }
  return a.field === b.field && a.code === b.code && a.severity === b.severity;
}

/**
 * Whether the stored problem list already says what the contract derived.
 *
 * An ABSENT stored field and a derived empty list are the same thing, and that
 * equivalence is what makes this backfill cheap: without it every one of the
 * ~725 clean clients takes a write to stamp `wave.problems: null` over a field
 * that was never there.
 *
 * Order matters — the contract emits problems in a fixed order (name, then
 * over-long fields in `PAYLOAD_CAPS` order, then contact), so a reordering is
 * a real difference rather than a false positive.
 * @param {*} stored The stored `wave.problems` value, possibly absent.
 * @param {!Array<!Object>} derived The contract's problems.
 * @return {boolean}
 */
function sameProblems(stored, derived) {
  const left = Array.isArray(stored) ? stored : [];
  const right = Array.isArray(derived) ? derived : [];
  if (left.length !== right.length) return false;
  return left.every((problem, i) => sameProblem(problem || {}, right[i]));
}

/**
 * The verdict for one client, and the patch to write for it.
 *
 * `patch` is null when nothing needs writing — including the STALE BLOCKED
 * case, which is skipped whole rather than half-patched. See decision 2 in
 * `docs/plans/2026-09-11-wave-validated-contract-phase-3.md`: clearing the
 * problems without clearing the state would leave the Settings list showing a
 * blocked client with no reason attached, and the state is not this script's
 * to clear.
 * @param {?Object} data The stored client document.
 * @return {{patch: ?Object, blocked: boolean, advisory: boolean,
 *   staleBlocked: boolean, problems: !Array<!Object>}}
 */
function changeFor(data) {
  const fields = data || {};
  const wave = fields.wave || {};
  const verdict = buildCustomerPayload(fields);
  const patch = verdictPatch(verdict);
  const problems = Array.isArray(verdict.problems) ? verdict.problems : [];

  const staleBlocked = verdict.ok === true && wave.syncState === "blocked";
  const changed =
    !sameProblems(wave.problems, problems) ||
    (patch["wave.syncState"] !== undefined &&
      wave.syncState !== patch["wave.syncState"]) ||
    ("wave.syncError" in patch && (wave.syncError || null) !== null);

  return {
    patch: staleBlocked || !changed ? null : patch,
    blocked: verdict.ok === false,
    advisory: verdict.ok === true && problems.length > 0,
    staleBlocked,
    problems,
  };
}

module.exports = {
  assertKnownFlags,
  changeFor,
  sameProblem,
  sameProblems,
  PAGE_SIZE,
};
```

- [ ] **Step 1.4: Run the tests to verify they pass**

Run: `cd functions && npx jest backfill_wave_blocked`
Expected: PASS, 10 tests. `backfillBlockedClients` is imported but not yet
asserted on — it is `undefined` until Task 2, which is fine.

- [ ] **Step 1.5: Lint**

Run: `cd functions && npm run lint`
Expected: clean. Every function needs a JSDoc block with a `@param` per
parameter and a `@return` — `functions/` runs `require-jsdoc` + `valid-jsdoc`.

- [ ] **Step 1.6: Commit**

```bash
git add functions/scripts/backfill-wave-blocked.js \
        functions/__tests__/backfill_wave_blocked.test.js
git commit -F- <<'MSG'
Derive the Wave contract verdict from a client doc

The pure half of the Phase 3 backfill: replay the contract, compare the
verdict against what the doc already stores, and write nothing when they
agree. An absent wave.problems and a derived empty list are the same
thing, which is what keeps a clean collection from costing a write per
client.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CKMzxXKL8Q6UjvCfg1q3q6
MSG
```

---

## Task 2: The paged, batched scan

**Files:**
- Modify: `functions/scripts/backfill-wave-blocked.js`
- Modify: `functions/__tests__/backfill_wave_blocked.test.js`

- [ ] **Step 2.1: Extend the test file's import**

Replace the `require` at the top of
`functions/__tests__/backfill_wave_blocked.test.js` with:

```js
const {
  changeFor,
  sameProblems,
  backfillBlockedClients,
  PAGE_SIZE,
} = require("../scripts/backfill-wave-blocked");
```

Both new names are used by the tests below, so `no-unused-vars` stays happy.

- [ ] **Step 2.2: Write the failing tests**

Append to `functions/__tests__/backfill_wave_blocked.test.js`:

```js
/**
 * A Firestore stand-in over one in-memory `clients` collection.
 *
 * Shaped like `backfill_search_tokens.test.js`'s: it records every staged
 * update so a `--dry-run` assertion is about what was WRITTEN, not about what
 * the summary claims.
 * @param {!Array<{id: string, data: !Object}>} docs Seed documents.
 * @return {!Object}
 */
function fakeDb(docs) {
  const committed = [];
  const pages = [];
  const makeDoc = (d) => ({id: d.id, ref: {id: d.id}, data: () => d.data});
  const query = (after) => {
    const start = after ? docs.findIndex((d) => d.id === after.id) + 1 : 0;
    const slice = docs.slice(start, start + PAGE_SIZE).map(makeDoc);
    pages.push(slice.length);
    return {docs: slice, size: slice.length, empty: slice.length === 0};
  };
  const chain = (after) => ({
    orderBy: () => chain(after),
    limit: () => chain(after),
    startAfter: (cursor) => chain(cursor),
    get: async () => query(after),
  });
  return {
    committed,
    pages,
    collection: () => chain(null),
    batch: () => ({
      update: (ref, patch) => committed.push({id: ref.id, patch}),
      commit: async () => {},
    }),
  };
}

describe("backfillBlockedClients", () => {
  const seed = () => [
    {id: "a-clean", data: {name: "Acme"}},
    {id: "b-advisory", data: {name: "Beta", phone: "Contact Person"}},
    {id: "c-blocked", data: {name: ""}},
    {id: "d-stale", data: {name: "Delta", wave: {syncState: "blocked",
      problems: [{field: "phone", code: "NOT_DIALABLE",
        severity: "blocking", detail: null}]}}},
  ];

  test("writes only the clients whose verdict is not recorded", async () => {
    const db = fakeDb(seed());
    const summary = await backfillBlockedClients(db, {dryRun: false});

    expect(summary.scanned).toBe(4);
    expect(summary.patched).toBe(2);
    expect(summary.blocked).toBe(1);
    expect(summary.advisory).toBe(1);
    expect(summary.staleBlocked).toBe(1);
    expect(db.committed.map((c) => c.id).sort())
        .toEqual(["b-advisory", "c-blocked"]);
  });

  test("--dry-run writes nothing while reporting the same counts", async () => {
    // The lesson from the backfill in this directory whose --dry-run wrote
    // everything and then threw: assert on the writes, not on the summary.
    const db = fakeDb(seed());
    const summary = await backfillBlockedClients(db, {dryRun: true});

    expect(summary.patched).toBe(2);
    expect(db.committed).toHaveLength(0);
  });

  test("names the affected clients for --verbose", async () => {
    const db = fakeDb(seed());
    const summary = await backfillBlockedClients(db, {dryRun: true});

    expect(summary.changes.map((c) => c.id))
        .toEqual(["b-advisory", "c-blocked"]);
    expect(summary.staleBlockedIds).toEqual(["d-stale"]);
  });

  test("a second run over the written result patches nothing", async () => {
    const first = fakeDb(seed());
    await backfillBlockedClients(first, {dryRun: false});

    const merged = seed().map((doc) => {
      const write = first.committed.find((c) => c.id === doc.id);
      if (!write) return doc;
      const wave = {...(doc.data.wave || {})};
      for (const [key, value] of Object.entries(write.patch)) {
        wave[key.replace("wave.", "")] = value;
      }
      return {id: doc.id, data: {...doc.data, wave}};
    });

    const second = fakeDb(merged);
    const summary = await backfillBlockedClients(second, {dryRun: false});
    expect(summary.patched).toBe(0);
    expect(second.committed).toHaveLength(0);
  });

  test("the paging loop terminates past one full page", async () => {
    const many = Array.from({length: PAGE_SIZE + 7}, (_, i) => ({
      id: `c${String(i).padStart(4, "0")}`,
      data: {name: "Acme"},
    }));
    const db = fakeDb(many);
    const summary = await backfillBlockedClients(db, {dryRun: false});

    expect(summary.scanned).toBe(PAGE_SIZE + 7);
    expect(db.pages).toEqual([PAGE_SIZE, 7]);
  });
});
```

- [ ] **Step 2.3: Run the tests to verify they fail**

Run: `cd functions && npx jest backfill_wave_blocked`
Expected: FAIL — `backfillBlockedClients is not a function`.

- [ ] **Step 2.4: Implement the scan**

Insert into `functions/scripts/backfill-wave-blocked.js`, above
`module.exports`:

```js
/**
 * Replays the contract over every client and records the verdict.
 *
 * Paged, never one `.get()` of the whole collection: a run that dies part-way
 * leaves a HALF-recorded collection, which from the app's side is
 * indistinguishable from one that was never backfilled at all.
 *
 * Paged on `__name__` specifically — an `orderBy` on any other field makes
 * Firestore EXCLUDE a doc missing it, and a legacy doc missing a field is
 * exactly the shape most likely to fail the contract.
 * @param {!Object} db The Firestore handle.
 * @param {{dryRun: boolean}} options Whether this run actually writes.
 * @return {!Promise<{scanned: number, patched: number, blocked: number,
 *   advisory: number, staleBlocked: number, changes: !Array<!Object>,
 *   staleBlockedIds: !Array<string>}>} The tally. `changes` and
 *   `staleBlockedIds` are collected rather than printed so the core stays
 *   testable without capturing stdout — the same shape
 *   `audit-wave-contract.js` uses, bounded by the same collection.
 */
async function backfillBlockedClients(db, {dryRun}) {
  const writer = commitInBatches(db, {dryRun, batchSize: BATCH_SIZE});
  const changes = [];
  const staleBlockedIds = [];
  let scanned = 0;
  let blocked = 0;
  let advisory = 0;

  for await (const doc of scanByName(
      db.collection("clients"), {pageSize: PAGE_SIZE})) {
    scanned += 1;
    const verdict = changeFor(doc.data() || {});
    if (verdict.blocked) blocked += 1;
    if (verdict.advisory) advisory += 1;
    if (verdict.staleBlocked) {
      staleBlockedIds.push(doc.id);
      continue;
    }
    if (!verdict.patch) continue;
    changes.push({
      id: doc.id,
      blocked: verdict.blocked,
      problems: verdict.problems,
    });
    await writer.stage(doc.ref, verdict.patch);
  }
  await writer.flush();

  return {
    scanned,
    patched: changes.length,
    blocked,
    advisory,
    staleBlocked: staleBlockedIds.length,
    changes,
    staleBlockedIds,
  };
}
```

And add `backfillBlockedClients,` to `module.exports`.

- [ ] **Step 2.5: Run the tests to verify they pass**

Run: `cd functions && npx jest backfill_wave_blocked`
Expected: PASS, 15 tests.

- [ ] **Step 2.6: Lint and commit**

```bash
cd functions && npm run lint
```

```bash
git add functions/scripts/backfill-wave-blocked.js \
        functions/__tests__/backfill_wave_blocked.test.js
git commit -F- <<'MSG'
Page the Wave verdict backfill and pin its dry run

Assert on what was written rather than on what the summary claims - this
directory has a backfill whose --dry-run wrote everything and then threw.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CKMzxXKL8Q6UjvCfg1q3q6
MSG
```

---

## Task 3: The entry point, and the docs that keep it findable

**Files:**
- Modify: `functions/scripts/backfill-wave-blocked.js`
- Modify: `.claude/rules/wave.md`
- Modify: `docs/plans/README.md` (the "Prod scripts" section, §7)

- [ ] **Step 3.1: Write `main()`**

Insert above the `module.exports` block:

```js
/**
 * Entry point.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {db, dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const verbose = argv.includes("--verbose");
  const tag = dryRun ? "[dry-run] " : "";

  const summary = await backfillBlockedClients(db, {dryRun});

  console.log(
      `\n${tag}clients: ${summary.scanned} scanned, ` +
      `${summary.patched} verdict rows patched`);
  console.log(
      `  ${summary.blocked} BLOCKED (Wave would refuse), ` +
      `${summary.advisory} advisory`);

  if (summary.staleBlocked > 0) {
    // Not an error, and not this script's to fix — see decision 2 in
    // `docs/plans/2026-09-11-wave-validated-contract-phase-3.md`.
    console.log(
        `  ${summary.staleBlocked} read "blocked" but now PASS the ` +
        `contract; left untouched. Edit each client — any no-op write ` +
        `re-fires waveUpsertCustomer, which clears state and problems ` +
        `together.`);
  }

  if (verbose) {
    for (const {id, blocked, problems} of summary.changes) {
      const detail = problems
          .map((p) => `${p.field}:${p.code}`)
          .join(", ") || "cleared";
      console.log(`  ${blocked ? "BLOCKED " : "advisory"}  ${id}  ${detail}`);
    }
    for (const id of summary.staleBlockedIds) {
      console.log(`  stale     ${id}`);
    }
  } else if (summary.patched > 0 || summary.staleBlocked > 0) {
    console.log("Re-run with --verbose to list them.");
  }
}

// Only run when invoked directly, so the pure halves are requirable by jest
// without the script reaching for prod credentials.
if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
```

- [ ] **Step 3.2: Verify the flag guard rejects a typo**

Run:
```bash
cd functions && node scripts/backfill-wave-blocked.js --dryrun
```
Expected: exits non-zero with
`unknown argument "--dryrun" — did you mean --dry-run?` and **no credential
lookup** — `assertFlags` runs before `initializeApp` inside `bootstrapScript`.

- [ ] **Step 3.3: Record the script in `.claude/rules/wave.md`**

Add to the Wave rules file, in the section describing the contract:

```markdown
- **A client's contract verdict is derivable from the collection, not only
  from the trigger.** `functions/scripts/backfill-wave-blocked.js` replays
  `buildCustomerPayload` over every client and writes the same `verdictPatch`
  the trigger writes. It exists because the trigger only stamps a doc that
  somebody EDITS, so a client that was already wrong when enforcement deployed
  would stay invisible indefinitely. Two rules inside it are load-bearing: an
  absent `wave.problems` and a derived empty list are EQUAL (otherwise every
  clean client costs a write per run), and a doc reading `blocked` that now
  passes the contract is reported and left ENTIRELY alone — clearing its
  problems without clearing its state would show a blocked client with no
  reason, and the non-blocked state is owned by the push, not by a backfill.
```

- [ ] **Step 3.4: Add the row to `docs/plans/README.md` §7**

Under "Prod scripts — what must never be re-run, and what is closed":

```markdown
- **Outstanding: `backfill-wave-blocked.js`** — Phase 3 of the Wave contract.
  Run it only AFTER the app build renders `blocked` and the enforcement
  backend is deployed; before that it writes a state every shipped build
  renders as no badge at all. Idempotent, so a re-run is free.
```

That section opens "**Nothing here is outstanding.**" — change that sentence
to name this one, or the row contradicts its own heading.

- [ ] **Step 3.5: Run the whole functions suite**

Run: `cd functions && npm run lint && npx jest`
Expected: lint clean; jest green. The baseline to beat is **1872 passing**
(observed 2026-09-10 on the Phase 2 branch) plus the 15 new tests.
**Re-measure rather than trusting that number** — a recorded green is a claim,
not a fact.

- [ ] **Step 3.6: Commit**

```bash
git add functions/scripts/backfill-wave-blocked.js .claude/rules/wave.md \
        docs/plans/README.md
git commit -F- <<'MSG'
Add the Wave verdict backfill entry point and record it

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CKMzxXKL8Q6UjvCfg1q3q6
MSG
```

---

## Task 4: The live run — OWNER ONLY, gated on the deploy

**Do not start this task until the enforcement backend is deployed.** Check
`docs/DEPLOYMENT.md`'s deploy log for a row whose targets include `functions`
at a commit at or after Phase 2. As of 2026-09-11 production runs `462a1907`
(2026-09-07) and the enforcement is **not live**.

- [ ] **Step 4.1: Re-run the read-only audit first**

```bash
node functions/scripts/audit-wave-contract.js --verbose
```

Record `scanned`, `refused` (blocking) and the advisory count. This is
Step 0.1 of the Phase 2 plan, re-stated here because it is the number the run
below is checked against. A blocking problem that appeared since 2026-09-10 is
a client that stops syncing the moment enforcement ships.

- [ ] **Step 4.2: Dry run, IMMEDIATELY before the live run**

```bash
node functions/scripts/backfill-wave-blocked.js --dry-run --verbose
```

**A dry-run count goes stale.** Any `clients` write fires `waveUpsertCustomer`,
which carries the `runWaveDaily` rider, which can write client docs — this is
exactly how the 2026-09-10 `backfill-search-tokens.js` dry run reported
`13 clients / 1 appointment` and the live run minutes later wrote 0. Read the
list, then run live without pausing.

Cross-check before proceeding: **the backfill's `blocked + advisory` must equal
the audit's `flagged`**. Two scans over the same contract; a disagreement means
the scan or the comparison is wrong, not the data.

- [ ] **Step 4.3: Live run**

```bash
node functions/scripts/backfill-wave-blocked.js --verbose
```

Expected against the 2026-09-10 replay: **725 scanned, 1 patched, 0 blocked,
1 advisory, 0 stale** — the advisory being `2wcEiCNztsWYUYNXYBEm`
(`phone:NOT_DIALABLE`). **0 patched is a red flag, not a success** — see the
correction at the top of this plan.

- [ ] **Step 4.4: Verify idempotence against prod**

```bash
node functions/scripts/backfill-wave-blocked.js --dry-run
```
Expected: `0 verdict rows patched`. A non-zero second run means the comparison
disagrees with what was written, and the difference is a write per client per
run forever.

- [ ] **Step 4.5: Verify in the app**

Open Settings → Wave. The advisory client appears in the problem list with its
field named, and the client's own page shows the same. That is the whole point
of the phase: a client nobody could ring was invisible, and is not any more.

- [ ] **Step 4.6: Record the run in the deploy log**

Add a row to `docs/DEPLOYMENT.md` — date, the tree it ran from, **prod scripts
only (no deploy target)**, the function count unchanged, and the four numbers
from Step 4.3 plus the Step 4.4 re-verification. That log is the authority the
plan docs point at; a run that is not in it did not happen as far as the next
operator is concerned.

- [ ] **Step 4.7: Commit the log**

```bash
git add docs/DEPLOYMENT.md
git commit -F- <<'MSG'
Record the Wave verdict backfill run

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CKMzxXKL8Q6UjvCfg1q3q6
MSG
```

---

## Verification

Run at the end of each task, not only at the end:

```bash
cd functions && npm run lint && npx jest
```

Nothing in this phase touches `lib/`, the ARBs, the rules or the indexes, so
`flutter analyze` / `flutter test` / `flutter gen-l10n` have nothing to say
about it — run them anyway before any commit that turns out to have touched
Dart, which would mean the change escaped this plan's scope.

**Never `--force` a Firebase deploy**, and clear `AI_AGENT`, `CLAUDECODE` and
`CLAUDE_CODE` from the shell before any `firebase` command
(`docs/DEPLOYMENT.md` §5). This phase has no deploy step of its own.

---

## What Phase 3 does NOT do

- It does not cancel queued jobs (decision 1).
- It does not un-block a stale `blocked` client (decision 2).
- It does not add a rule, a cap or a problem code. A new code is a change to
  `customer_contract.js` and to `WaveProblemCode.fromRaw`
  (`lib/features/wave/domain/models/wave_problem.dart`) in one commit — an
  unknown code parses to `WaveProblemCode.unknown` rather than being dropped,
  so a server-only addition renders as a problem with no explanation.
- It does not start Phase 4. `worker.js`'s split and the cadence removal wait
  until enforcement has run quietly for several days, and
  `waveSetImportSchedule`'s deletion is a `docs/DEPLOYMENT.md` §4a carve-out
  needing its own deploy.
