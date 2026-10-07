#!/usr/bin/env node
// Backfills the usersByUid bridge collection from existing `users` docs.
// It's idempotent, so it's safe to re-run once after deploying the
// syncUsersByUid trigger.
//
// Usage:
//   For prod:
//     $env:GOOGLE_APPLICATION_CREDENTIALS = "C:\path\to\prod-sa.json"
//     node functions/scripts/backfill.js --dry-run
//     node functions/scripts/backfill.js
//
//   For the local emulator:
//     $env:FIRESTORE_EMULATOR_HOST = "localhost:8080"
//     $env:GCLOUD_PROJECT = "schedulingapp-88727"
//     node functions/scripts/backfill.js --dry-run
//
//   Options:
//     --dry-run        report what would change, write nothing
//     --prune-orphans  ALSO delete bridge rows that no `users` doc claims.
//                      OFF BY DEFAULT: this is the only script in this
//                      directory that deletes anything, and it deletes from
//                      the collection every rules gate resolves a role
//                      through. Without the flag orphans are reported and
//                      nothing is removed. Combine it with --dry-run first.
//
// AN UNKNOWN ARGUMENT IS A HARD ERROR — see `_flags.js`. `--dryrun`,
// `--dry_run` or `--prune_orphans` would otherwise silently read as false: the
// first takes the run LIVE, the second would be a request to delete that this
// script simply never honours.
//
// The script never writes to `users` — it only reads from it and writes to
// `usersByUid`.
//
// A USERS DOC THIS SCRIPT SKIPS KEEPS ITS BRIDGE ROW. That mirrors
// `functions/bridge.js`, whose role guard logs and returns WITHOUT touching
// the bridge: only a console or Admin-SDK write can produce such a doc, and
// removing its row locks a live employee out of everything. So the orphan
// sweep is scoped to a uid NO users doc claims at all — a skipped doc's uid is
// still claimed, and its row is reported and retained. Deciding what such a
// doc's bridge should say belongs to the trigger, not to a one-off script.
//
// PROD RUN: not recorded. `usersByUid` is long-deployed and foundational —
// every rules gate resolves a role through it, and sign-in works — so it
// either ran or the trigger has since covered every doc. Kept rather than
// deleted because it is idempotent and re-runnable if a bridge doc is ever
// found missing; unlike the two client backfills, nothing tracks this one.

const {initializeApp, applicationDefault} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {printTargetBanner} = require("./_project");
// The bridge's pure rules, shared with the `syncUsersByUid` trigger that
// maintains the same collection — see `../bridge_policy.js`.
const {
  shouldHaveBridge,
  bridgeBody,
  bridgeMatches,
  classifyBridgeRow,
} = require("../bridge_policy");
// The batched-write loop, shared so `--dry-run` cannot be forgotten at a call
// site — including on the orphan DELETE below, which is the one irreversible
// write in this directory. See `_batch.js`.
const {commitInBatches} = require("./_batch");

/** Bare switches, matched EXACTLY — see `_flags.js`. */
const EXACT_FLAGS = ["--dry-run", "--prune-orphans"];

/**
 * Rejects any argument that is not a flag this script knows. The rejection
 * rule itself lives in the shared `_flags.js` — this wrapper only supplies
 * this script's flag list.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

/**
 * Reconciles `usersByUid` against `users`; writes nothing under `dryRun`.
 * @param {!Object} db Firestore instance.
 * @param {{dryRun: boolean, pruneOrphans: boolean}} opts The run flags.
 * @return {!Promise<!Object>} The stats the run prints.
 */
