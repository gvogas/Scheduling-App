"use strict";

/**
 * @fileoverview The outbox's claim, lease and outcome protocol — the
 * transactional pieces every drain is built from.
 * ## Job document contract (`waveSyncQueue/{jobId}`)
 * ```
 * {
 * type:           'customerUpsert',
 * refPath:        'clients/<id>',
 * payloadHash:    '<hash>|undefined',   // written when caller provides it
 * attempts:       0,
 * nextAttemptAt:  <timestamp>,
 * claimedAt:      <timestamp>|undefined, // set on claim; used by reaper
 * status:         'queued'|'inflight'|'done'|'dead',
 * lastError:      string|null,
 * idempotencyKey: '<string>',
 * }
 * ```
 * ## Claim protocol
 * To claim a job we re-read it, skip it unless it's still `queued`, then set
 * it `inflight` and stamp `claimedAt` — all inside one transaction. That's
 * what keeps two worker instances from grabbing the same job.
 * ## Lease / reclaim protocol
 * The claim and the outcome write are separated by a Wave API call, so if
 * the function instance dies in between, a job could get stranded `inflight`
 * forever. To fix that, the reclaim pass at the start of `drainQueue` looks
 * for jobs whose `claimedAt` is older than `LEASE_MS` and retries or
 * dead-letters them (bumping `attempts`). It does that through the same
 * atomic re-read-and-rewrite transaction a normal failure uses, so a
 * concurrent reclaim or re-enqueue happening in that same window can't get
 * clobbered.
 * ## Outcome-write guard
 * The outcome write is transactional too (`commitOutcome`): it only commits
 * while the job is still `inflight` with the same `claimedAt` it had at
 * claim time. That way, if a client re-enqueues the job or another worker
 * re-claims it while the Wave call is still in flight, our write just gets
 * skipped instead of incorrectly stomping the job to `done`.
 * ## Required Firestore composite indexes
 * `waveSyncQueue` needs both `(status ASC, nextAttemptAt ASC)` (for
 * `drainQueue`'s queued query) and `(status ASC, claimedAt ASC)` (for the
 * reclaim pass) in `firestore.indexes.json`. Run
 * `firebase deploy --only firestore:indexes` after adding them.
 * ## Throughput sizing
 * drainQueue's schedule frequency × batchLimit must stay under Wave's 60/min
 * limit — the default (batchLimit 30, 5-min cadence) peaks at 6/min, so
 * adjust both together if you change either.
 * @module wave/outbox_core
 */

const {toMillis} = require("../time_utils");
const {
  sanitizeError,
  RECLAIM_REASON,
  reclaimDecision,
} = require("./retry_policy");
const {QUEUE_COLLECTION, clientIdFromRefPath} = require("./outbox_keys");

/**
 * Default number of jobs to claim per drainQueue invocation (see note above
 * about throughput sizing).
 */
const DEFAULT_BATCH_LIMIT = 30;

/**
 * Default lease duration (10 minutes, comfortably longer than any Cloud
 * Function's max runtime) after which an `inflight` job is assumed lost and
 * reclaimed by the next drainQueue run.
 */
const DEFAULT_LEASE_MS = 600_000;

/**
 * Flags the client doc behind a dead-lettered job with a sanitized sync error,
 * so admins see `error` instead of forever-`pending` — best effort, so it never
 * throws.
 * @param {!Object} db Firestore instance.
 * @param {string} refPath The job's `refPath` (`'clients/<id>'`).
 * @param {string} message Sanitized, PII-free error summary.
 * @param {!Object} logger Logging facade.
 * @return {!Promise<void>}
 */
async function markClientSyncError(db, refPath, message, logger) {
  const clientId = clientIdFromRefPath(refPath);
  if (!clientId) return;
  try {
    await db.collection("clients").doc(clientId).update({
      "wave.syncState": "error",
      "wave.syncError": message,
    });
  } catch (err) {
    logger.warn("WAVE-WORKER could not mark client sync error", {
      clientId,
      error: sanitizeError(err),
    });
  }
}

/**
 * Converts a Firestore timestamp-ish value (Date, Timestamp, or number) to
 * epoch milliseconds, returning NaN for anything non-numeric (e.g.
 * @param {*} value
 * @return {number} Epoch ms, or NaN.
 */
function timestampToMs(value) {
  // Delegates to the owner in `time_utils`.
  const ms = toMillis(value);
  if (ms != null) return ms;
  // Numeric strings were accepted here and nowhere else; preserved rather than
  // quietly narrowed.
  const n = Number(value);
  return Number.isFinite(n) ? n : NaN;
}

/**
 * Whether two `claimedAt` stamps identify the same claim — compares by epoch ms
 * when both are real timestamps, else falls back to strict identity (e.g.
 * @param {*} a
 * @param {*} b
 * @return {boolean}
 */
function sameClaim(a, b) {
  const am = timestampToMs(a);
  const bm = timestampToMs(b);
  if (Number.isFinite(am) && Number.isFinite(bm)) return am === bm;
  return a === b;
}

/**
 * Atomically writes a claimed job's terminal/retry outcome, but only while this
 * worker still owns the claim — same `inflight` status and same `claimedAt`.
 * @param {!Object} db Firestore instance.
 * @param {!Object} ref The job document ref.
 * @param {*} claimStamp The `claimedAt` value written when the job was claimed.
 * @param {!Object} update The outcome fields to write when still owned.
 * @return {!Promise<boolean>} True if the outcome was written.
 */
