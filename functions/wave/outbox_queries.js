"use strict";

/**
 * @fileoverview Reading and recovering the outbox as a whole: the two counters
 * Settings shows, the "Retry failed" requeue, and the import's protect-list.
 * @module wave/outbox_queries
 */

const {adminFirestore} = require("../admin_firestore");
const {buildCustomerPayload, verdictPatch} = require("./customer_contract");
const {
  QUEUE_COLLECTION,
  OUTSTANDING_STATUSES,
  clientIdFromRefPath,
} = require("./outbox_keys");

// Cap on the dead-job requeue and the import's protect-list read.
const OUTSTANDING_MAX = 2000;

/** How many requeue transactions run concurrently. */
const REQUEUE_CHUNK = 25;

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
            const contract = buildCustomerPayload(clientData);
            if (!contract.ok) {
              tx.update(clientRef, verdictPatch(contract));
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
      .where("status", "in", OUTSTANDING_STATUSES)
      .limit(limit)
      .get();
  const docs = (snap && snap.docs) || [];
  const ids = new Set();
  for (const doc of docs) {
    const id = clientIdFromRefPath((doc.data() || {}).refPath);
    if (id) ids.add(id);
  }
  // A truncated list only costs transactions: the import re-checks each write.
  if (docs.length >= limit) {
    const log = deps.logger || require("firebase-functions/logger");
    log.warn("WAVE-WORKER outstanding protect-list hit its cap; the import " +
        "checks the rest inside its own write transactions", {
      limit,
      protectedIds: ids.size,
    });
  }
  return ids;
}

module.exports = {
  countQueuedJobs,
  countDeadJobs,
  requeueDeadJobs,
  listOutstandingClientIds,
};
