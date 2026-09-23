"use strict";

const {HttpsError} = require("firebase-functions/v2/https");
const {FieldValue} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

/**
 * Serializes credential writes across containers. No expiring lease: Auth
 * cannot check a fencing token, so a timed-out writer must never overlap a
 * replacement. A terminated invocation leaves a lock for operator recovery.
 * @param {!Object} db Firestore.
 * @param {string} uid Auth uid.
 * @param {string} operation Non-sensitive operation name.
 * @param {!Function} work Work held under the lock.
 * @return {!Promise<*>} Work result.
 */
async function withAccountOperation(db, uid, operation, work) {
  const ref = db.collection("accountOperations").doc(uid);
  try {
    await ref.create({operation, createdAt: FieldValue.serverTimestamp()});
  } catch (error) {
    if (error.code === 6 || error.code === "already-exists") {
      throw new HttpsError("aborted", "account-operation-in-progress");
    }
    throw error;
  }
  try {
    return await work();
  } finally {
    // Do not turn successful provisioning into a rollback if only release
    // fails. The retained lock fails closed until an operator clears it.
    await ref.delete().catch(() => {
      logger.error("Account operation lock needs recovery", {uid, operation});
    });
  }
}

module.exports = {withAccountOperation};
