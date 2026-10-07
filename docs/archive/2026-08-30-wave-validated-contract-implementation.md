# Wave validated contract — Phase 1 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: PHASE 1 COMPLETE — every step including the replay.** Built and
deployed 2026-08-30 (`fe9edc51`, functions + rules + storage) in report-only
mode, and the production replay — the one step that stayed open for ten days for
want of credentials — **RAN 2026-09-09**:
`audit-wave-contract.js --verbose` against `schedulingapp-88727` scanned **724
clients, 0 blocking, 1 advisory** (`phone:NOT_DIALABLE` on the already-analyzed
`2wcEiCNztsWYUYNXYBEm`). The report is clean, so Phase 2 (enforce) is unblocked
and writable. Design doc:
`docs/plans/2026-08-30-wave-validated-contract-design.md`.

**Goal:** Build the Wave customer contract and run it in report-only mode, so
we learn what it would reject across ~700 real clients before it can reject
anything.

**Architecture:** A new pure module `functions/wave/customer_contract.js` answers
*"will Wave accept this client?"*, returning either a payload or a structured
list of problems. Phase 1 wires it in **additively**: the trigger records
`wave.problems` on the client doc but still enqueues exactly as it does today,
so behaviour is unchanged. A read-only script replays the contract against
production. Making the contract the *only* payload producer is Phase 2.

**Tech Stack:** Node 20 CommonJS, `firebase-admin`, `firebase-functions` v2,
Jest. ESLint `google` config — 80-column lines, double quotes, 2-space indent,
JSDoc required on every function.

**Design:** `docs/plans/2026-08-30-wave-validated-contract-design.md`

---

## Scope

Phase 1 of the design's four-step migration (design §7). Phases 2–4 (enforce,
backfill, refactors) get their own plans; Phase 2's shape depends on what this
phase's report reveals, which is the whole point of doing it first.

**This phase changes no behaviour.** Every client that syncs today still syncs.
The only observable difference is a new `wave.problems` field on client docs.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `functions/wave/customer_contract.js` | Owns "will Wave accept this client?". Pure, no I/O. | **Create** |
| `functions/__tests__/wave_customer_contract.test.js` | Contract rules + the historical-incident regression table. | **Create** |
| `functions/wave/triggers.js` | Merges the contract's patch into the existing batch. ~6 lines. | Modify |
| `functions/scripts/audit-wave-contract.js` | Read-only replay of the contract over production. | **Create** |
| `.claude/rules/wave.md` | Record the contract and report-only mode. | Modify |
| `docs/CLOUD_FUNCTIONS.md` | Note the new `wave.problems` field. | Modify |

`functions/wave/mappers.js` is **not** modified in this phase. The contract
consumes its existing public exports.

---

## Task 1: The contract module and the EMPTY rule

**Files:**
- Create: `functions/wave/customer_contract.js`
- Create: `functions/__tests__/wave_customer_contract.test.js`

- [ ] **Step 1: Write the failing test**

Create `functions/__tests__/wave_customer_contract.test.js`:

```js
"use strict";

const {buildCustomerPayload} = require("../wave/customer_contract");

/**
 * A client doc that the contract accepts, so each test can break exactly one
 * thing and attribute the problem to it.
 * @param {!Object=} over Fields to override.
 * @return {!Object} Client document fields.
 */
function client(over = {}) {
  return {
    name: "Vogas Plumbing",
    firstName: "",
    lastName: "",
    email: "",
    phone: "(514) 555-1234",
    mobile: "",
    address: "4450 Prom. Paton",
    addressLine2: "",
    apt: "",
    city: "Laval",
    province: "QC",
    country: "Canada",
    postalCode: "H7W 5J7",
    type: "commercial",
    ...over,
  };
}

describe("buildCustomerPayload", () => {
  test("accepts an ordinary client and returns a payload and a hash", () => {
    const out = buildCustomerPayload(client());
    expect(out.ok).toBe(true);
    expect(out.payload.name).toBe("Vogas Plumbing");
    expect(typeof out.hash).toBe("string");
    expect(out.hash).toHaveLength(64);
  });

  test("refuses a blank name", () => {
    // The 2026-08-30 dead-letter: composeStored's business branch reduced a
    // business named only by its own number to "", toWaveCustomerInput sends
    // `name` unconditionally, and Wave refuses a blank customer name. It was
    // non-retryable, so it died on every push forever.
    const out = buildCustomerPayload(client({name: ""}));
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual([
      {field: "name", code: "EMPTY", detail: null},
    ]);
    expect(out.payload).toBeUndefined();
  });

  test("refuses a whitespace-only name", () => {
    const out = buildCustomerPayload(client({name: "   "}));
    expect(out.ok).toBe(false);
    expect(out.problems[0]).toEqual(
        {field: "name", code: "EMPTY", detail: null});
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: FAIL — `Cannot find module '../wave/customer_contract'`.

- [ ] **Step 3: Write the minimal implementation**

Create `functions/wave/customer_contract.js`:

```js
"use strict";

