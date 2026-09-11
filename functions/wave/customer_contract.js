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
 * Pure and synchronous — no Firebase, no network. Since Phase 2 it is the ONLY
 * producer of a Wave customer payload, and a client it refuses never becomes a
 * queued job.
 *
 * Design: `docs/plans/2026-08-30-wave-validated-contract-design.md`.
 * @module wave/customer_contract
 */

const {IMPORT_FIELD_CAPS, toWaveCustomerInput, mappedFieldsHash} =
  require("./mappers");

/**
 * @typedef {{field: string, code: string, severity: string,
 *   detail: ?Object}} WaveProblem
 *   `field` names the CLIENT DOC field an admin edits, never the Wave payload
 *   path — the UI points at an input with it.
 *
 *   `severity` is `"blocking"` or `"advisory"`, and the split is load-bearing.
 *   Two different questions were competing for one verdict:
 *
 *     - BLOCKING — "Wave will refuse this." Never enqueue it; the push would
 *       dead-letter permanently.
 *     - ADVISORY — "Wave accepts this, but the data is wrong." Report it,
 *       surface it, and push anyway.
 *
 *   Collapsing them costs a real failure in each direction. Treating every
 *   problem as blocking stops a client Wave is happy with from syncing at all
 *   (client `2wcEiCNztsWYUYNXYBEm`, below). Treating none as blocking puts the
 *   permanent dead-letter back. Only `blocking` decides `ok`.
 */

/**
 * The cap `IMPORT_FIELD_CAPS` registers for one client-doc field.
 *
 * Throws at REQUIRE time rather than returning undefined, and that is the
 * point: `overLongProblems` compares `value.length <= rule.cap`, which is
 * false for an undefined cap — so a field renamed in `mappers.js` would not
 * go uncapped, it would report EVERY client as `TOO_LONG` with `cap:
 * undefined`. Report-only today, but `blocking` in Phase 2, where that is
 * every client refused. A rename has to fail the deploy, not the data.
 * @param {string} field Client document field name.
 * @return {number}
 */
function importCap(field) {
  const cap = IMPORT_FIELD_CAPS[field];
  if (typeof cap !== "number") {
    throw new Error(
        `PAYLOAD_CAPS: no IMPORT_FIELD_CAPS entry for "${field}"`);
  }
  return cap;
}

/**
 * Wave's own length caps, as PAYLOAD paths paired with the client-doc field an
 * admin would edit to fix them.
 *
 * The numbers are READ from `IMPORT_FIELD_CAPS` (`wave/mappers.js`), never
 * restated here. That map has always applied them on the IMPORT direction only
 * — `capped()` is called solely by `fromWaveCustomer` — while the push path
 * capped nothing, which is what left a 201-225 name and a 501-533 address able
 * to dead-letter permanently. Two directions, one set of caps: a second
 * hand-written list is exactly the contract-versus-reality drift this module
 * exists to close, and it would drift silently, since nothing tests one list
 * against the other.
 *
 * `provinceCode`/`countryCode` are absent deliberately: they are GraphQL
 * ENUMS, already membership-tested by `toProvinceCode`/`toCountryCode`, so a
 * length is meaningless for them.
 * @const {!Array<{path: !Array<string>, field: string, cap: number}>}
 */
const PAYLOAD_CAPS = [
  {path: ["name"], field: "name", cap: importCap("name")},
  {path: ["firstName"], field: "firstName", cap: importCap("firstName")},
  {path: ["lastName"], field: "lastName", cap: importCap("lastName")},
  {path: ["email"], field: "email", cap: importCap("email")},
  {path: ["phone"], field: "phone", cap: importCap("phone")},
  // Borrows `phone`'s cap on purpose: `IMPORT_FIELD_CAPS` has no `mobile`
  // entry because the import folds Wave's mobile into the one `phone` field,
  // but the PUSH direction sends both, and they are the same Wave field type.
  {path: ["mobile"], field: "mobile", cap: importCap("phone")},
  {
    path: ["address", "addressLine1"],
    field: "address",
    cap: importCap("address"),
  },
  {
    path: ["address", "addressLine2"],
    field: "addressLine2",
    cap: importCap("addressLine2"),
  },
  {path: ["address", "city"], field: "city", cap: importCap("city")},
  {
    path: ["address", "postalCode"],
    field: "postalCode",
    cap: importCap("postalCode"),
  },
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
      severity: "blocking",
      detail: {length: value.length, cap: rule.cap},
    });
  }
  return problems;
}

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
 *
 * `NOT_DIALABLE` is ADVISORY, and the first production conformance run is
 * exactly why. Client `2wcEiCNztsWYUYNXYBEm` stores a person's NAME in
 * `phone` — typed into the wrong box; "Contact Person" stands in for it here
 * and in the tests, because the real one is a customer's name and PII does
 * not belong in source or in git history — and
 * Wave has that client **synced**, with that string as the customer's phone
 * number. So Wave plainly does not refuse it, and blocking the sync over it
 * would strand a customer Wave is happy with.
 *
 * But it is still WRONG: nothing can dial it, and that client has no reachable
 * number. Nothing else in the system catches this — `ClientFormValidator` says
 * so in its own comment ("phone/mobile aren't format-checked at all"), the
 * rules only bound length, and no other check exists. Advisory is what lets
 * both facts be true at once: the push proceeds, and the problem is on record.
 *
 * The code is deliberately NOT `INVALID_PHONE`. That name asserts something
 * about Wave's opinion, and Wave's opinion is that it is fine; this is a claim
 * about whether a human can ring it. Wave *can* emit `INVALID_PHONE` (it is in
 * `ERROR_CODE_MESSAGES`, and `createCustomerWithPhoneFallback` exists for it),
 * so a BLOCKING phone rule may be warranted one day — write it from an
 * observed rejection, never a plausible one, which is how this one got its
 * severity wrong to begin with.
 *
 * The shape check stays deliberately weak: only "carries no digit at all".
 * The app legitimately stores international forms and extensions that no
 * stricter pattern would match, and an advisory that cries wolf gets ignored,
 * which costs more than it saves.
 *
 * `INVALID_EMAIL` stays BLOCKING: no client trips it, so nothing disproves it,
 * and a malformed address is a far more standard refusal. It is still unproven
 * against Wave — if real data ever contradicts it, demote it the same way.
 * @param {!Object} payload The Wave customer input.
 * @return {!Array<WaveProblem>}
 */
