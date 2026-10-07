#!/usr/bin/env node
// One-off: drains the `waveSyncQueue` outbox to Wave, PACED so Wave's ~60
// calls/min ceiling doesn't just rate-limit everything back onto the queue.
//
// WHY THIS EXISTS. Every other drain path is bounded, deliberately, because
// each is a side job on something else:
//   - `waveUpsertCustomer` (the client-write trigger) — 5 jobs, and it only
//     fires ON A CLIENT WRITE;
//   - `runWaveDaily` (18:00 Toronto, riding the digest) — 20 jobs;
//   - "Sync with Wave" in Settings — 20 jobs per press.
// That is the right sizing for ordinary traffic, where one edit makes one job.
// It is the WRONG sizing after a bulk backfill: a few hundred writes fire a
// few hundred trigger invocations inside a couple of seconds, Wave rate-limits
// most of them, every job goes back on the queue with backoff — and by the
// time the backoff expires the trigger invocations are spent, because nothing
// is writing to `clients` any more. The queue then drains at 20/day, which is
// not a wait, it is stuck. This script is the missing "just finish it".
//
// It is a recovery tool, not part of the system: nothing calls it, it is safe
// to interrupt at any point, and running it twice is harmless.
//
// WHAT IT DOES NOT DO. It does not re-enqueue anything, it does not touch
// `clients`, and it cannot resurrect a DEAD-lettered job — those never retry
// by design and are the "Retry failed" button's business
// (`waveRetryFailedJobs`). It reports the dead count so you know to press it.
//
// PACING. `--rate` is the ceiling in Wave calls per minute (default 50, under
// Wave's 60). Each processed job is about one Wave mutation, so after each
// round the script sleeps however long is needed to keep the running rate
// under that. Raising it past 60 just moves the rejections back into the
// queue — the backoff is what you are trying to escape.
//
// BACKED-OFF JOBS ARE NOT DUE. `drainQueue` only claims jobs whose
// `nextAttemptAt` has come due, so a round can legitimately process NOTHING
// while the queue is still deep — the jobs are sitting out a backoff that
// doubles to a 1 h cap. The script then polls rather than spinning, and gives
// up after `--max-idle` consecutive idle rounds so it cannot loop forever on a
// queue that has genuinely stalled.
//
// Usage:
//   export GOOGLE_APPLICATION_CREDENTIALS=/path/to/prod-service-account.json
//   export WAVE_FULL_ACCESS_TOKEN="$(gcloud secrets versions access latest \
//     --secret=WAVE_FULL_ACCESS_TOKEN --project=schedulingapp-88727)"
//
//   node functions/scripts/drain-wave-queue.js --dry-run   # depth only
//   node functions/scripts/drain-wave-queue.js
//
//   Options:
//     --dry-run       report the queue depth and exit, push nothing
//     --rate=N        Wave calls per minute (default 50, must be 1..60)
//     --max=N         stop after N jobs have been dispatched
//     --max-idle=N    give up after N consecutive rounds with nothing due
//                     (default 10; at the poll interval that is ~5 minutes)
//
// THE TOKEN IS A SECRET AND MUST NOT BE PASTED AS A FLAG — shell history and
// `ps` both leak it. It is read from the environment only, the same variable
// name the deployed functions bind, so `defineSecret(...).value()` resolves it
// unchanged.
//
// AN UNKNOWN ARGUMENT IS A HARD ERROR, for the usual reason: `--dry-run` is
// matched exactly, so `--dryrun` would otherwise read as false and start
// pushing.
//
// Interrupting with Ctrl-C is SAFE. A job is claimed transactionally with a
// lease, so one killed mid-dispatch is reclaimed by the next drain's stale
// pass rather than lost or double-pushed.


const {drainQueue, countQueuedJobs} = require("../wave/worker");
const {readWaveBusinessId} = require("../wave/sync_run");
const {assertKnownFlags: rejectUnknownFlags} = require("./_flags");
const {bootstrapScript} = require("./_project");

/** Jobs claimed per round. Matches the interactive sync's batch. */
const BATCH_LIMIT = 20;

/** Wall-clock budget for one round, so a hung call can't wedge the loop. */
const ROUND_BUDGET_MS = 120 * 1000;

/** How long to wait when the queue is non-empty but nothing is due yet. */
const IDLE_POLL_MS = 30 * 1000;

/** Default Wave calls per minute. Under Wave's ~60 with room to spare. */
const DEFAULT_RATE_PER_MIN = 50;

/** Wave's own ceiling. Asking for more than this is asking to be rejected. */
const MAX_RATE_PER_MIN = 60;

/** Default consecutive idle rounds before giving up. */
const DEFAULT_MAX_IDLE = 10;

const EXACT_FLAGS = ["--dry-run"];
const PREFIX_FLAGS = ["--rate=", "--max=", "--max-idle="];

/**
 * Rejects any argument that is not a flag this script knows.
 * @param {!Array<string>} argv Arguments after the node + script paths.
 */
function assertKnownFlags(argv) {
  rejectUnknownFlags(argv, {exact: EXACT_FLAGS, prefixes: PREFIX_FLAGS});
}

/**
 * Reads a positive integer flag, throwing rather than falling back.
 *
 * A silent fallback here would be a pacing flag that reads as its default and
 * hammers Wave at a rate the operator thought they had turned down.
 *
 * @param {!Array<string>} argv Process arguments.
 * @param {string} name Flag name including the trailing "=".
 * @param {number} fallback Value when the flag is absent.
 * @param {number=} max Inclusive upper bound, if any.
 * @return {number}
 */
