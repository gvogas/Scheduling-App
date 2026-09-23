"use strict";

const {
  shouldHaveBridge, bridgeBody, bridgeMatches,
} = require("./bridge_policy");

/**
 * Reconciles authorization against the live profile under a transaction lock.
 * @param {!Object} db Firestore instance.
 * @param {string} userId User document id.
 * @param {!Array<string>} eventUids Uids mentioned by the triggering event.
 * @return {!Promise<?Object>} Current user fields.
 */
async function reconcileBridge(db, userId, eventUids) {
  return db.runTransaction(async (tx) => {
    const source = await tx.get(db.doc(`users/${userId}`));
    const current = source.exists ? source.data() : null;
    const currentUid = typeof current?.uid === "string" ? current.uid : "";
    const uids = [...new Set([...eventUids, currentUid].filter(Boolean))];
    const refs = uids.map((uid) => db.collection("usersByUid").doc(uid));
    const snapshots = await Promise.all(refs.map((ref) => tx.get(ref)));
    for (let i = 0; i < uids.length; i++) {
      const stored = snapshots[i].exists ? snapshots[i].data() : null;
      // Delayed events cannot remove another profile's bridge.
      if (stored && stored.docId !== userId) {
        if (uids[i] === currentUid && shouldHaveBridge(current)) {
          throw new Error("syncUsersByUid: uid belongs to another profile");
        }
        continue;
      }
      if (uids[i] === currentUid && shouldHaveBridge(current)) {
        const body = bridgeBody(userId, current);
        if (!bridgeMatches(stored, body)) tx.set(refs[i], body);
      } else if (stored) {
        tx.delete(refs[i]);
      }
    }
    return current;
  });
}

/**
 * Rechecks the profile after Auth writes, which cannot join a transaction.
 * @param {!Object} db Firestore instance.
 * @param {string} userId User document id.
 * @param {string} uid Auth account to reconcile.
 * @param {function(string, string): !Promise<void>} apply Applies Auth access.
 * @return {!Promise<void>}
 */
async function reconcileAuthAccess(db, userId, uid, apply) {
  const ref = db.doc(`users/${userId}`);
  for (let attempt = 0; attempt < 3; attempt++) {
    const snap = await ref.get();
    const current = snap.exists ? snap.data() : null;
    if (current && (current.uid !== uid || current.status === "invited")) {
      return;
    }
    const bridge = await db.collection("usersByUid").doc(uid).get();
    if (bridge.exists && bridge.data().docId !== userId) return;
    const change = current?.status === "active" ? "restore" : "revoke";
    await apply(uid, change);
    const latest = await ref.get();
    const after = latest.exists ? latest.data() : null;
    if (current?.uid === after?.uid && current?.status === after?.status) {
      return;
    }
  }
  throw new Error("syncUsersByUid: profile changed during Auth reconciliation");
}

module.exports = {reconcileBridge, reconcileAuthAccess};
