#!/usr/bin/env node
// One-off: repairs Places mojibake (`Calixa-Lavallã©E` → `Calixa-Lavallée`)
// already stored on /clients address fields, and rebuilds `searchTokens` so
// the client is findable under the corrected spelling.
//
// Only the address fields Places fills are touched; names are never rewritten.
// Idempotent: a repaired value no longer matches, so a re-run writes nothing.
//
// Each write fires `propagateClientEdits` (FUTURE appointments still carrying
// the old address follow it) and `waveUpsertCustomer` (Wave gets the fix).
//
// Usage:
//   $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\path\to\prod-sa.json"
//   node functions/scripts/repair-client-address-mojibake.js --dry-run
//   node functions/scripts/repair-client-address-mojibake.js
//
// Add --verbose to either to print every field it changes.
//
// AN UNKNOWN ARGUMENT IS A HARD ERROR — see `_flags.js`.

const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {bootstrapScript} = require("./_project");
const {commitInBatches} = require("./_batch");
const {scanByName} = require("./_scan");
const {repairMojibake} = require("../mojibake");
const {clientSearchTokens} = require("../search_tokens");

const EXACT_FLAGS = ["--dry-run", "--verbose"];
const BATCH_SIZE = 400;
const PAGE_SIZE = 500;

const ADDRESS_FIELDS = [
  "address",
  "addressLine2",
  "city",
  "province",
  "postalCode",
  "country",
];

/**
 * Rejects any argument that is not a flag this script knows.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/**
 * The repair patch for one client, or null when no address field is corrupt.
 * @param {?Object} data The stored client document.
 * @return {?Object} Repaired fields plus rebuilt `searchTokens`.
 */
function repairPatchFor(data) {
  const d = data || {};
  const patch = {};
  for (const field of ADDRESS_FIELDS) {
    if (typeof d[field] !== "string") continue;
    const repaired = repairMojibake(d[field]);
    if (repaired !== d[field]) patch[field] = repaired;
  }
  if (Object.keys(patch).length === 0) return null;
  patch.searchTokens = clientSearchTokens({...d, ...patch});
  return patch;
}

/**
 * Scans every client and repairs the corrupt ones.
 * @param {!Object} db Firestore instance.
 * @param {{dryRun: boolean, verbose: boolean}} options Run options.
 * @return {!Promise<{scanned: number, patched: number}>}
 */
async function repairClients(db, {dryRun, verbose}) {
  const writer = commitInBatches(db, {dryRun, batchSize: BATCH_SIZE});
  let scanned = 0;
  let patched = 0;
  for await (const doc of scanByName(
      db.collection("clients"), {pageSize: PAGE_SIZE})) {
    scanned += 1;
    const data = doc.data() || {};
    const patch = repairPatchFor(data);
    if (!patch) continue;
    patched += 1;
    if (verbose) {
      for (const field of ADDRESS_FIELDS) {
        if (field in patch) {
          console.log(
              `  ${doc.id}  ${field}: ${data[field]} → ${patch[field]}`);
        }
      }
    }
    await writer.stage(doc.ref, patch);
  }
  await writer.flush();
  return {scanned, patched};
}

/**
 * Runs the repair.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {db, dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const verbose = argv.includes("--verbose");
  const {scanned, patched} = await repairClients(db, {dryRun, verbose});
  console.log(
      `${dryRun ? "[dry-run] " : ""}clients: ${scanned} scanned, ` +
      `${patched} repaired`);
  if (patched > 0 && !verbose) {
    console.log("Re-run with --verbose to list them.");
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = {assertKnownFlags, repairClients, repairPatchFor};
