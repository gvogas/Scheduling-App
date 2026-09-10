"use strict";

/**
 * @fileoverview Wave Accounting outbox worker.
 * Manages the `waveSyncQueue` collection — a durable outbox for Wave API
 * write-backs — enqueued per client and drained by the scheduler's
 * `drainQueue`.
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
 * ## Retryability taxonomy
 * Lives in the pure sibling `retry_policy.js` — no db, no logger, no clock —
 * so the decisions that dead-letter a real client edit are testable without
 * this module's Firestore-mock harness. `RATE_LIMITED_MAX_ATTEMPTS` is
 * re-exported from here so downstream callers see no change.
 * ## Required Firestore composite indexes
 * `waveSyncQueue` needs both `(status ASC, nextAttemptAt ASC)` (for
 * `drainQueue`'s queued query) and `(status ASC, claimedAt ASC)` (for the
 * reclaim pass) in `firestore.indexes.json`. Run
 * `firebase deploy --only firestore:indexes` after adding them.
 * ## Throughput sizing
 * drainQueue's schedule frequency × batchLimit must stay under Wave's 60/min
 * limit — the default (batchLimit 30, 5-min cadence) peaks at 6/min, so
 * adjust both together if you change either.
 * @module wave/worker
 */

const {WaveValidationError, upsertCustomer} = require("./customers");
const {isBlocked, statePatch} = require("./customer_contract");
const {adminFirestore} = require("../admin_firestore");
const {WaveApiError} = require("./client");
const {mappedFieldsHash} = require("./mappers");
const {toMillis} = require("../time_utils");
const {
  DEFAULT_MAX_ATTEMPTS,
  RATE_LIMITED_MAX_ATTEMPTS,
  defaultBackoffMs,
  isRetryable,
  attemptBudgetFor,
  sanitizeError,
  describeWaveError,
  RECLAIM_REASON,
  reclaimDecision,
} = require("./retry_policy");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Firestore collection that holds outbox jobs. */
const QUEUE_COLLECTION = "waveSyncQueue";

/**
 * Default number of jobs to claim per drainQueue invocation (see note above
 * about throughput sizing).
 */
const DEFAULT_BATCH_LIMIT = 30;

// Cap on the import's protect-list read (see listOutstandingClientIds).
const OUTSTANDING_MAX = 2000;

/**
 * Default lease duration (10 minutes, comfortably longer than any Cloud
 * Function's max runtime) after which an `inflight` job is assumed lost and
 * reclaimed by the next drainQueue run.
 */
const DEFAULT_LEASE_MS = 600_000;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

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
 * Extracts the clientId from a `refPath` like `'clients/<id>'`.
 * @param {string} refPath The `refPath` stored in the job doc.
 * @return {string} The client id segment, or empty string on a bad path.
 */
