"use strict";

/**
 * @fileoverview Taking jobs OUT of the outbox: `drainQueue` claims each due
 * job, pushes it to Wave and writes the outcome.
 * @module wave/dispatch
 */

const {WaveValidationError, upsertCustomer} = require("./customers");
const {adminFirestore} = require("../admin_firestore");
const {WaveApiError} = require("./client");
const {
  DEFAULT_MAX_ATTEMPTS,
  defaultBackoffMs,
  isRetryable,
  attemptBudgetFor,
  sanitizeError,
  describeWaveError,
} = require("./retry_policy");
const {
  DEFAULT_BATCH_LIMIT,
  DEFAULT_LEASE_MS,
  markClientSyncError,
  commitOutcome,
  reclaimStaleJobs,
  claimJob,
} = require("./outbox_core");
const {QUEUE_COLLECTION, clientIdFromRefPath} = require("./outbox_keys");

/**
 * Main drain. Before dispatch, it claims queued jobs transactionally — same
 * re-read, skip-unless-`queued`, set-`inflight`-and-stamp-`claimedAt` dance
 * described in `outbox_core.js` — and writes every outcome through
 * `commitOutcome` so a concurrent re-enqueue never gets clobbered.
 * @param {!DrainContext} ctx Shared drain state; `ctx.summary` is mutated.
 * @return {!Promise<void>}
 */
async function dispatchQueuedJobs(ctx) {
  const {db, logger, batchLimit, deadlineMs, pastDeadline, nowValue, nowFn,
    summary} = ctx;

  const snap = await db.collection(QUEUE_COLLECTION)
      .where("status", "==", "queued")
      .where("nextAttemptAt", "<=", nowValue)
      .orderBy("nextAttemptAt")
      .limit(batchLimit)
      .get();

  const docs = snap && Array.isArray(snap.docs) ? snap.docs : [];

  for (const doc of docs) {
    // Stop claiming new jobs once the wall-clock deadline passes, so the
    // function returns with clean outcome writes instead of getting killed
    // mid-dispatch.
    if (pastDeadline()) {
      logger.warn("WAVE-WORKER deadline budget reached — stopping early", {
        deadlineMs,
        remainingJobs: docs.length - summary.processed - summary.skipped,
      });
      break;
    }

    const jobData = doc.data() || {};
    // The actual claim time, not the drain-start clock — with a stale stamp, a
    // long drain could make a job look lease-expired to a concurrent reclaim
    // pass while it is still being dispatched.
    const claimStamp = nowFn ? nowFn() : new Date();

    if (!await claimJob(ctx, doc, claimStamp)) {
      summary.skipped += 1;
      continue;
    }
    summary.processed += 1;

    const result = await dispatchJob(ctx, jobData);
    await resolveOutcome(ctx, doc, jobData, claimStamp, result);
  }
}

/**
 * Runs one claimed job's side effect.
 * @param {!DrainContext} ctx Shared drain state.
 * @param {!Object} jobData The claimed job's stored fields.
 * @return {!Promise<{upsertStatus: (string|undefined), error: ?Error}>}
 */
async function dispatchJob(ctx, jobData) {
  const {db, dispatchUpsert} = ctx;
  try {
    if (jobData.type !== "customerUpsert") {
      // Unknown job type — a permanent failure, never retried.
      throw new TypeError(`Unknown job type: ${String(jobData.type)}`);
    }
    const clientId = clientIdFromRefPath(jobData.refPath);
    // The return value feeds tallyUpsert — see the pointer on upsertCustomer in
    // customers.js.
    const outcome = await dispatchUpsert(clientId, {
      db,
      graphql: ctx.graphql,
      businessId: ctx.businessId,
      // Lets the upsert run its crash-retry duplicate check (search Wave before
      // creating) when a previous attempt may have half-finished.
      priorAttempts:
        typeof jobData.attempts === "number" ? jobData.attempts : 0,
    });
    return {upsertStatus: (outcome || {}).status, error: null};
  } catch (err) {
    return {upsertStatus: undefined, error: err};
  }
}