async function reconcileBridges(db, {dryRun, pruneOrphans}) {
  const tag = dryRun ? "[dry-run] " : "";
  // `batchSize: 1`, deliberately. This repairs the collection every
  // `firestore.rules` gate resolves a role through, so PARTIAL PROGRESS IS
  // STRICTLY BETTER THAN NONE: each row used to commit on its own, and
  // accumulating them into a 500-op batch meant one rejected commit discarded
  // up to 499 repairs that had already been decided. The writer is still what
  // owns `--dry-run` — that is why this goes through it rather than back to a
  // bare `set`/`delete` with a hand-written guard.
  const writer = commitInBatches(db, {dryRun, batchSize: 1});

  // Read the bridge FIRST so a dry run can report what would actually change
  // rather than counting every eligible doc as a write.
  const bridgeSnap = await db.collection("usersByUid").get();
  const stored = new Map(bridgeSnap.docs.map((d) => [d.id, d.data()]));

  const usersSnap = await db.collection("users").get();

  const stats = {
    scanned: 0,
    created: 0,
    updated: 0,
    unchanged: 0,
    skippedInvited: 0,
    skippedNoUid: 0,
    skippedInvalid: 0,
    bridgesRetained: 0,
    orphansFound: 0,
    orphansDeleted: 0,
  };

  // Every uid ANY users doc carries, including the docs skipped below — a
  // claimed uid is never an orphan. `expectedUids` is the narrower set this
  // script is willing to write.
  const claimedUids = new Set();
  const expectedUids = new Set();

  for (const doc of usersSnap.docs) {
    stats.scanned += 1;
    const data = doc.data();
    const uid = typeof data.uid === "string" ? data.uid : "";
    if (uid) claimedUids.add(uid);

    if (data.status === "invited") {
      stats.skippedInvited += 1;
      continue;
    }
    if (!uid) {
      stats.skippedNoUid += 1;
      continue;
    }
    if (!shouldHaveBridge(data)) {
      stats.skippedInvalid += 1;
      console.warn(
          `  ${tag}skipping invalid user doc ${doc.id} (role=${data.role}, ` +
          `status=${data.status}) — its bridge row is left untouched`);
      continue;
    }

    expectedUids.add(uid);
    const body = bridgeBody(doc.id, data);
    if (bridgeMatches(stored.get(uid), body)) {
      stats.unchanged += 1;
      continue;
    }
    if (stored.has(uid)) {
      stats.updated += 1;
    } else {
      stats.created += 1;
    }
    await writer.stageSet(db.collection("usersByUid").doc(uid), body);
  }

  for (const doc of bridgeSnap.docs) {
    // The three-way decision guarding this script's only destructive write
    // lives in `../bridge_policy.js` so it can be unit-tested — see
    // `classifyBridgeRow` for why "retained" is not "orphan".
    const verdict = classifyBridgeRow(doc.id, {expectedUids, claimedUids});
    if (verdict === "current") continue;

    if (verdict === "retained") {
      stats.bridgesRetained += 1;
      console.warn(
          `  ${tag}bridge retained: usersByUid/${doc.id} — a skipped users ` +
          "doc claims this uid");
      continue;
    }

    stats.orphansFound += 1;
    if (!pruneOrphans) {
      console.warn(
          `  orphan bridge found: usersByUid/${doc.id} — kept; pass ` +
          "--prune-orphans to delete it");
      continue;
    }
    // The writer no-ops under `--dry-run`, so the decision to delete is made
    // in exactly one place and the count reports what the run would do —
    // the same convention `backfill-clients-archived.js` follows. The WORDING
    // still has to stay conditional: this is the one irreversible script here,
    // and an operator reading "removed" plus a non-zero `orphansDeleted` out
    // of a dry run would reasonably conclude the rows were gone.
    await writer.stageDelete(doc.ref);
    stats.orphansDeleted += 1;
    console.warn(dryRun ?
        `  ${tag}orphan bridge would be removed: usersByUid/${doc.id}` :
        `  orphan bridge removed: usersByUid/${doc.id}`);
  }

  await writer.flush();

  return stats;
}

/**
 * Mirrors every eligible `users` doc into `usersByUid`.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  assertKnownFlags(argv);
  const dryRun = argv.includes("--dry-run");
  const pruneOrphans = argv.includes("--prune-orphans");
  const tag = dryRun ? "[dry-run] " : "";

  // When pointed at the emulator, applicationDefault() is unused. The SDK
  // picks up FIRESTORE_EMULATOR_HOST automatically and ignores creds.
  let app;
  if (process.env.FIRESTORE_EMULATOR_HOST) {
    app = initializeApp({
      projectId: process.env.GCLOUD_PROJECT || "schedulingapp-88727",
    });
  } else {
    if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
      console.error(
          "ERROR: set GOOGLE_APPLICATION_CREDENTIALS to a service-account " +
          "JSON path (or FIRESTORE_EMULATOR_HOST for the emulator).");
      process.exit(1);
    }
    app = initializeApp({credential: applicationDefault()});
  }

  // Printed BEFORE the first read. This used to say "Running against PROD
  // project from service-account creds", which names the credential SOURCE and
  // not the project — the one thing an operator needs to see before a bulk
  // write to the collection every rules gate resolves a role through.
  printTargetBanner(app, {dryRun});

  const db = getFirestore();
  const stats = await reconcileBridges(db, {dryRun, pruneOrphans});

  console.log(`\n${tag}Backfill complete:`);
  console.log(JSON.stringify(stats, null, 2));
  if (stats.orphansFound > 0 && !pruneOrphans) {
    console.log(
        `\n${stats.orphansFound} orphan bridge row(s) were left in place. ` +
        "Re-run with --prune-orphans to delete them.");
  }
}

// Only run when invoked directly, so the helpers here are requirable by jest
// without the script reaching for prod credentials.
if (require.main === module) {
  main().catch((err) => {
    console.error("Backfill failed:", err);
    process.exit(1);
  });
}

module.exports = {
  assertKnownFlags,
  reconcileBridges,
  // Re-exported so the script's own surface stays requirable by jest without
  // prod credentials; the bodies live in `../bridge_policy.js`.
  bridgeBody,
  bridgeMatches,
  shouldHaveBridge,
  classifyBridgeRow,
};
