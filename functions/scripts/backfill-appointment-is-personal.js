#!/usr/bin/env node
// One-off: stamps `isPersonal: false` on every /appointments doc that lacks
// the field, and REPORTS (never modifies) every client job stored as one wide
// multi-day document.
//
// WHY: the overdue review now filters `where('isPersonal', '==', false)` and
// the calendar's 14-day lookback is a second query `isPersonal == true`.
// Firestore EXCLUDES documents missing a filtered field, so a doc written
// before the flag existed (2026-07-31, ADR-0047) would silently leave the
// overdue review. The app has always read a missing flag as false
// (`AppointmentRecord.fromMap`: `data['isPersonal'] == true`), so stamping
// false changes nothing it shows.
//
// The wide-job report is the owner's go/no-go for the lookback split
// (ADR-0189): a client job spanning days that starts before a calendar window
// is no longer fetched by it once the main query starts at the window.
//
// RUN THIS BEFORE deploying the app build that carries the query change.
// Idempotent: a doc that already has the field is skipped.
//
// Usage: node functions/scripts/run.js backfill-appointment-is-personal
//        [--live] [--verbose]
//
// AN UNKNOWN ARGUMENT IS A HARD ERROR — see `_flags.js`.

"use strict";

const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {bootstrapScript} = require("./_project");
const {commitInBatches} = require("./_batch");
const {scanByName} = require("./_scan");
const {dayCountOf} = require("../day_slice_utils");
const {toMillis} = require("../time_utils");

/** Bare switches, matched EXACTLY — see `_flags.js`. */
const EXACT_FLAGS = ["--dry-run", "--verbose"];

/**
 * Rejects any argument that is not a flag this script knows.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS});
}

const BATCH_SIZE = 400;
const PAGE_SIZE = 500;

/**
 * The one decision per document: what to write, and whether to report it.
 *
 * `patch` mirrors the Dart read (`isPersonal == true`, so absent is false);
 * a stored boolean is never rewritten. `wideJob` is a NON-personal document
 * whose daily window covers two or more work days (`dayCountOf`, the owner of
 * that count) — the shape ADR-0050 stopped writing and the lookback split
 * stops fetching.
 *
 * @param {?Object} data The stored appointment document.
 * @return {{patch: ?Object, wideJob: boolean, days: number}}
 */
function classifyAppointment(data) {
  const doc = data || {};
  const patch = typeof doc.isPersonal === "boolean" ? null :
    {isPersonal: false};
  const days = doc.isPersonal === true ? 1 : dayCountOf(doc);
  return {patch, wideJob: days >= 2, days};
}

/**
 * Scans every appointment, stamping the flag and collecting wide jobs.
 * @param {!Object} db The Firestore handle.
 * @param {{dryRun: boolean}} options Whether to write.
 * @return {!Promise<{scanned: number, stamped: number, skipped: number,
 *     stampedIds: !Array<string>, wideJobs: !Array<!Object>}>}
 */
async function backfillIsPersonal(db, {dryRun}) {
  const summary = {scanned: 0, stamped: 0, skipped: 0, stampedIds: [],
    wideJobs: []};
  const writer = commitInBatches(db, {dryRun, batchSize: BATCH_SIZE});

  for await (const doc of scanByName(
      db.collection("appointments"), {pageSize: PAGE_SIZE})) {
    summary.scanned += 1;
    const data = doc.data() || {};
    const {patch, wideJob, days} = classifyAppointment(data);
    if (wideJob) {
      summary.wideJobs.push({
        id: doc.id,
        days,
        status: String(data.status || "pending"),
        startMs: toMillis(data.startTime),
      });
    }
    if (!patch) {
      summary.skipped += 1;
      continue;
    }
    summary.stamped += 1;
    summary.stampedIds.push(doc.id);
    await writer.stage(doc.ref, patch);
  }
  await writer.flush();
  return summary;
}

/**
 * Entry point.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {db, dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const verbose = argv.includes("--verbose");

  const s = await backfillIsPersonal(db, {dryRun});

  if (verbose) {
    for (const id of s.stampedIds) console.log(`  stamped  ${id}`);
  }
  console.log(
      `${dryRun ? "[dry-run] " : ""}appointments: ${s.scanned} scanned, ` +
      `${s.stamped} stamped isPersonal:false, ` +
      `${s.skipped} already had the field`);
  if (s.stamped > 0 && !verbose) {
    console.log("Re-run with --verbose to list them.");
  }

  console.log(`\nwide client jobs (one document, 2+ work days): ` +
      `${s.wideJobs.length} — reported only, never modified`);
  for (const job of s.wideJobs) {
    const start = job.startMs == null ? "(no startTime)" :
      new Date(job.startMs).toISOString();
    console.log(`  ${job.days}d  appointments/${job.id}  ${job.status}  ` +
        `starts ${start}`);
  }
  if (s.wideJobs.length > 0) {
    console.log(
        "A wide job starting before a calendar window is no longer fetched " +
        "by it (ADR-0189). Closed ones still list in History; an OPEN one " +
        "should be re-booked per day before the app build ships.");
  }
}

// Only run when invoked directly, so the decision is requirable by jest.
if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = {
  assertKnownFlags,
  classifyAppointment,
  backfillIsPersonal,
  PAGE_SIZE,
};