/**
 * Writes the durable outcome for one dispatched job and tallies it.
 * @param {!DrainContext} ctx Shared drain state; `ctx.summary` is mutated.
 * @param {!Object} doc The queue doc snapshot.
 * @param {!Object} jobData The claimed job's stored fields.
 * @param {!Date} claimStamp This drain's lease stamp.
 * @param {{upsertStatus: (string|undefined), error: ?Error}} result
 * @return {!Promise<void>}
 */
async function resolveOutcome(ctx, doc, jobData, claimStamp, result) {
  const {db, logger, backoffFn, maxAttempts, nowMs, summary} = ctx;
  const jobId = doc.id;
  const dispatchError = result.error;

  if (!dispatchError) {
    const applied = await commitOutcome(db, doc.ref, claimStamp, {
      status: "done",
      lastError: null,
    });
    if (applied) {
      summary.done += 1;
      tallyUpsert(summary, result.upsertStatus);
    } else {
      logger.info("WAVE-WORKER outcome superseded (done skipped)", {jobId});
    }
    return;
  }

  const retryable = isRetryable(dispatchError);
  const newAttempts = (typeof jobData.attempts === "number" ?
    jobData.attempts : 0) + 1;
  const sanitized = sanitizeError(dispatchError);
  // Wave rate-limiting us is not the job's fault, so it gets a far larger
  // budget than a job that is failing on its own merits — see
  // RATE_LIMITED_MAX_ATTEMPTS.
  const budget = attemptBudgetFor(dispatchError, maxAttempts);

  if (retryable && newAttempts < budget) {
    // Back to queued with backoff, using the injected clock so retry time stays
    // testable and consistent with the query's `nowValue`.
    const delayMs = backoffFn(newAttempts - 1);
    const applied = await commitOutcome(db, doc.ref, claimStamp, {
      status: "queued",
      attempts: newAttempts,
      nextAttemptAt: new Date(nowMs + delayMs),
      lastError: sanitized,
    });
    if (applied) {
      summary.retried += 1;
    } else {
      logger.info("WAVE-WORKER outcome superseded (retry skipped)", {jobId});
    }
    return;
  }

  // Dead-letter: not retryable OR attempts cap reached.
  const errKind = (dispatchError instanceof WaveApiError) ?
    dispatchError.kind :
    (dispatchError instanceof WaveValidationError ?
      "validation" : "unexpected");

  const applied = await commitOutcome(db, doc.ref, claimStamp, {
    status: "dead",
    attempts: newAttempts,
    lastError: sanitized,
  });
  if (!applied) {
    logger.info("WAVE-WORKER outcome superseded (dead skipped)", {jobId});
    return;
  }
  // `errorDetail` is the only place the REASON survives — `sanitized` (which is
  // what the job and the client doc keep) flattens every transport failure to
  // "WaveApiError(graphql)", so without this a permanently-dead client edit is
  // undiagnosable and "Retry failed" just re-sends the same payload into the
  // same refusal.
  logger.error("WAVE-WORKER dead-lettering job", {
    jobId,
    clientId: clientIdFromRefPath(jobData.refPath),
    errorClass: dispatchError.constructor ?
      dispatchError.constructor.name : "Error",
    errorKind: errKind,
    errorDetail: describeWaveError(dispatchError),
    attempts: newAttempts,
    retryable,
  });
  // Surface the terminal failure on the client doc, best effort, so the admin
  // UI shows 'error' instead of forever-'pending'.
  if (!(dispatchError instanceof WaveValidationError)) {
    await markClientSyncError(db, jobData.refPath, sanitized, logger);
  }
  summary.dead += 1;
}

/**
 * Folds one `upsertCustomer` outcome into the drain summary's Wave-direction
 * counters, so a caller can say what actually landed in Wave rather than just
 * how many jobs ran.
 * @param {!Object} summary The mutable drain summary.
 * @param {string|undefined} status An `upsertCustomer` status.
 * @return {void}
 */
