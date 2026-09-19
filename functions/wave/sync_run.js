"use strict";

/**
 * @fileoverview The two sync-run primitives every Wave push/pull site shares.
 *
 * `importWithWatermark` and `drainForSync` are the two halves of the
 * interactive sync, and each was hand-copied across callers before it had
 * ONE owner. They live here rather than in `callables.js` because
 * nothing about either is a callable: they were only ever in that file because
 * the callables happened to be their first caller.
 *
 * `readWaveBusinessIdCached` comes with them for the same reason: its
 * per-instance cache is what keeps a disconnected install from paying a
 * Firestore read on every client edit, and both automatic drain sites gate on
 * it.
 *
 * @module wave/sync_run
 */

const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");

const {graphql, WaveApiError} = require("./client");
const {importCustomers, WaveValidationError} = require("./customers");
const {sanitizeError, describeWaveError} = require("./retry_policy");
const {drainQueue, countQueuedJobs} = require("./worker");
const {resolveImportWindow, watermarkPatch} = require("./import_schedule");
const {toMillis} = require("../time_utils");
const {shortHash} = require("../security");

/**
 * Coerces a `wave/connection` snapshot into the fields its read sites need.
 *
 * The one owner of that coercion: it was spelled out at eight sites across
 * the callables, the daily rider and here.
 *
 * @param {?Object} snap The connection document snapshot, or null.
 * @return {{data: ?Object, businessId: string, businessName: string}} The
 *   stored document beside its coerced fields; `businessId` is "" when not
 *   connected.
 */
function connectionFieldsOf(snap) {
  const data = snap && snap.exists ? snap.data() : null;
  return {
    data,
    businessId: data && typeof data.businessId === "string" ?
      data.businessId : "",
    businessName: data && typeof data.businessName === "string" ?
      data.businessName : "",
  };
}

/**
 * Reads `wave/connection` once, returning its ref beside the coerced fields.
 *
 * The ref comes back because the sync needs it next, to hand
 * `importWithWatermark` the document it advances.
 *
 * @return {!Promise<{ref: !Object, data: ?Object, businessId: string,
 *   businessName: string}>} The connection.
 */
async function readWaveConnection() {
  const ref = getFirestore().collection("wave").doc("connection");
  return {ref, ...connectionFieldsOf(await ref.get())};
}

/**
 * Reads the connected Wave `businessId` from the `wave/connection` doc.
 * @return {!Promise<string>} The business id, or "" if not connected.
 */
async function readWaveBusinessId() {
  return (await readWaveConnection()).businessId;
}

// Per-instance cache for the drain's connection gate. A found businessId
// caches for the instance's lifetime; a not-connected result only caches for a
// short TTL, so a fresh bootstrap still gets picked up within a few minutes.
const NOT_CONNECTED_CACHE_MS = 5 * 60 * 1000;
let cachedBusinessId = "";
let notConnectedUntilMs = 0;

/**
 * Cached wrapper around readWaveBusinessId for the two automatic drain sites
 * (the `clients` write trigger and the daily sweep). The cache is what keeps a
 * disconnected install from paying a Firestore read on every client edit.
 * @return {!Promise<string>} The business id, or "" if not connected.
 */
async function readWaveBusinessIdCached() {
  if (cachedBusinessId) return cachedBusinessId;
  if (Date.now() < notConnectedUntilMs) return "";
  const businessId = await readWaveBusinessId();
  if (businessId) {
    cachedBusinessId = businessId;
  } else {
    notConnectedUntilMs = Date.now() + NOT_CONNECTED_CACHE_MS;
  }
  return businessId;
}

/**
 * Runs an import against the delta watermark and advances it on success.
 *
 * ONE owner for the whole four-step dance — read the stamps, resolve the
 * window, import, advance — because both callers previously hand-copied it and
 * each omission fails silently in its own direction: forget `since` and every
 * run is a full import; forget the patch and the watermark never moves;
 * advance on the failure path and every customer changed inside that window is
 * skipped for good. The unattended `waveScheduledImport` carried the untested
 * copy, which is the one where a mistake is invisible.
 *
 * Does NOT catch — the caller owns error classification and logging, and each
 * has its own (an HttpsError vs. a logged skip). Throwing leaves both stamps
 * untouched, which is the correct failure behaviour.
 *
 * @param {{connectionRef: !Object, connection: !Object, businessId: string,
 *   skipClientIds: !Set<string>, nowMs: number}} params `connection` is the
 *   already-read doc data.
 * @return {!Promise<{summary: !Object, window: !Object}>}
 */
