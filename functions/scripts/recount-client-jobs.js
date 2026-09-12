#!/usr/bin/env node
// One-off: recomputes `clients/{id}.jobCount` for every client, so the count
// stops including cancelled visits.
//
// `jobCount` is maintained lazily — a client self-heals only on its NEXT
// appointment write — so every client with an existing cancelled visit keeps an
// inflated count indefinitely, including its position under the Most jobs sort.
// That makes this a PREREQUISITE for the release that ships the corrected
// aggregate, not a follow-up.
//
// It recomputes through `countJobsFor`, the same function the trigger uses, so
// the backfill cannot disagree with the trigger about what a job is.
//
// Usage:
//   For prod:
//     export GOOGLE_APPLICATION_CREDENTIALS=/path/to/prod-service-account.json
//     node functions/scripts/recount-client-jobs.js --dry-run
//     node functions/scripts/recount-client-jobs.js
//
//   For the local emulator:
//     export FIRESTORE_EMULATOR_HOST=localhost:8080
//     export GCLOUD_PROJECT=schedulingapp-88727
//     node functions/scripts/recount-client-jobs.js
//
//   Options:
//     --dry-run   report what would change, write nothing
//     --verbose   print every client it would patch, old -> new

const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {commitInBatches} = require("./_batch");
const {bootstrapScript} = require("./_project");
const {scanByName} = require("./_scan");
const {countJobsFor} = require("../client_job_count");

const BATCH_SIZE = 400;
const PAGE_SIZE = 500;
const EXACT_FLAGS = ["--dry-run", "--verbose"];

/**
 * Rejects any flag this script does not know.
 * @param {!Array<string>} argv Arguments after node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/**
 * The stored count as a number, or null when the field is absent or junk.
 *
 * Absent is NOT zero: a client the trigger has never stamped renders no count
 * at all, and telling the two apart is what keeps the dry run's numbers
 * meaningful.
 * @param {!Object} data Client document fields.
 * @return {?number}
 */
function storedCountOf(data) {
  const raw = data.jobCount;
  return typeof raw === "number" && Number.isFinite(raw) ? raw : null;
}

/**
 * Recomputes every client's `jobCount`, writing only the ones that moved.
 *
 * Idempotent by comparison: a re-run patches nothing, which is what makes a
 * second run free and the dry run's count honest.
 * @param {!Object} db Firestore instance.
 * @param {{dryRun: boolean, verbose: boolean}} opts Run options.
 * @return {!Promise<{scanned: number, patched: number}>}
 */
async function recountClients(db, {dryRun, verbose}) {
  // Paged, never one `.get()` of the whole collection: a run that dies
  // part-way leaves a half-corrected collection, and nothing on screen says
  // which half.
  const writer = commitInBatches(db, {dryRun, batchSize: BATCH_SIZE});
  let scanned = 0;
  let patched = 0;
  for await (const doc of scanByName(
      db.collection("clients"), {pageSize: PAGE_SIZE})) {
    scanned += 1;
    const stored = storedCountOf(doc.data() || {});
    // One aggregate group per client, run serially with the paged scan rather
    // than fanned out: this walks the whole roster, and a Promise.all over it
    // would open ~4x that many concurrent aggregates at once.
    const actual = await countJobsFor(db, doc.id);
    if (stored === actual) continue;
    patched += 1;
    if (verbose) {
      console.log(`  ${doc.id}: ${stored === null ? "unset" : stored} -> ` +
        `${actual}`);
    }
    await writer.stage(doc.ref, {jobCount: actual});
  }
  await writer.flush();
  return {scanned, patched};
}

/**
 * Runs the recount.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {db, dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const verbose = argv.includes("--verbose");
  const tag = dryRun ? "[dry-run] " : "";

  const clients = await recountClients(db, {dryRun, verbose});

  console.log(
      `${tag}clients: ${clients.scanned} scanned, ` +
      `${clients.patched} job counts patched`);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = {assertKnownFlags, recountClients, storedCountOf};
