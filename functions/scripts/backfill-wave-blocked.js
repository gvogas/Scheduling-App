#!/usr/bin/env node
// One-off: records the Wave customer contract's verdict on every client.
// RUN LAST: after the `blocked`-rendering app build and the enforcement deploy.
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

"use strict";

const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {commitInBatches} = require("./_batch");
const {bootstrapScript} = require("./_project");
const {scanByName} = require("./_scan");
const {buildCustomerPayload, verdictPatch} =
  require("../wave/customer_contract");

/** Bare switches, matched EXACTLY - see `_flags.js`. */
const EXACT_FLAGS = ["--dry-run", "--verbose"];

const BATCH_SIZE = 400;
const PAGE_SIZE = 500;

/**
 * Rejects any argument this script does not recognize.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/**
 * Whether two problem entries describe the same fault, `detail` included.
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
 * @param {*} stored The stored `wave.problems` value, possibly absent.
 * @param {!Array<!Object>} derived The contract's problems, in its order.
 * @return {boolean}
 */
function sameProblems(stored, derived) {
  const left = Array.isArray(stored) ? stored : [];
  const right = Array.isArray(derived) ? derived : [];
  if (left.length !== right.length) return false;
  return left.every((problem, i) => sameProblem(problem || {}, right[i]));
}

/**
 * The verdict for one client, and the patch to write for it (null for none).
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

/**
 * Replays the contract over every client and records the verdict.
 * @param {!Object} db The Firestore handle.
 * @param {{dryRun: boolean}} options Whether this run actually writes.
 * @return {!Promise<{scanned: number, patched: number, blocked: number,
 *   advisory: number, staleBlocked: number, changes: !Array<!Object>,
 *   staleBlockedIds: !Array<string>}>} The tally.
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

// Only run when invoked directly.
if (require.main === module) {
  main().catch((err) => {
    console.error(err && err.message ? err.message : err);
    process.exit(1);
  });
}

module.exports = {
  assertKnownFlags,
  backfillBlockedClients,
  changeFor,
  sameProblem,
  sameProblems,
  PAGE_SIZE,
};