function clientIdFromRefPath(refPath) {
  if (typeof refPath !== "string") return "";
  const parts = refPath.split("/");
  return parts.length >= 2 ? parts[parts.length - 1] : "";
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

// ---------------------------------------------------------------------------
// shouldEnqueueClientWrite
// ---------------------------------------------------------------------------

/**
 * Decides whether a `clients/{id}` write should enqueue a Wave customer-upsert
 * job.
 * @param {Object|null|undefined} before Pre-write client document data
 * (null/undefined on a create).
 * @param {Object|null|undefined} after Post-write client document data;
 * callers must not invoke this for a delete (after absent) — that path
 * returns early in the trigger.
 * @return {boolean} True when a job should be enqueued.
 */
function shouldEnqueueClientWrite(before, after) {
  const afterData = after || {};
  const afterHash = mappedFieldsHash(afterData);

  // Rule 1: mapped fields unchanged vs. before → wave-only/unmapped change.
  if (before && afterHash === mappedFieldsHash(before)) {
    return false;
  }

  // Rule 2: mapped fields already equal the last synced hash → no-op.
  const wave = (afterData.wave && typeof afterData.wave === "object") ?
    afterData.wave : {};
  if (afterHash === wave.lastSyncedHash) {
    return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// enqueueCustomerUpsert
// ---------------------------------------------------------------------------

/**
 * Uses a deterministic jobId (`customerUpsert__<clientId>`) written via
 * `set(..., {merge:true})`, so a burst of client edits collapses into one
 * updated-in-place job.
 * @param {string} clientId Firestore `clients` document id.
 * @param {Object=} deps Injectable dependencies. `db`/`now` default to
 * `getFirestore()`/`FieldValue.serverTimestamp` (never triggered in unit
 * tests). Optional `payloadHash` is written to the job doc when provided.
 * Optional `batch` (a Firestore WriteBatch) stages the enqueue on the
 * caller's batch instead of writing immediately, so it can be paired
 * atomically with other writes — e.g. the waveUpsertCustomer trigger's
 * mark-pending update.
 * @return {!Promise<string>} The jobId that was enqueued (or staged).
 */
async function enqueueCustomerUpsert(clientId, deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  const now = deps.now || adminFirestore().FieldValue.serverTimestamp;

  const jobId = `customerUpsert__${clientId}`;
  const ref = db.collection(QUEUE_COLLECTION).doc(jobId);

  const docData = {
    type: "customerUpsert",
    refPath: `clients/${clientId}`,
    status: "queued",
    nextAttemptAt: now(),
    idempotencyKey: jobId,
    attempts: 0,
    lastError: null,
  };

  if (deps.payloadHash !== undefined) {
    docData.payloadHash = deps.payloadHash;
  }

  if (deps.batch) {
    deps.batch.set(ref, docData, {merge: true});
  } else {
    await ref.set(docData, {merge: true});
  }

  return jobId;
}

/**
 * Removes a client's queued upsert job, if one is still waiting.
 *
 * The enqueue gate refuses a client the contract blocks, but a job enqueued by
 * an EARLIER edit can still be sitting in the outbox — and the worker re-reads
 * the LIVE document, so that job would push the now-invalid one.
 *
 * Transactional, and it deletes ONLY while the job is still `queued`. An
 * `inflight` job is claimed by a live dispatcher; deleting it out from under
 * `commitOutcome` would break the claim invariant that keeps a re-enqueue
 * mid-dispatch from being clobbered. Such a job is left alone and refused at
 * dispatch instead, one moment later.
 * @param {string} clientId Firestore `clients` document id.
 * @param {Object=} deps Injectable `db`.
 * @return {!Promise<boolean>} Whether a queued job was removed.
 */
async function cancelCustomerUpsert(clientId, deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  const ref = db
      .collection(QUEUE_COLLECTION)
      .doc(`customerUpsert__${clientId}`);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap || !snap.exists) return false;
    const data = snap.data() || {};
    if (data.status !== "queued") return false;
    tx.delete(ref);
    return true;
  });
}

// ---------------------------------------------------------------------------
// drainQueue phases
// ---------------------------------------------------------------------------

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
 * Main drain. Before dispatch, it claims queued jobs transactionally — same
 * re-read, skip-unless-`queued`, set-`inflight`-and-stamp-`claimedAt` dance
 * described above — and writes every outcome through `commitOutcome` so a
 * concurrent re-enqueue never gets clobbered.
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

// ---------------------------------------------------------------------------
// drainQueue
// ---------------------------------------------------------------------------

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

/**
 * Counts outbox jobs still waiting to reach Wave.
 * @param {Object=} deps Injectable dependencies — `db`.
 * @return {!Promise<number>} Jobs currently in `queued`.
 */
async function countQueuedJobs(deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  const snap = await db.collection(QUEUE_COLLECTION)
      .where("status", "==", "queued").count().get();
  return snap.data().count;
}

/**
 * Counts DEAD-LETTERED outbox jobs — client edits that will never reach Wave on
 * their own.
 * @param {Object=} deps Injectable dependencies — `db`.
 * @return {!Promise<number>} Jobs currently in `dead`.
 */
async function countDeadJobs(deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  const snap = await db.collection(QUEUE_COLLECTION)
      .where("status", "==", "dead").count().get();
  return snap.data().count;
}

/** How many requeue transactions run concurrently. */
const REQUEUE_CHUNK = 25;

/**
 * Returns dead-lettered jobs to the queue for another try.
 *
 * A job whose client the CONTRACT now refuses is dropped instead, and the
 * reason is written onto the client. Requeuing it would dead-letter it again
 * inside the drain behind this very call — which is what made "Retry failed"
 * appear to do nothing: the press reported success over a count that had not
 * moved. Only a transient failure is retryable; a refusal is fixable, and it
 * is fixed on the client, not in the queue.
 * @param {Object=} deps Injectable dependencies — `db`, `limit`, `now`,
 * `logger`.
 * @return {!Promise<{requeued: number, scanned: number, blocked: number}>} How
 * many were returned to the queue, how many dead jobs were examined, and how
 * many were dropped as refused.
 */
