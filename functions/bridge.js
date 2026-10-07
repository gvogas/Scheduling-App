const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");

const {reconcileBridge, reconcileAuthAccess} = require("./bridge_reconcile");

/**
 * True when the user doc was deleted or an active account was deactivated —
 * coordinates are PII and must not outlive the account.
 * @param {?object} beforeData user doc fields before the write, or null.
 * @param {?object} afterData user doc fields after the write, or null.
 * @return {boolean}
 */
function shouldPurgePresence(beforeData, afterData) {
  if (!beforeData) return false;
  if (!afterData) return true;
  return beforeData.status === "active" && afterData.status !== "active";
}

/**
 * Decides whether to revoke or restore the user's Auth credential — the
 * Firestore `status` field alone never blocked sign-in on its own.
 * `"restore"` also safely no-ops on first activation (invited->active).
 * @param {?object} beforeData user doc fields before the write, or null.
 * @param {?object} afterData user doc fields after the write, or null.
 * @return {?string} "revoke" | "restore" | null.
 */
function authAccessChange(beforeData, afterData) {
  // Deleted doc, or active account leaving active — mirrors shouldPurgePresence
  // so access and PII are revoked by the same rule.
  if (beforeData && (!afterData ||
      (beforeData.status === "active" && afterData.status !== "active"))) {
    return "revoke";
  }
  if (afterData && afterData.status === "active" &&
      (!beforeData || beforeData.status !== "active")) {
    return "restore";
  }
  return null;
}

/**
 * Applies [authAccessChange]'s decision to the Auth account. It's idempotent,
 * and if the user is already gone (removed by account deletion), we swallow
 * that instead of retrying forever.
 * @param {string} uid Firebase Auth uid.
 * @param {string} change "revoke" | "restore".
 * @param {!Object} auth Admin Auth instance.
 * @return {!Promise<void>}
 */
async function applyAuthAccess(uid, change, auth) {
  try {
    if (change === "revoke") {
      await auth.updateUser(uid, {disabled: true});
      // Stops new ID tokens. An already-issued one stays valid until it
      // expires (<=1 h), but the firestore.rules status gate blocks reads
      // during that window.
      await auth.revokeRefreshTokens(uid);
    } else {
      await auth.updateUser(uid, {disabled: false});
    }
  } catch (err) {
    if (err && err.code === "auth/user-not-found") {
      logger.debug("syncUsersByUid: no auth user to update", {change});
      return;
    }
    throw err;
  }
}

/**
 * Deletes every push/Live-Activity delivery artifact for a user — FCM/Live
 * Activity token rows plus the card marker. It's idempotent since deleting a
 * doc that's already gone is a no-op.
 * @param {!Object} db Firestore instance.
 * @param {string} userId Firestore doc id of the user.
 * @return {!Promise<void>}
 */
async function purgeDeliveryState(db, userId) {
  // recursiveDelete paginates internally so a user with >500 stale token rows
  // can't fail partway — same primitive account.js uses.
  const subcollections = ["fcmTokens", "liveActivityTokens"];
  for (const name of subcollections) {
    await db.recursiveDelete(db.collection(`users/${userId}/${name}`));
  }
  await db.collection("liveActivityCards").doc(userId).delete();
}

// Event snapshots identify affected uids; only live profiles grant access.
const syncUsersByUid = onDocumentWritten(
    {document: "users/{userId}", retry: true},
    async (event) => {
      const userId = event.params.userId;
      const before = event.data?.before?.exists ?
        event.data.before.data() : null;
      const after = event.data?.after?.exists ? event.data.after.data() : null;
      if (before && after && before.role === after.role &&
          before.status === after.status && before.uid === after.uid) return;

      const db = getFirestore();
      const beforeUid = typeof before?.uid === "string" ? before.uid : "";
      const afterUid = typeof after?.uid === "string" ? after.uid : "";
      const current = await reconcileBridge(db, userId, [beforeUid, afterUid]);

      // A delayed deactivation must not erase a reactivated device's tokens.
      if (shouldPurgePresence(before, after) && current?.status !== "active") {
        try {
          await db.doc(`users/${userId}/presence/location`).delete();
          await purgeDeliveryState(db, userId);
        } catch (err) {
          logger.warn("syncUsersByUid: presence purge failed", {
            userId, error: err.message,
          });
          throw err;
        }
      }

      if (authAccessChange(before, after)) {
        const uid = current?.uid || afterUid || beforeUid;
        if (uid) {
          try {
            await reconcileAuthAccess(db, userId, uid,
                (id, change) => applyAuthAccess(id, change, getAuth()));
          } catch (err) {
            logger.warn("syncUsersByUid: auth access update failed", {
              userId, error: err.message,
            });
            throw err;
          }
        }
      }
    },
);

module.exports = {
  syncUsersByUid,
  shouldPurgePresence,
  authAccessChange,
  applyAuthAccess,
};