/**
 * @fileoverview The single owner of "will Wave accept this client?".
 *
 * Every Wave incident on record has one root: the app sent a value Wave
 * refuses, found out at push time, and had no way back. `WaveValidationError`
 * is non-retryable by design, so "Retry failed" re-sends the identical payload
 * into the identical refusal. Wave was being used as the validator and its
 * "no" was permanent.
 *
 * This module moves that verdict to the boundary. It answers with either a
 * payload or a structured list of PROBLEMS naming the client-doc field at
 * fault, so a failure becomes something an admin can fix rather than a counter
 * in Settings.
 *
 * Pure and synchronous — no Firebase, no network. In PHASE 1 it is additive:
 * `wave/customers.js` still builds its own payload and nothing is blocked. It
 * becomes the only producer in Phase 2.
 *
 * Design: `docs/plans/2026-08-30-wave-validated-contract-design.md`.
 * @module wave/customer_contract
 */

const {toWaveCustomerInput, mappedFieldsHash} = require("./mappers");

/**
 * @typedef {{field: string, code: string, detail: ?Object}} WaveProblem
 *   `field` names the CLIENT DOC field an admin edits, never the Wave payload
 *   path — the UI points at an input with it.
 */

/**
 * Builds the Wave customer payload for a client, or says why it cannot.
 * @param {!Object} clientFields Firestore `clients` document fields.
 * @return {{ok: boolean, payload: (!Object|undefined),
 *   hash: (string|undefined), problems: (!Array<WaveProblem>|undefined)}}
 */
function buildCustomerPayload(clientFields) {
  const payload = toWaveCustomerInput(clientFields);
  const problems = [];

  if (!payload.name || !payload.name.trim()) {
    problems.push({field: "name", code: "EMPTY", detail: null});
  }

  if (problems.length > 0) return {ok: false, problems};
  return {ok: true, payload, hash: mappedFieldsHash(clientFields)};
}

module.exports = {
  buildCustomerPayload,
};
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Lint**

```bash
cd functions && npm run lint
```

Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add functions/wave/customer_contract.js \
        functions/__tests__/wave_customer_contract.test.js