function contactProblems(payload) {
  const problems = [];
  if (typeof payload.email === "string" && !EMAIL_SHAPE.test(payload.email)) {
    problems.push({
      field: "email", code: "INVALID_EMAIL",
      severity: "blocking", detail: null,
    });
  }
  for (const field of ["phone", "mobile"]) {
    const value = payload[field];
    if (typeof value !== "string" || HAS_DIGIT.test(value)) continue;
    problems.push({
      field, code: "NOT_DIALABLE",
      severity: "advisory", detail: null,
    });
  }
  return problems;
}

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
    problems.push({
      field: "name", code: "EMPTY", severity: "blocking", detail: null,
    });
  }
  problems.push(...overLongProblems(payload));
  problems.push(...contactProblems(payload));

  // ONLY a blocking problem withholds the payload. An advisory one rides along
  // on a perfectly good result — the push proceeds and the problem is still
  // reported, which is the whole reason the severities are split.
  if (problems.some((p) => p.severity === "blocking")) {
    return {ok: false, problems};
  }
  return {ok: true, payload, hash: mappedFieldsHash(clientFields), problems};
}

/**
 * The blocking subset of a problem list.
 *
 * One owner for the `severity === "blocking"` test. `buildCustomerPayload`
 * spells it inline to decide `ok`, and the enqueue gate, the dispatcher and
 * the import each need the same question answered — four spellings of one
 * predicate is how a severity stops meaning the same thing everywhere.
 * @param {?Array<WaveProblem>=} problems Problems, or nothing.
 * @return {!Array<WaveProblem>} Only the blocking ones.
 */
function blockingProblems(problems) {
  if (!Array.isArray(problems)) return [];
  return problems.filter((p) => p.severity === "blocking");
}

/**
 * The Firestore patch recording a client's contract verdict.
 *
 * Records BOTH severities. An advisory problem does not stop the push, but the
 * admin still has to be able to see it — a client nobody can ring is worth
 * showing even though Wave took it happily.
 *
 * Always returns `wave.problems`, `null` when there is nothing wrong — a
 * client repaired since the last write must not keep stale problems on its
 * doc. `syncState` is only touched when the contract REFUSES: a clean client's
 * state is owned by the push (`pending` → `synced` / `error`), and stamping it
 * here would fight the worker for it.
 * @param {!Object} clientFields Firestore `clients` document fields.
 * @param {{clearedState: string}=} opts State to write when nothing blocks;
 *   omit to leave `syncState` alone.
 * @return {!Object} A patch of DOTTED keys, safe to merge into a client-doc
 *   update without replacing sibling `wave` keys.
 */
function statePatch(clientFields, opts) {
  const {problems} = buildCustomerPayload(clientFields);
  const found = Array.isArray(problems) ? problems : [];
  const patch = {"wave.problems": found.length > 0 ? found : null};
  if (blockingProblems(found).length > 0) {
    patch["wave.syncState"] = "blocked";
    // A refused client never reaches Wave, so any error left from an earlier
    // push describes a push that will not be retried.
    patch["wave.syncError"] = null;
  } else if (opts && opts.clearedState) {
    patch["wave.syncState"] = opts.clearedState;
    patch["wave.syncError"] = null;
  }
  return patch;
}

/**
 * Whether the contract refuses this client outright.
 * @param {!Object} clientFields Firestore `clients` document fields.
 * @return {boolean} True when Wave would refuse it.
 */
function isBlocked(clientFields) {
  return buildCustomerPayload(clientFields).ok === false;
}

module.exports = {
  buildCustomerPayload,
  blockingProblems,
  statePatch,
  isBlocked,
};
