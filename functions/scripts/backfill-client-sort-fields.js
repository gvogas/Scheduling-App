#!/usr/bin/env node
// One-off: stamps `jobCount` and `createdAt` on every client doc missing
// either, so the Most jobs / Recently added sorts return the whole roster.
//
// Firestore `orderBy` returns only documents that HAVE the ordered field, so a
// client the recount trigger never stamped, or a pre-`createdAt` import, is in
// the list under Name and silently gone under the other two sorts.
//
// PREREQUISITE for the search-first clients release, not a follow-up — see
// docs/archive/2026-09-04-clients-page-search-first-implementation.md.
//
// Usage:
//   For prod:
//     export GOOGLE_APPLICATION_CREDENTIALS=/path/to/prod-service-account.json
//     node functions/scripts/backfill-client-sort-fields.js --dry-run
//     node functions/scripts/backfill-client-sort-fields.js
//
//   For the local emulator:
//     export FIRESTORE_EMULATOR_HOST=localhost:8080
//     export GCLOUD_PROJECT=schedulingapp-88727
//     node functions/scripts/backfill-client-sort-fields.js
//
//   Options:
//     --dry-run   report what would change, write nothing

const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {commitInBatches} = require("./_batch");
const {bootstrapScript} = require("./_project");
const {scanByName} = require("./_scan");
const {planClientSortPatch} = require("../client_sort_backfill_policy");

const BATCH_SIZE = 400;
const PAGE_SIZE = 500;
const EXACT_FLAGS = ["--dry-run"];

// Deliberately NOT serverTimestamp(): a client whose creation date was never
// recorded is not new, and stamping "now" would park the whole legacy roster
// at the top of Recently added. A fixed date before the app existed sorts them
// last, which is what "added before we tracked it" actually means.
const LEGACY_CREATED_AT = new Date("2020-01-01T00:00:00Z");

/**
 * Rejects any flag this script does not know.
 * @param {!Array<string>} argv Arguments after node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/**
 * Walks the clients collection and applies the patch each doc needs.
 * @param {!Object} db Firestore instance.
 * @param {boolean} dryRun Whether to write.
 * @return {!Promise<{scanned: number, patched: number}>}
 */
async function backfillClients(db, dryRun) {
  // Paged, never one `.get()` of the whole collection: a run that dies
  // part-way leaves a HALF-stamped collection, which from the app's side is
  // indistinguishable from one that was never backfilled at all.
  const writer = commitInBatches(db, {dryRun, batchSize: BATCH_SIZE});
  let scanned = 0;
  let patched = 0;
  for await (const doc of scanByName(
      db.collection("clients"), {pageSize: PAGE_SIZE})) {
    scanned += 1;
    const patch = planClientSortPatch(doc.data() || {}, LEGACY_CREATED_AT);
    if (!patch) continue;
    patched += 1;
    await writer.stage(doc.ref, patch);
  }
  await writer.flush();
  return {scanned, patched};
}

/**
 * Runs the backfill.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {db, dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const tag = dryRun ? "[dry-run] " : "";

  const clients = await backfillClients(db, dryRun);

  console.log(
      `${tag}clients: ${clients.scanned} scanned, ` +
      `${clients.patched} sort rows patched`);
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = {assertKnownFlags, backfillClients, LEGACY_CREATED_AT};