async function requeueDeadJobs(deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  // eslint-disable-next-line global-require
  const logger = deps.logger || require("firebase-functions/logger");
  const limit = typeof deps.limit === "number" ? deps.limit : OUTSTANDING_MAX;
  const nowValue = deps.now ? deps.now() : new Date();

  const snap = await db.collection(QUEUE_COLLECTION)
      .where("status", "==", "dead")
      .limit(limit)
      .get();
  const docs = snap && Array.isArray(snap.docs) ? snap.docs : [];

  const requeueOne = async (doc) => {
    try {
      return await db.runTransaction(async (tx) => {
        const fresh = await tx.get(doc.ref);
        // Re-enqueued by a client edit in the meantime: that job is newer and
        // carries the current payload hash.
        if (!fresh.exists) return "skipped";
        const data = fresh.data() || {};
        if (data.status !== "dead") return "skipped";

        // Ask the contract before spending a retry on it.
        const refPath = typeof data.refPath === "string" ? data.refPath : "";
        if (refPath) {
          const clientRef = db.doc(refPath);
          const clientSnap = await tx.get(clientRef);
          // A MISSING doc is not a refusal — the dispatcher already treats one
          // as a clean skip, and blocking would put a reason on a client that
          // no longer exists.
          if (clientSnap && clientSnap.exists) {
            const clientData = clientSnap.data() || {};
            if (isBlocked(clientData)) {
              tx.update(clientRef, statePatch(clientData));
              tx.delete(doc.ref);
              return "blocked";
            }
          }
        }

        tx.update(doc.ref, {
          status: "queued",
          attempts: 0,
          nextAttemptAt: nowValue,
          lastError: null,
        });
        return "requeued";
      });
    } catch (e) {
      // One stubborn job must not abort the rest of the recovery.
      logger.warn("WAVE-WORKER requeue failed", {
        jobId: doc.id, error: String(e),
      });
      return "skipped";
    }
  };

  // Chunked rather than one-at-a-time.
  let requeued = 0;
  let blocked = 0;
  for (let i = 0; i < docs.length; i += REQUEUE_CHUNK) {
    const chunk = docs.slice(i, i + REQUEUE_CHUNK);
    const outcomes = await Promise.all(chunk.map(requeueOne));
    requeued += outcomes.filter((o) => o === "requeued").length;
    blocked += outcomes.filter((o) => o === "blocked").length;
  }
  return {requeued, scanned: docs.length, blocked};
}

/**
 * Client ids with an outbox job that has not reached Wave yet.
 * @param {Object=} deps Injectable dependencies — `db`, `limit`.
 * @return {!Promise<!Set<string>>} Client ids to leave alone.
 */
async function listOutstandingClientIds(deps = {}) {
  const db = deps.db || adminFirestore().getFirestore();
  const limit = typeof deps.limit === "number" ? deps.limit : OUTSTANDING_MAX;
  const snap = await db.collection(QUEUE_COLLECTION)
      .where("status", "in", ["queued", "inflight", "dead"])
      .limit(limit)
      .get();
  const docs = (snap && snap.docs) || [];
  const ids = new Set();
  for (const doc of docs) {
    const id = clientIdFromRefPath((doc.data() || {}).refPath);
    if (id) ids.add(id);
  }
  // Logged HERE, not at the callers: the header claimed the callable logged at
  // the cap and none of them did, so the truncation was silent.
  if (docs.length >= limit) {
    const log = deps.logger || require("firebase-functions/logger");
    log.error("WAVE-WORKER outstanding protect-list hit its cap; the import " +
        "will protect only a prefix and may overwrite queued client edits", {
      limit,
      protectedIds: ids.size,
    });
  }
  return ids;
}

module.exports = {
  enqueueCustomerUpsert,
  cancelCustomerUpsert,
  drainQueue,
  countQueuedJobs,
  countDeadJobs,
  requeueDeadJobs,
  listOutstandingClientIds,
  shouldEnqueueClientWrite,
  RATE_LIMITED_MAX_ATTEMPTS,
};
