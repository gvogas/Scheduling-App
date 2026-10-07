/**
 * Pure rules behind the `usersByUid` bridge — the collection every
 * `firestore.rules` gate resolves a caller's role through.
 *
 * Dependency-free (no firebase-admin, no firebase-functions), the same split
 * `notification_policy.js` took out of `notification_utils.js` and
 * `maintenance_policy.js` out of `maintenance.js`, and for the same reason:
 * `scripts/backfill.js` is the only script in this repo that DELETES from
 * this collection, and it could not be tested while these decisions lived
 * inside a module that resolves prod credentials at load.
 *
 * `bridge.js` (the trigger) and `scripts/backfill.js` (the one-off repair)
 * both require this. They previously carried byte-identical copies of
 * `shouldHaveBridge`, `VALID_ROLES` and `VALID_BRIDGE_STATUS`, under a
 * comment in the script asserting the duplication was deliberate because
 * "folding the role check in up front lets us skip malformed docs outright" —
 * a divergence that stopped existing once `bridge.js` gained the same role
 * check. Keep them on this one owner rather than restoring either copy.
 */

const VALID_ROLES = new Set(["admin", "employee"]);
const VALID_BRIDGE_STATUS = new Set(["active", "disabled"]);

/**
 * True when a users doc should have a bridge row — suppressed for invited
 * users (no uid yet), unknown statuses, and unknown roles.
 *
 * The role check FAILS CLOSED on a missing role: `bridgeBody` writes `role`
 * unconditionally and `initializeApp()` sets no `ignoreUndefinedProperties`,
 * so letting a roleless doc through made the Admin SDK throw inside a
 * `retry: true` trigger — the bridge was then never written and every rules
 * gate resolving through it failed for that person. Only a console or
 * Admin-SDK write can produce such a doc.
 *
 * @param {?Object} data User document fields.
 * @return {boolean}
 */
function shouldHaveBridge(data) {
  if (!data) return false;
  const uid = data.uid;
  if (typeof uid !== "string" || uid === "") return false;
  if (!VALID_BRIDGE_STATUS.has(data.status)) return false;
  if (!VALID_ROLES.has(data.role)) return false;
  return true;
}

/**
 * The three fields the bridge mirrors — the whole document body.
 * @param {string} userId Firestore doc id of the users doc.
 * @param {!Object} data User document fields.
 * @return {{role: string, docId: string, status: string}}
 */
function bridgeBody(userId, data) {
  return {
    role: data.role,
    docId: userId,
    status: data.status,
  };
}

/**
 * True when the stored bridge row already says exactly what we would write.
 * @param {?Object} stored The bridge doc's current fields, or undefined.
 * @param {{role: string, docId: string, status: string}} body Target body.
 * @return {boolean}
 */
function bridgeMatches(stored, body) {
  if (!stored) return false;
  return stored.role === body.role &&
      stored.docId === body.docId &&
      stored.status === body.status;
}

/**
 * What a backfill run should do with one existing `usersByUid/{uid}` row.
 *
 * This is the decision guarding the only destructive write in
 * `functions/scripts/`, and the three outcomes are NOT interchangeable:
 *
 * - `"current"` — a users doc this run wrote or verified claims the uid.
 *   Leave it; there is nothing to decide.
 * - `"retained"` — the uid is claimed by a users doc the run SKIPPED
 *   (invited, no uid, or a malformed role/status). **Not an orphan.**
 *   Deleting it locks a live employee out of everything, and what such a
 *   row should say belongs to the `syncUsersByUid` trigger, not to a
 *   one-off script — which is why the trigger's own role guard logs and
 *   returns without touching the bridge.
 * - `"orphan"` — no users doc anywhere carries this uid. Only this outcome
 *   is ever eligible for deletion, and only then behind `--prune-orphans`.
 *
 * @param {string} uid The bridge document id.
 * @param {{expectedUids: !Set<string>, claimedUids: !Set<string>}} sets
 *   `expectedUids` are the uids this run wrote or verified; `claimedUids` is
 *   every uid ANY users doc carries, skipped docs included.
 * @return {string} "current" | "retained" | "orphan".
 */
function classifyBridgeRow(uid, {expectedUids, claimedUids}) {
  if (expectedUids.has(uid)) return "current";
  if (claimedUids.has(uid)) return "retained";
  return "orphan";
}

module.exports = {
  shouldHaveBridge,
  bridgeBody,
  bridgeMatches,
  classifyBridgeRow,
};