function tallyUpsert(summary, status) {
  if (status === "created") {
    summary.created += 1;
  } else if (status === "patched" || status === "linked") {
    summary.updated += 1;
  } else if (status === "blocked") {
    // Its own counter, not `dead` and not silence. The job IS resolved — it
    // will never push and nothing should retry it — but a drain that removed
    // a job without sending anything to Wave must be able to say so, or a
    // blocked roster and an idle one report identical zeros.
    summary.blocked += 1;
  }
}

/**
 * Claims and dispatches pending `waveSyncQueue` jobs.
 * @param {Object=} deps Injectable dependencies:
 * - `db` {!Object} Firestore instance (default `getFirestore()`).
 * - `graphql` {!Function} Wave GraphQL client.
 * - `businessId` {string} Connected Wave business id.
 * - `upsertCustomer` {!Function} Override for testing (default: the real
 * `upsertCustomer` from customers.js).
 * - `now` {!Function} Returns the current Firestore Timestamp or a plain
 * Date/number for `nextAttemptAt <= now` comparison.
 * - `backoffFn` {!Function} `(attempts:number) => number` ms; default:
 * exponential with jitter, base 60s, cap 1h.
 * - `maxAttempts` {number} Max retries before dead-lettering (default 5).
 * - `batchLimit` {number} Max jobs per call (default 30; keep
 * `schedule_frequency × batchLimit < Wave 60/min` limit).
 * - `leaseMs` {number} Inflight lease duration in ms (default 600000 / 10
 * min). Jobs still inflight this long get reclaimed, so this needs to
 * exceed the function's maximum runtime or it'll reclaim live jobs.
 * - `deadlineMs` {number} Wall-clock epoch-ms budget — no new job gets
 * claimed past it, though in-flight work still finishes and commits.
 * Defaults to Infinity; the scheduler passes ~70% of its timeout so the
 * run ends with clean outcome writes instead of getting killed
 * mid-dispatch.
 * - `wallClock` {!Function} Returns the current epoch ms (default
 * `Date.now`); injectable for deadline tests.
 * - `logger` {!Object} Logging facade with `.error(msg, meta)` etc.,
 * defaulting to `firebase-functions/logger` (never `console`).
 * @return {!Promise<{processed:number, done:number, retried:number,
 * dead:number, skipped:number, reclaimed:number, created:number,
 * updated:number}>} Summary of the drain run. `created`/`updated` count what
 * landed in Wave (see `tallyUpsert`); the rest describe the queue.
 */
async function drainQueue(deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  // eslint-disable-next-line global-require
  const logger = deps.logger || require("firebase-functions/logger");
  const backoffFn = deps.backoffFn || defaultBackoffMs;
  const maxAttempts =
    typeof deps.maxAttempts === "number" ? deps.maxAttempts :
    DEFAULT_MAX_ATTEMPTS;
  const batchLimit =
    typeof deps.batchLimit === "number" ? deps.batchLimit :
    DEFAULT_BATCH_LIMIT;
  const leaseMs =
    typeof deps.leaseMs === "number" ? deps.leaseMs : DEFAULT_LEASE_MS;
  const deadlineMs =
    typeof deps.deadlineMs === "number" ? deps.deadlineMs : Infinity;
  const wallClock = deps.wallClock || Date.now;
  const dispatchUpsert = deps.upsertCustomer || upsertCustomer;
  const nowValue = deps.now ? deps.now() : new Date();
  const nowMs = +nowValue;

  // True once the wall-clock budget is exhausted (logged once).
  const pastDeadline = () => wallClock() > deadlineMs;

  // `created`/`updated` describe what landed in WAVE (see tallyUpsert); the
  // other counters describe the queue itself.
  const summary = {
    processed: 0, done: 0, retried: 0, dead: 0, skipped: 0, reclaimed: 0,
    created: 0, updated: 0, blocked: 0,
  };

  const ctx = {
    db, logger, backoffFn, maxAttempts, batchLimit, leaseMs, deadlineMs,
    pastDeadline, nowValue, nowMs, nowFn: deps.now, dispatchUpsert,
    graphql: deps.graphql, businessId: deps.businessId, summary,
  };

  await reclaimStaleJobs(ctx);
  await dispatchQueuedJobs(ctx);

  return summary;
}

module.exports = {
  drainQueue,
};
