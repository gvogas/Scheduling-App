"use strict";

/**
 * @fileoverview Admin-only client deletion. A client is normally ARCHIVED, not
 * deleted; delete exists for junk data only and is refused for any client that
 * still has appointments, since deleting one orphans that history (the visits
 * keep a denormalized `clientName` but lose the `clientId` link). `allow
 * delete` on `/clients` is withdrawn in `firestore.rules`, so this callable is
 * the only delete path — rules cannot express "only when this client has no
 * appointments" (there is no cheap way to count a foreign collection there).
 * @module clients
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");
const {randomUUID} = require("node:crypto");

const {
  requireDocId,
  assertAdminCall,
  enforceDurableRateLimit,
  shortHash,
  APP_CHECK,
} = require("./security");

const DELETE_RATE_MAX = 20;
const DELETE_RATE_WINDOW_MS = 60 * 60 * 1000;

/**
 * Deletes a client, refusing when it still has appointments.
 * @param {*} db Firestore instance.
 * @param {string} clientId Client doc id.
 * @return {!Promise<void>}
 */
async function performDeleteClient(db, clientId) {
  const ref = db.collection("clients").doc(clientId);
  // A new attempt may take over a crashed attempt, but only the current owner
  // may delete or release the barrier. Booking rules read this same document.
  const token = randomUUID();
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "client-not-found");
    tx.update(ref, {deletionToken: token});
  });

  try {
    const agg = await db
        .collection("appointments")
        .where("clientId", "==", clientId)
        .count()
        .get();
    if (agg.data().count > 0) {
      throw new HttpsError("failed-precondition", "client-has-history");
    }
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return;
      if (snap.data().deletionToken !== token) {
        throw new HttpsError("aborted", "client-delete-superseded");
      }
      tx.delete(ref);
    });
  } catch (error) {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.exists && snap.data().deletionToken === token) {
        tx.update(ref, {deletionToken: ""});
      }
    });
    throw error;
  }
}

// Guard order per .claude/rules/security.md: auth -> assertAdmin -> payload ->
// rate limit -> work.
const deleteClient = onCall(APP_CHECK, async (req) => {
  await assertAdminCall(req, new Set(["clientId"]));
  const clientId = requireDocId(req.data, "clientId");
  await enforceDurableRateLimit(
      "deleteClient", req.auth.uid, DELETE_RATE_MAX, DELETE_RATE_WINDOW_MS);

  await performDeleteClient(getFirestore(), clientId);
  logger.info("deleteClient: deleted", {
    uidHash: shortHash(req.auth.uid),
    clientId,
  });
});

module.exports = {deleteClient, performDeleteClient};