function parsePositiveInt(argv, name, fallback, max) {
  const arg = argv.find((a) => a.startsWith(name));
  if (!arg) return fallback;
  const raw = arg.slice(name.length);
  if (!/^\d+$/.test(raw)) {
    throw new Error(`${name} must be a whole number, got "${raw}"`);
  }
  const value = Number(raw);
  if (value < 1) throw new Error(`${name} must be at least 1, got ${value}`);
  if (max !== undefined && value > max) {
    throw new Error(`${name} must be at most ${max}, got ${value}`);
  }
  return value;
}

/**
 * How long to sleep after a round so the running rate stays under the cap.
 *
 * Pure, so the pacing arithmetic is pinned by a test rather than discovered
 * against the live API. Each dispatched job is about one Wave mutation, so N
 * jobs are owed `N / rate` minutes; whatever the round already spent counts
 * toward that.
 *
 * @param {number} processed Jobs dispatched in the round just finished.
 * @param {number} elapsedMs How long that round took.
 * @param {number} ratePerMin Wave calls per minute to stay under.
 * @return {number} Milliseconds to sleep; 0 when the round was slow enough.
 */
function pacingDelayMs(processed, elapsedMs, ratePerMin) {
  if (processed <= 0) return 0;
  const owedMs = (processed / ratePerMin) * 60 * 1000;
  return Math.max(0, Math.ceil(owedMs - elapsedMs));
}

/**
 * @param {number} ms Milliseconds to wait.
 * @return {!Promise<void>}
 */
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Drains the outbox until it is empty, the job cap is hit, or it stalls.
 * @return {!Promise<void>}
 */
async function main() {
  const argv = process.argv.slice(2);
  const {dryRun} = bootstrapScript(argv, {assertFlags: assertKnownFlags});
  const ratePerMin =
    parsePositiveInt(argv, "--rate=", DEFAULT_RATE_PER_MIN, MAX_RATE_PER_MIN);
  const maxJobs = parsePositiveInt(argv, "--max=", Infinity);
  const maxIdle = parsePositiveInt(argv, "--max-idle=", DEFAULT_MAX_IDLE);

  const depth = await countQueuedJobs();
  console.log(`queued jobs: ${depth}\n`);
  if (dryRun) {
    console.log("[dry-run] nothing pushed. Drop --dry-run to drain.");
    return;
  }
  if (depth === 0) {
    console.log("nothing to drain.");
    return;
  }

  // Checked AFTER the depth report, so a `--dry-run` costs nothing and needs
  // no secret at all.
  if (!String(process.env.WAVE_FULL_ACCESS_TOKEN || "").trim()) {
    throw new Error(
        "WAVE_FULL_ACCESS_TOKEN is not set — see this file's header. " +
        "Export it; never pass it as a flag.");
  }

  const businessId = await readWaveBusinessId();
  if (!businessId) {
    throw new Error(
        "Wave is not connected (no businessId on wave/connection). " +
        "Press Connect in Settings first.");
  }
  console.log(`business: ${businessId}`);
  console.log(`pacing: <= ${ratePerMin} Wave calls/min\n`);

  const totals = {processed: 0, done: 0, retried: 0, dead: 0, created: 0,
    updated: 0};
  let idleRounds = 0;

  while (totals.processed < maxJobs) {
    const startedAt = Date.now();
    const remaining = maxJobs - totals.processed;
    const summary = await drainQueue({
      businessId,
      batchLimit: Math.min(BATCH_LIMIT, remaining),
      deadlineMs: startedAt + ROUND_BUDGET_MS,
    });
    if (summary.paused) {
      console.log("Wave sync is paused (feature_wave_sync = false); stopping.");
      break;
    }

    for (const key of Object.keys(totals)) totals[key] += summary[key] || 0;

    const left = await countQueuedJobs();
    if (summary.processed > 0) {
      idleRounds = 0;
      console.log(
          `round: ${summary.processed} dispatched ` +
          `(${summary.done} ok, ${summary.retried} retried, ` +
          `${summary.dead} dead) — ${left} left`);
    } else {
      // Nothing was DUE. Either every remaining job is sitting out a backoff,
      // or another drain claimed them first — both resolve by waiting.
      idleRounds += 1;
      console.log(
          `round: nothing due (${left} left, backing off) ` +
          `[idle ${idleRounds}/${maxIdle}]`);
    }

    if (left === 0) break;
    if (idleRounds >= maxIdle) {
      console.log(
          `\ngiving up after ${maxIdle} idle rounds — ${left} job(s) are ` +
          "still backing off. Re-run later; nothing is lost.");
      break;
    }

    await sleep(summary.processed > 0 ?
      pacingDelayMs(summary.processed, Date.now() - startedAt, ratePerMin) :
      IDLE_POLL_MS);
  }

  console.log(
      `\ndrained: ${totals.processed} dispatched, ${totals.done} committed ` +
      `(${totals.created} created, ${totals.updated} updated in Wave), ` +
      `${totals.retried} requeued, ${totals.dead} dead-lettered`);
  console.log(`queued jobs remaining: ${await countQueuedJobs()}`);

  if (totals.dead > 0) {
    console.log(
        `\n${totals.dead} job(s) DEAD-LETTERED. Those never retry on their ` +
        "own — press \"Retry failed\" in Settings > Wave. If the count does " +
        "not move, the cause is stored on the client doc and re-sending " +
        "cannot fix it; read `lastError` on the job.");
  }
}

// Only run when invoked directly, so the pure helpers are requirable by jest
// without the script reaching for prod credentials.
if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = {assertKnownFlags, pacingDelayMs, parsePositiveInt};