git commit -m "feat(wave): add the customer contract with the empty-name rule"
```

---

## Task 2: The length rules

Two fields are permitted by `firestore.rules` at a length Wave refuses —
`name` at 225 against Wave's 200, and `address` at 533 against Wave's 500 —
and the push path caps nothing. This is the latent fourth incident.

Note the caps are checked against the **payload** values, not the raw doc
fields: `addressLine1` is `apt + address` joined, so it can exceed Wave's cap
even when both source fields are individually within it. The problem is
reported against the doc field an admin can edit.

**Files:**
- Modify: `functions/wave/customer_contract.js`
- Modify: `functions/__tests__/wave_customer_contract.test.js`

- [ ] **Step 1: Write the failing tests**

Append inside the `describe("buildCustomerPayload", ...)` block:

```js
  test("refuses a name past Wave's 200-character cap", () => {
    // firestore.rules permits 225 (sized for the old "<name> <phone>" shape,
    // and it must STAY there — a cap below a stored value makes that doc
    // permanently un-updatable). So the contract is what catches this.
    const out = buildCustomerPayload(client({name: "a".repeat(218)}));
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual([
      {field: "name", code: "TOO_LONG", detail: {length: 218, cap: 200}},
    ]);
  });

  test("accepts a name exactly at the cap", () => {
    expect(buildCustomerPayload(client({name: "a".repeat(200)})).ok)
        .toBe(true);
  });

  test("refuses an address past Wave's 500-character cap", () => {
    const out = buildCustomerPayload(client({address: "a".repeat(520)}));
    expect(out.ok).toBe(false);
    expect(out.problems).toEqual([
      {field: "address", code: "TOO_LONG", detail: {length: 520, cap: 500}},
    ]);
  });

  test("blames `address` when apt + address together exceed the cap", () => {
    // addressLine1 is the two joined, so each can be legal alone and the
    // composed line still refused. The admin edits `address`, so that is what
    // the problem names.
    const out = buildCustomerPayload(
        client({apt: "1108", address: "a".repeat(498)}));
    expect(out.ok).toBe(false);
    expect(out.problems[0].field).toBe("address");
    expect(out.problems[0].code).toBe("TOO_LONG");
  });

  test("reports every over-long field, not just the first", () => {
    const out = buildCustomerPayload(client({
      name: "a".repeat(201),
      city: "b".repeat(129),
    }));
    expect(out.ok).toBe(false);
    expect(out.problems.map((p) => p.field).sort()).toEqual(["city", "name"]);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: FAIL — 5 failures, each `expect(received).toBe(false)` receiving
`true`, because nothing checks length yet.

- [ ] **Step 3: Write the implementation**

In `functions/wave/customer_contract.js`, add above `buildCustomerPayload`:

```js
/**
 * Wave's own length caps, as PAYLOAD paths paired with the client-doc field an
 * admin would edit to fix them.
 *
 * The values mirror `IMPORT_FIELD_CAPS` (`wave/mappers.js`), which has always
 * applied them on the IMPORT direction only — `capped()` is called solely by
 * `fromWaveCustomer`. The push path capped nothing, which is what left a
 * 201–225 name and a 501–533 address able to dead-letter permanently.
 *
 * `provinceCode`/`countryCode` are absent deliberately: they are GraphQL
 * ENUMS, already membership-tested by `toProvinceCode`/`toCountryCode`, so a
 * length is meaningless for them.
 * @const {!Array<{path: !Array<string>, field: string, cap: number}>}
 */
const PAYLOAD_CAPS = [
  {path: ["name"], field: "name", cap: 200},
  {path: ["firstName"], field: "firstName", cap: 200},
  {path: ["lastName"], field: "lastName", cap: 200},
  {path: ["email"], field: "email", cap: 320},
  {path: ["phone"], field: "phone", cap: 32},
  {path: ["mobile"], field: "mobile", cap: 32},
  {path: ["address", "addressLine1"], field: "address", cap: 500},
  {path: ["address", "addressLine2"], field: "addressLine2", cap: 500},
  {path: ["address", "city"], field: "city", cap: 128},
  {path: ["address", "postalCode"], field: "postalCode", cap: 32},
];

/**
 * Reads a nested payload value, tolerating an absent branch.
 * @param {!Object} payload The Wave customer input.
 * @param {!Array<string>} path Property names, outermost first.
 * @return {*} The value, or undefined.
 */
function readPath(payload, path) {
  let cursor = payload;
  for (const key of path) {
    if (!cursor || typeof cursor !== "object") return undefined;
    cursor = cursor[key];
  }
  return cursor;
}

/**
 * Every field whose composed value exceeds Wave's cap.
 * @param {!Object} payload The Wave customer input.
 * @return {!Array<WaveProblem>}
 */
function overLongProblems(payload) {
  const problems = [];
  for (const rule of PAYLOAD_CAPS) {
    const value = readPath(payload, rule.path);
    if (typeof value !== "string" || value.length <= rule.cap) continue;
    problems.push({
      field: rule.field,
      code: "TOO_LONG",
      detail: {length: value.length, cap: rule.cap},
    });
  }
  return problems;
}
```

Then, inside `buildCustomerPayload`, after the name check:

```js
  problems.push(...overLongProblems(payload));
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Lint and commit**

```bash
cd functions && npm run lint
cd .. && git add functions/wave/customer_contract.js \
        functions/__tests__/wave_customer_contract.test.js
git commit -m "feat(wave): cap push-path fields at Wave's own limits"
```

---

## Task 3: The email and phone rules

**Files:**
- Modify: `functions/wave/customer_contract.js`
- Modify: `functions/__tests__/wave_customer_contract.test.js`

- [ ] **Step 1: Write the failing tests**

Append inside the same `describe` block:

```js
  test("refuses an email Wave would reject", () => {
    for (const email of ["nope", "a@b", "a b@example.com", "@example.com"]) {
      const out = buildCustomerPayload(client({email}));
      expect(out.ok).toBe(false);
      expect(out.problems[0])
          .toEqual({field: "email", code: "INVALID_EMAIL", detail: null});
    }
  });

  test("accepts ordinary and plus-addressed email", () => {
    for (const email of ["marc@example.com", "marc+wave@sub.example.co.uk"]) {
      expect(buildCustomerPayload(client({email})).ok).toBe(true);
    }
  });

  test("an absent email is not a problem", () => {
    // `presence` omits an empty optional, so there is nothing to validate.
    expect(buildCustomerPayload(client({email: ""})).ok).toBe(true);
  });

  test("refuses a phone carrying no digits at all", () => {
    const out = buildCustomerPayload(client({phone: "call the office"}));
    expect(out.ok).toBe(false);
    expect(out.problems[0])
        .toEqual({field: "phone", code: "INVALID_PHONE", detail: null});
  });

  test("accepts every phone shape the app legitimately stores", () => {
    // The formatted NANP form, the bare form, an international number and an
    // extension all reach Wave today and are accepted.
    for (const phone of ["(514) 555-1234", "5145551234", "+33 1 42 68 53 00",
      "514-555-1234 x22"]) {
      expect(buildCustomerPayload(client({phone})).ok).toBe(true);
    }
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: FAIL — the two "refuses" tests fail (`true` received where `false`
expected). The three "accepts" tests already pass.

- [ ] **Step 3: Write the implementation**

In `functions/wave/customer_contract.js`, add above `buildCustomerPayload`:

```js
/**
 * A deliberately loose email shape: a local part, one `@`, a dotted domain,
 * and no whitespace.
 *
 * Wave is the authority on what it accepts, and this is not trying to be a
 * second one — it catches the obvious refusals BEFORE they become a permanent
 * dead-letter. A false accept simply behaves as it does today; a false REJECT
 * would block a client that syncs fine, so this errs loose on purpose.
 * @const {!RegExp}
 */
const EMAIL_SHAPE = /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/;

/** Any decimal digit. @const {!RegExp} */
const HAS_DIGIT = /\d/;

/**
 * Problems with the payload's contact fields.
 * @param {!Object} payload The Wave customer input.
 * @return {!Array<WaveProblem>}
 */
function contactProblems(payload) {
  const problems = [];
  if (typeof payload.email === "string" && !EMAIL_SHAPE.test(payload.email)) {
    problems.push({field: "email", code: "INVALID_EMAIL", detail: null});
  }
  // A number with no digit in it cannot be dialled and Wave refuses it. The
  // shape is otherwise left alone: the app legitimately stores international
  // and extension forms that no NANP pattern would match.
  for (const field of ["phone", "mobile"]) {
    const value = payload[field];
    if (typeof value !== "string" || HAS_DIGIT.test(value)) continue;
    problems.push({field, code: "INVALID_PHONE", detail: null});
  }
  return problems;
}
```

Then, inside `buildCustomerPayload`, after the `overLongProblems` line:

```js
  problems.push(...contactProblems(payload));
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: PASS, 13 tests.

- [ ] **Step 5: Lint and commit**

```bash
cd functions && npm run lint
cd .. && git add functions/wave/customer_contract.js \
        functions/__tests__/wave_customer_contract.test.js
git commit -m "feat(wave): reject unusable email and phone before Wave does"
```

---

## Task 4: Pin the historical incidents as named regressions

The contract's value is that a past incident cannot return anonymously. This
task adds no production code — it adds the regression table.

`CA-NY` is included even though `toProvinceCode` already prevents it: the
contract now owns payload production, and this is the test that fails if that
guarantee is ever weakened.

**Files:**
- Modify: `functions/__tests__/wave_customer_contract.test.js`

- [ ] **Step 1: Write the tests**

Append at the end of the file, as a new top-level block:

```js
describe("historical incidents", () => {
  // Each case dead-lettered a real client permanently in production. They are
  // named so a regression cannot come back anonymously.

  test("2026-08-15: a New York client is never sent as CA-NY", () => {
    // provinceCode had an unconditional `CA-` prefix, so a US client shipped
    // as a subdivision of nowhere. Enums are not an inputErrors entry — the
    // whole $input fails to coerce, arriving as a non-retryable
    // WaveApiError(graphql). Nothing recovered it.
    const out = buildCustomerPayload(client({
      city: "Brooklyn", province: "NY", country: "United States",
      postalCode: "11201",
    }));
    expect(out.ok).toBe(true);
    expect(out.payload.address.countryCode).toBe("US");
    expect(out.payload.address.provinceCode).toBe("US-NY");
  });

  test("2026-08-15: an unknown province is omitted, never guessed", () => {
    const out = buildCustomerPayload(client({province: "Ontari"}));
    expect(out.ok).toBe(true);
    expect(out.payload.address.provinceCode).toBeUndefined();
  });

  test("2026-08-30: a business named only by its phone is refused", () => {
    // Client o0KcOnJSgjvMHYpmcZ44. `type: building` with a name that
    // composeStored had reduced to "". Wave refuses a blank customer name.
    const out = buildCustomerPayload(client({
      name: "", firstName: "", lastName: "", type: "building",
      phone: "(514) 458-6186",
    }));
    expect(out.ok).toBe(false);
    expect(out.problems).toContainEqual(
        {field: "name", code: "EMPTY", detail: null});
  });

  test("latent: a legacy 225-character name is refused, not dead-lettered",
      () => {
        const out = buildCustomerPayload(client({name: "a".repeat(225)}));
        expect(out.ok).toBe(false);
        expect(out.problems).toContainEqual({
          field: "name", code: "TOO_LONG", detail: {length: 225, cap: 200},
        });
      });

  test("latent: a legacy 533-character address is refused", () => {
    const out = buildCustomerPayload(client({address: "a".repeat(533)}));
    expect(out.ok).toBe(false);
    expect(out.problems).toContainEqual({
      field: "address", code: "TOO_LONG", detail: {length: 533, cap: 500},
    });
  });
});
```

- [ ] **Step 2: Run the tests**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: PASS, 18 tests. All five should pass without production changes — if
the `CA-NY` case fails, `toProvinceCode`'s membership test has regressed and
that is a real finding, not a test bug.

- [ ] **Step 3: Commit**

```bash
git add functions/__tests__/wave_customer_contract.test.js
git commit -m "test(wave): pin every historical Wave incident by name"
```

---

## Task 5: Report-only recording

The trigger has **no test file**, and `onDocumentWritten` is awkward to drive
directly. So the decision goes in a pure function the contract owns and the
trigger stays thin — the same split `maintenance_policy.js` ↔ `maintenance.js`
already uses.

**Files:**
- Modify: `functions/wave/customer_contract.js`
- Modify: `functions/__tests__/wave_customer_contract.test.js`
- Modify: `functions/wave/triggers.js:126-131`

- [ ] **Step 1: Write the failing tests**

Append to `functions/__tests__/wave_customer_contract.test.js`:

```js
const {problemsPatch} = require("../wave/customer_contract");

describe("problemsPatch", () => {
  test("records the problems when a client cannot be sent", () => {
    expect(problemsPatch(client({name: ""}))).toEqual({
      "wave.problems": [{field: "name", code: "EMPTY", detail: null}],
    });
  });

  test("clears the field when a client is fine", () => {
    // Explicitly null rather than omitted: a client REPAIRED since the last
    // write must not keep stale problems on its doc.
    expect(problemsPatch(client())).toEqual({"wave.problems": null});
  });

  test("is a plain patch with no other keys", () => {
    // Phase 1 is report-only. It must not touch syncState, and the enqueue
    // decision stays exactly where it is.
    expect(Object.keys(problemsPatch(client({name: ""})))).toEqual(
        ["wave.problems"]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: FAIL — `problemsPatch is not a function`.

- [ ] **Step 3: Implement `problemsPatch`**

In `functions/wave/customer_contract.js`, add before `module.exports`:

```js
/**
 * The Firestore patch recording a client's contract problems.
 *
 * PHASE 1 IS REPORT-ONLY: this records what the contract WOULD refuse and
 * changes nothing else. The job is still enqueued, the push still runs, and
 * `wave.syncState` is untouched. The point is to learn what the contract
 * flags across every real client before it is able to block one.
 *
 * Always returns the key, `null` when there is nothing wrong — a client
 * repaired since the last write must not keep stale problems on its doc.
 * @param {!Object} clientFields Firestore `clients` document fields.
 * @return {!Object} A patch to merge into a client-doc update.
 */
function problemsPatch(clientFields) {
  const result = buildCustomerPayload(clientFields);
  return {"wave.problems": result.ok ? null : result.problems};
}
```

And add it to the exports:

```js
module.exports = {
  buildCustomerPayload,
  problemsPatch,
};
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd functions && npx jest __tests__/wave_customer_contract.test.js
```

Expected: PASS, 21 tests.

- [ ] **Step 5: Wire it into the trigger**

In `functions/wave/triggers.js`, add to the requires near line 31:

```js
const {problemsPatch} = require("./customer_contract");
```

Then replace the batch update at lines 126–131. **From:**

```js
      const batch = db.batch();
      batch.update(db.doc("clients/" + clientId), {
        "wave.syncState": "pending",
        "wave.syncError": null,
      });
```

**To:**

```js
      const batch = db.batch();
      // `wave.problems` rides the batch that was already updating this doc, so
      // report-only costs no extra write. It is NOT a mapped field, so the
      // hash is unchanged and `shouldEnqueueClientWrite` returns false when
      // the trigger re-fires on this write — the same protection the
      // mark-pending update above already relies on, and the reason this
      // cannot loop.
      batch.update(db.doc("clients/" + clientId), {
        "wave.syncState": "pending",
        "wave.syncError": null,
        ...problemsPatch(after),
      });
```

- [ ] **Step 6: Run the full Wave suite to prove nothing regressed**

```bash
cd functions && npx jest __tests__/wave_
```

Expected: PASS, all Wave suites. Behaviour is unchanged, so no existing
expectation should move.

- [ ] **Step 7: Lint and commit**

```bash
cd functions && npm run lint
cd .. && git add functions/wave/customer_contract.js functions/wave/triggers.js \
        functions/__tests__/wave_customer_contract.test.js
git commit -m "feat(wave): record contract problems in report-only mode"
```

---

## Task 6: The conformance script

This is how incident #4 gets found before a customer finds it. Read-only.

**Files:**
- Create: `functions/scripts/audit-wave-contract.js`

- [ ] **Step 1: Write the script**

Create `functions/scripts/audit-wave-contract.js`:

```js
#!/usr/bin/env node
// One-off, READ-ONLY: replays the Wave customer contract over every client and
// reports what it would refuse.
//
// WHY: every Wave incident on record was a value Wave refused, discovered at
// push time, where the rejection is non-retryable and therefore permanent.
// This is the check that moves that discovery before the deploy. Run it after
// any change to the contract, the mappers, or ClientNamePolicy.
//
// It writes NOTHING. Safe against production at any time.
//
// Usage:
//   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/prod-service-account.json
//   node functions/scripts/audit-wave-contract.js
//   node functions/scripts/audit-wave-contract.js --verbose
//
//   --verbose  lists every affected client id and its problems, not just the
//              per-code tally.

"use strict";

const {initializeApp, applicationDefault} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {printTargetBanner} = require("./_project");
const {buildCustomerPayload} = require("../wave/customer_contract");

const EXACT_FLAGS = ["--verbose"];

/**
 * Rejects any argument this script does not recognize. The rule itself lives
 * in the shared `_flags.js` — this wrapper only supplies the flag list.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/** Read-only, so this is a round-trip dial rather than a write bound. */
const PAGE_SIZE = 500;

/**
 * Replays the contract over every client document.
 * @param {!Object} db The Firestore handle.
 * @return {!Promise<{scanned: number, refused: number,
 *   byCode: !Object<string, number>, offenders: !Array<!Object>}>} The tally.
 */
async function audit(db) {
  const byCode = {};
  const offenders = [];
  let scanned = 0;
  let cursor = null;

  // Paged on `__name__` so this needs no index and no orderBy field, which
  // matters: an orderBy makes Firestore EXCLUDE any doc missing that field,
  // and a legacy doc missing one is exactly the shape most likely to fail.
  for (;;) {
    let query = db.collection("clients").orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      scanned += 1;
      const result = buildCustomerPayload(doc.data() || {});
      if (result.ok) continue;
      offenders.push({id: doc.id, problems: result.problems});
      for (const problem of result.problems) {
        const key = `${problem.field}:${problem.code}`;
        byCode[key] = (byCode[key] || 0) + 1;
      }
    }

    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE_SIZE) break;
  }

  return {scanned, refused: offenders.length, byCode, offenders};
}

/**
 * Entry point.
 * @return {!Promise<void>}
 */
async function main() {
  assertKnownFlags(process.argv.slice(2));
  const verbose = process.argv.includes("--verbose");

  const app = initializeApp({credential: applicationDefault()});
  printTargetBanner(app);
  const db = getFirestore();

  const {scanned, refused, byCode, offenders} = await audit(db);

  console.log(`\nScanned ${scanned} clients.`);
  console.log(`${refused} would be REFUSED by Wave.\n`);

  const keys = Object.keys(byCode).sort();
  if (keys.length === 0) {
    console.log("  No client fails the contract.");
  } else {
    for (const key of keys) console.log(`  ${key}: ${byCode[key]}`);
  }

  if (verbose && offenders.length > 0) {
    console.log("\nAffected clients:");
    for (const {id, problems} of offenders) {
      const summary = problems
          .map((p) => `${p.field}:${p.code}`)
          .join(", ");
      console.log(`  ${id}  ${summary}`);
    }
  }

  await app.delete();
}

main().catch((err) => {
  console.error(err && err.message ? err.message : err);
  process.exit(1);
});
```

- [ ] **Step 2: Verify it lints**

```bash
cd functions && npm run lint
```

Expected: no output (clean).

- [ ] **Step 3: Verify the flag guard rejects a typo**

```bash
cd functions && node scripts/audit-wave-contract.js --dryrun
```

Expected: exits non-zero complaining about the unknown argument, **before**
touching credentials or Firestore.

- [ ] **Step 4: Commit**

```bash
git add functions/scripts/audit-wave-contract.js
git commit -m "feat(wave): add a read-only contract conformance audit"
```

---

## Task 7: Documentation

**Files:**
- Modify: `.claude/rules/wave.md`
- Modify: `docs/CLOUD_FUNCTIONS.md`

- [ ] **Step 1: Add the contract to the Wave rules**

Append to `.claude/rules/wave.md`:

```markdown
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
  **PHASE 1 IS REPORT-ONLY.** `problemsPatch` rides the trigger's existing
  mark-pending batch and records `wave.problems`; nothing is blocked and the
  enqueue decision is untouched. `wave.problems` is not a mapped field, so the
  hash is unchanged and `shouldEnqueueClientWrite` stops the re-fire — the same
  protection mark-pending relies on. The contract becomes the ONLY payload
  producer in Phase 2; until then `wave/customers.js` still builds its own.
  `functions/scripts/audit-wave-contract.js` replays it over production,
  read-only. Run it after any change to the contract, the mappers, or
  `ClientNamePolicy`. Design:
  `docs/plans/2026-08-30-wave-validated-contract-design.md`.
```

- [ ] **Step 2: Note the new field in the functions reference**

In `docs/CLOUD_FUNCTIONS.md`, in the `waveUpsertCustomer` entry, add:

```markdown
Also records `wave.problems` on the client doc — the contract's verdict on
whether Wave would accept it (`wave/customer_contract.js`). Report-only in
Phase 1: nothing is blocked by it yet.
```

- [ ] **Step 3: Commit**

```bash
git add .claude/rules/wave.md docs/CLOUD_FUNCTIONS.md
git commit -m "docs(wave): record the customer contract and report-only mode"
```

---

## Task 8: Full verification

- [ ] **Step 1: Run the whole functions suite**

```bash
cd functions && npx jest
```

Expected: PASS. Baseline before this plan is **1540 tests**; this adds 21, so
expect **1561 passing**, 0 failing.

- [ ] **Step 2: Lint**

```bash
cd functions && npm run lint
```

Expected: no output.

- [ ] **Step 3: Confirm the Flutter side is untouched**

```bash
cd .. && flutter analyze
```

Expected: `No issues found!` — this phase changes no Dart.

---

## Deploy and the report

Not a code task, but the point of the phase.

- [ ] **Step 1: Deploy the backend**

Per `docs/DEPLOYMENT.md`. Clear `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` first.

```bash
firebase deploy --only functions
```

Only `waveUpsertCustomer` changes. No rules, no indexes, no callable payload
shapes — so there is no app-build ordering constraint this time.

- [ ] **Step 2: Run the audit against production**

```bash
cd functions && node scripts/audit-wave-contract.js --verbose
```

- [ ] **Step 3: Read the report before writing Phase 2**

The per-code tally is Phase 2's input. Specifically:

- **Codes with a high count** may indicate a contract rule that is too strict
  rather than a fleet of broken clients. Loosen the rule; do not blocklist 200
  customers.
- **`name:EMPTY`** should be a very small number. Each is a real client that
  cannot sync today.
- **Zero refusals** would mean the contract is not yet earning its keep, and
  Phase 2 should start by widening the rules rather than enforcing them.

Do not proceed to enforcement until this report has been read.