async function commitOutcome(db, ref, claimStamp, update) {
  let applied = false;
  await db.runTransaction(async (tx) => {
    applied = false; // reset per retry of the transaction callback
    const fresh = await tx.get(ref);
    if (!fresh || !fresh.exists) return;
    const freshData = fresh.data() || {};
    if (freshData.status !== "inflight") return;
    if (!sameClaim(freshData.claimedAt, claimStamp)) return;
    tx.update(ref, update);
    applied = true;
  });
  return applied;
}

/**
 * @typedef {{
 * db: !Object,
 * logger: !Object,
 * backoffFn: !Function,
 * maxAttempts: number,
 * batchLimit: number,
 * leaseMs: number,
 * deadlineMs: number,
 * pastDeadline: !Function,
 * nowValue: *,
 * nowMs: number,
 * nowFn: (!Function|undefined),
 * dispatchUpsert: !Function,
 * graphql: (!Function|undefined),
 * businessId: (string|undefined),
 * summary: !Object
 * }} DrainContext
 */

/**
 * Reclaim pass. Fixes jobs stuck `inflight` because the function died between
 * claim and outcome write, by re-reading and rewriting each stale job in one
 * transaction — that's what leaves a concurrent reclaim or re-enqueue untouched
 * instead of getting clobbered.
 * @param {!DrainContext} ctx Shared drain state; `ctx.summary` is mutated.
 * @return {!Promise<void>}
 */
async function reclaimStaleJobs(ctx) {
  const {
    db, logger, backoffFn, maxAttempts, batchLimit, leaseMs, deadlineMs,
    pastDeadline, nowMs, summary,
  } = ctx;

  const leaseThreshold = new Date(nowMs - leaseMs);
  const staleSnap = await db.collection(QUEUE_COLLECTION)
      .where("status", "==", "inflight")
      .where("claimedAt", "<=", leaseThreshold)
      .limit(batchLimit)
      .get();

  const staleDocs = staleSnap && Array.isArray(staleSnap.docs) ?
    staleSnap.docs : [];

  for (const staleDoc of staleDocs) {
    if (pastDeadline()) {
      logger.warn("WAVE-WORKER deadline budget reached during reclaim", {
        deadlineMs,
      });
      break;
    }
    const jobId = staleDoc.id;
    // This reclaim is atomic: we re-read and rewrite the job in one
    // transaction, writing only while it's still inflight past its lease.
    let outcome = null;

    try {
      await db.runTransaction(async (tx) => {
        outcome = null; // reset per transaction retry
        const fresh = await tx.get(staleDoc.ref);
        if (!fresh || !fresh.exists) return;
        const freshData = fresh.data() || {};
        // The decision itself is pure and lives in `retry_policy.js` — the
        // transaction owns only the re-read and the write.
        const decision = reclaimDecision({
          status: freshData.status,
          claimedAtMs: timestampToMs(freshData.claimedAt),
          attempts: freshData.attempts,
        }, {nowMs, leaseMs, maxAttempts, backoffFn});
        if (!decision) return;

        tx.update(staleDoc.ref, decision.patch);
        outcome = decision.dead ?
          {
            dead: true,
            newAttempts: decision.attempts,
            refPath: freshData.refPath,
            clientId: clientIdFromRefPath(freshData.refPath),
          } :
          {dead: false, newAttempts: decision.attempts};
      });
    } catch (txErr) {
      logger.warn("WAVE-WORKER reclaim transaction failed", {
        jobId,
        error: sanitizeError(txErr),
      });
      continue;
    }

    // No outcome means the job was no longer a stale inflight — it was
    // re-enqueued or re-claimed in the window, so we leave it for the owning
    // path to resolve.
    if (!outcome) continue;

    if (outcome.dead) {
      logger.error("WAVE-WORKER dead-lettering reclaimed job", {
        jobId,
        clientId: outcome.clientId,
        attempts: outcome.newAttempts,
        reason: RECLAIM_REASON,
      });
      // Surface the terminal failure on the client doc, best effort, so the
      // admin UI shows 'error' instead of a forever-'pending' sync state.
      await markClientSyncError(
          db, outcome.refPath, "Sync failed after repeated attempts.", logger,
      );
    }
    summary.reclaimed += 1;
  }
}

/**
 * Transactionally claims one queued job for this drain.
 * @param {!DrainContext} ctx Shared drain state.
 * @param {!Object} doc The queue doc snapshot from the batch query.
 * @param {!Date} claimStamp The lease stamp; `commitOutcome` matches on it.
 * @return {!Promise<boolean>} whether this drain now owns the job.
 */
async function claimJob(ctx, doc, claimStamp) {
  const {db, logger} = ctx;
  let claimed = false;
  try {
    await db.runTransaction(async (tx) => {
      // Reset on each retry so a prior abandoned callback run doesn't bleed:
      // Firestore may re-run the callback, and a `true` left over from an
      // aborted attempt would claim a job this drain does not hold.
      claimed = false;
      const fresh = await tx.get(doc.ref);
      if (!fresh || !fresh.exists) return; // deleted between query and claim
      const freshData = fresh.data() || {};
      if (freshData.status !== "queued") return; // already claimed/done
      tx.update(doc.ref, {status: "inflight", claimedAt: claimStamp});
      claimed = true;
    });
  } catch (txErr) {
    logger.warn("WAVE-WORKER claim transaction failed", {
      jobId: doc.id,
      error: sanitizeError(txErr),
    });
    return false;
  }
  return claimed;
}

module.exports = {
  DEFAULT_BATCH_LIMIT,
  DEFAULT_LEASE_MS,
  markClientSyncError,
  commitOutcome,
  reclaimStaleJobs,
  claimJob,
};
