#!/usr/bin/env node
"use strict";

const {bootstrapScript} = require("./_project");
const {assertKnownFlags} = require("./_flags");
const {scanByName} = require("./_scan");
const {filterPatchFor, reconcileClientBuilding} =
  require("../client_buildings");

/**
 * Rerunnable alongside the live trigger. Dry-run never enters a write path.
 * @param {!Object} db Firestore.
 * @param {boolean} dryRun Read-only preview.
 * @return {!Promise<!Object>} Non-sensitive counts.
 */
async function backfillBuildings(db, dryRun) {
  let scanned = 0;
  let projectionsChanged = 0;
  for await (const doc of scanByName(
      db.collection("clients"), {pageSize: 250})) {
    scanned++;
    if (Object.keys(filterPatchFor(doc.data())).length > 0) {
      projectionsChanged++;
    }
    if (!dryRun) await reconcileClientBuilding(db, doc.id);
  }
  // Include membership rows whose source was deleted during an earlier run.
  // The live reconciler safely checks whether each source still exists.
  if (!dryRun) {
    for await (const doc of scanByName(
        db.collection("clientBuildingMemberships"), {pageSize: 250})) {
      await reconcileClientBuilding(db, doc.id);
    }
  }
  return {scanned, projectionsChanged, dryRun};
}

if (require.main === module) {
  const {db, dryRun} = bootstrapScript(process.argv.slice(2), {
    assertFlags: (argv) => assertKnownFlags(argv, {exact: ["--dry-run"]}),
  });
  backfillBuildings(db, dryRun).then(console.log).catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}

module.exports = {backfillBuildings};
