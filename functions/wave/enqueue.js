"use strict";

/**
 * @fileoverview Putting a client's Wave write-back INTO the outbox: the enqueue
 * decision, the enqueue itself, and cancelling a job still waiting.
 * @module wave/enqueue
 */

const {adminFirestore} = require("../admin_firestore");
const {mappedFieldsHash} = require("./mappers");
const {QUEUE_COLLECTION, customerUpsertJobId} = require("./outbox_keys");

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

  const jobId = customerUpsertJobId(clientId);
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
      .doc(customerUpsertJobId(clientId));

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap || !snap.exists) return false;
    const data = snap.data() || {};
    if (data.status !== "queued") return false;
    tx.delete(ref);
    return true;
  });
}

module.exports = {
  shouldEnqueueClientWrite,
  enqueueCustomerUpsert,
  cancelCustomerUpsert,
};