async function importWithWatermark({
  connectionRef, connection, businessId, skipClientIds, nowMs,
}) {
  let window = resolveImportWindow({
    deltaSinceMs: toMillis(connection.customerDeltaSince),
    lastFullMs: toMillis(connection.lastFullImportAt),
    nowMs,
  });

  let summary;
  try {
    summary = await importCustomers({
      businessId, graphql, skipClientIds, since: window.since,
    });
  } catch (e) {
    // A delta-only failure is STICKY without this: the watermark stays put,
    // so every retry rebuilds the same delta query and fails the same way
    // until the 7-day resync ages it out. One retry as
    // a full import both self-heals that and covers `modifiedAtAfter` itself
    // being wrong, which is not a hypothetical: the query shape was already
    // wrong once against this API.
    if (!window.since) throw e;
    logger.warn("WAVE-CUST delta import failed — retrying as full",
        logSafeError(e));
    window = {since: "", reason: "delta-failed-fell-back-to-full"};
    summary = await importCustomers({
      businessId, graphql, skipClientIds, since: "",
    });
  }

  // A run that PROTECTED clients (skipClientIds) did not import them, so the
  // window it just covered is incomplete — advancing past it would hide any
  // Wave-side change to those customers until the next full pass. Holding the
  // watermark makes the next run re-query the same span; that is idempotent
  // and free, and it self-heals as soon as the outbox drains (a dead-lettered
  // job leaves `queued`/`inflight`, so it stops being protected).
  // Unknown counts as NOT covered on purpose: holding the watermark is free
  // (the next run redoes an idempotent window), advancing it wrongly loses
  // changes.
  const covered = summary.skippedPending === 0;

  // `wasFull` comes from the window we just built, not from the summary —
  // routing our own input back out through importCustomers would give the
  // decision two sources and the further-travelled one would win.
  const patch = covered ?
    watermarkPatch({startedAtMs: nowMs, wasFull: !window.since}) : {};
  if (!covered) {
    logger.info("WAVE-CUST watermark held — run protected pending clients", {
      skippedPending: summary.skippedPending,
    });
  }

  // The import already committed. A failure to record the watermark means the
  // next run redoes this window — wasteful, not wrong — so it must not turn a
  // successful sync into an error the admin sees, discarding the push counts
  // with it.
  if (Object.keys(patch).length > 0) {
    try {
      await connectionRef.update(patch);
    } catch (e) {
      logger.error("WAVE-CUST watermark write failed — next run will redo " +
        "this window", {error: String(e)});
    }
  }

  return {summary, window};
}

// The interactive sync drains the outbox itself so it can report what reached
// Wave. Unlike the other two drain sites, the bound here is the ADMIN'S
// PATIENCE, not the function timeout: the client gives up at
// `kWaveSyncTimeoutSeconds` (120, `wave_service.dart` — hand-mirrored, each
// carries a pointer to the other) and a callable cannot be cancelled,
// so anything past that is work the admin has already been told failed — and
// will re-trigger by tapping again. Push therefore gets a small slice and the
// import keeps the rest; the `waveUpsertCustomer` trigger and the daily sweep
// mop up the backlog either way.
//
// The batch limit is sized to what the budget can actually chew: dispatch is
// sequential (claim txn → Wave round trip → outcome txn, ~1s/job), and the
// query fetches batchLimit docs up front, so a limit the deadline can't reach
// just bills reads for jobs it discards. It is also one of three consumers of
// Wave's 60/min ceiling (see DEFAULT_BATCH_LIMIT's sizing note in worker.js) —
// 20/min leaves room.
const SYNC_PUSH_BATCH_LIMIT = 20;
const SYNC_PUSH_BUDGET_MS = 20 * 1000;

/**
 * Log fields for an error that may carry a Wave message quoting customer data.
 * @param {*} e The caught error.
 * @return {{error: string, errorDetail: string}} Loggable fields.
 */
function logSafeError(e) {
  const isWave = e instanceof WaveApiError || e instanceof WaveValidationError;
  return {
    error: isWave ? sanitizeError(e) : String(e),
    errorDetail: describeWaveError(e),
  };
}

/**
 * Pushes pending outbox jobs to Wave for the interactive sync, then counts
 * what is still queued.
 *
 * Best-effort by design: this half is a courtesy — the `waveUpsertCustomer`
 * trigger already pushed each edit as it was made, and the daily sweep retries
 * whatever is left — so a drain failure must not fail the sync the admin asked
 * for. The import that follows is the part allowed to throw. The
 * two steps are caught separately on purpose: the pending count matters MORE
 * when the drain failed, since it is the only thing that then tells the admin
 * work is still outstanding.
 *
 * @param {{businessId: string, uid: string}} params Connected business id and
 *   the calling admin's uid (for the failure log only).
 * @return {!Promise<{created: number, updated: number, pending: number,
 *   failed: number, incomplete: boolean}>} What landed in Wave, what is still
 *   queued, what dead-lettered, and whether the drain itself threw.
 */
async function drainForSync({businessId, uid}) {
  const result =
    {created: 0, updated: 0, pending: 0, failed: 0, incomplete: false};
  try {
    // No `graphql`/`upsertCustomer` — drainQueue defaults to the real Wave
    // client and WAVE_FULL_ACCESS_TOKEN is in scope via the callable's
    // `secrets` binding, same as the other two drain sites.
    const drained = await drainQueue({
      businessId,
      batchLimit: SYNC_PUSH_BATCH_LIMIT,
      deadlineMs: Date.now() + SYNC_PUSH_BUDGET_MS,
    });
    result.created = drained.created;
    result.updated = drained.updated;
    // Dead-lettered jobs are NOT queued and will never retry, so without
    // this the admin is told "already up to date" about clients that can
    // now only reach Wave by hand.
    result.failed = drained.dead;
  } catch (e) {
    // `incomplete` is what stops the notice reporting an all-zero drain as
    // "everything was already up to date" — a broken push and a quiet queue
    // produce identical counters, and only one of them is good news.
    result.incomplete = true;
    logger.warn("WAVE-CUST sync push failed",
        {uidHash: shortHash(uid), ...logSafeError(e)});
  }

  // Counted AFTER the drain, so the number is what the admin still has to
  // wait for. Without it a 3-of-200 drain would report "3 added to Wave" and
  // read as a finished sync.
  try {
    result.pending = await countQueuedJobs();
  } catch (e) {
    result.incomplete = true;
    logger.warn("WAVE-CUST sync pending count failed",
        {uidHash: shortHash(uid), error: String(e)});
  }
  return result;
}

module.exports = {
  connectionFieldsOf,
  readWaveConnection,
  readWaveBusinessId,
  readWaveBusinessIdCached,
  importWithWatermark,
  drainForSync,
  SYNC_PUSH_BATCH_LIMIT,
  SYNC_PUSH_BUDGET_MS,
};
