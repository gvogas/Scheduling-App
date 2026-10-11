"use strict";

/**
 * @fileoverview Reads and prunes the Live Activity token registry at
 * `users/{docId}/liveActivityTokens/{activityId}` (doc id = ActivityKit
 * activity id). The client writes its own rows only; we read across
 * employees here via `collectionGroup`.
 *
 * Deps are injected (`{db, now, logger}`) so jest can drive this without
 * firebase-admin. Every export here is also best-effort — a failed read just
 * returns `[]` and the caller degrades to the plain `leaveNow` push.
 *
 * This module also owns the card marker at
 * `liveActivityCards/{employeeDocId}`, the Admin-SDK-only record of which
 * appointment a tech's live card is showing. We need that marker because a
 * push-started activity's id is minted by ActivityKit, and the device has no
 * way to stamp `appointmentId` back onto its own token row.
 *
 * @module live_activity_registry
 */

// live_activity_utils only requires time_utils, so this closes no cycle.
const {PHASE_TRAVEL} = require("./live_activity_utils");

const KIND_PUSH_TO_START = "pushToStart";
const KIND_UPDATE = "update";

const CARDS_COLLECTION = "liveActivityCards";

// A card outlives its job by at most a few hours. This is the marker's own
// TTL backstop for the case where no end push ever lands.
const CARD_TTL_MS = 12 * 60 * 60 * 1000;

// Firestore caps an `in` filter at 30 values — same constraint the
// `whereArrayContainsAny` chunking in the appointments repository documents.
const IN_QUERY_MAX = 30;

// Safety valve on a single prune pass so one run can't blow the timeout.
const PRUNE_MAX = 400;

// How many expired rows a prune pass deletes at once. Bounded rather than a
// flat `Promise.all` over the whole page so a full cap doesn't fire 400
// concurrent deletes at Firestore.
const PRUNE_CHUNK = 25;

/**
 * Splits a list into chunks of at most `size`.
 * @param {!Array<*>} list
 * @param {number} size
 * @return {!Array<!Array<*>>}
 */
function _chunk(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) {
    out.push(list.slice(i, i + size));
  }
  return out;
}

/**
 * Flattens one query snapshot into registry rows, keeping `ref` so the caller
 * can prune a dead row without re-deriving a path.
 * @param {*} snap
 * @return {!Array<!Object>}
 */
function _rows(snap) {
  return ((snap && snap.docs) || []).map((d) => ({
    activityId: d.id,
    ref: d.ref,
    ...(d.data() || {}),
  }));
}

/**
 * Runs one collection-group query and never throws.
 * @param {!Object} deps `{db, logger}`.
 * @param {function(!Object): !Object} build Applies the filters.
 * @param {string} label Log label.
 * @return {!Promise<!Array<!Object>>}
 */
async function _query(deps, build, label) {
  const {db, logger} = deps;
  try {
    const snap = await build(db.collectionGroup("liveActivityTokens")).get();
    return _rows(snap);
  } catch (err) {
    if (logger) logger.warn(`liveActivity: ${label} failed`, {err});
    return [];
  }
}

/**
 * The push-to-start tokens for the given employees (one per device, used to
 * start a card on a closed, locked phone), chunked to the Firestore `in` cap.
 * @param {!Object} deps `{db, logger}`.
 * @param {{employeeDocIds: !Array<string>}} args
 * @return {!Promise<!Array<!Object>>}
 */
async function listPushToStartTokens(deps, {employeeDocIds}) {
  const ids = (employeeDocIds || []).filter(Boolean);
  if (ids.length === 0) return [];
  const batches = await Promise.all(_chunk(ids, IN_QUERY_MAX).map((chunk) =>
    _query(
        deps,
        (q) => q
            .where("kind", "==", KIND_PUSH_TO_START)
            .where("employeeDocId", "in", chunk),
        "pushToStart read",
    ),
  ));
  return batches.flat();
}

/**
 * The per-activity update tokens an employee's device(s) registered, keyed by
 * employee (not appointment). Pair this with [readCardMarker] to confirm
 * which appointment the live card is actually showing.
 * @param {!Object} deps `{db, logger}`.
 * @param {{employeeDocId: string}} args
 * @return {!Promise<!Array<!Object>>}
 */
async function listUpdateTokens(deps, {employeeDocId}) {
  if (!employeeDocId) return [];
  return _query(
      deps,
      (q) => q
          .where("kind", "==", KIND_UPDATE)
          .where("employeeDocId", "==", employeeDocId),
      "update-token read",
  );
}

/**
 * Records that this employee's live card now shows `appointmentId`, as an
 * absolute write that fully replaces any previous marker.
 * @param {!Object} deps `{db, now, logger}`.
 * @param {{employeeDocId: string, appointmentId: string, startTime: *,
 *   phase: string}} args
 * @return {!Promise<boolean>}
 */
async function writeCardMarker(
    deps,
    {employeeDocId, appointmentId, startTime, phase, leadMinutes,
      travelMinutes}) {
  const {db, now, logger} = deps;
  if (!employeeDocId || !appointmentId) return false;
  const nowDate = now || new Date();
  try {
    await db.collection(CARDS_COLLECTION).doc(employeeDocId).set({
      employeeDocId,
      appointmentId,
      startTime: startTime || null,
      phase,
      // The sweep's drive estimate, carried so a later reschedule can rebuild
      // a real `leaveAt` off the NEW start instead of falling back to the
      // appointment time (which the card would otherwise label "Leave at").
      // `setCardStart` merges, so a reschedule preserves these.
      leadMinutes: typeof leadMinutes === "number" ? leadMinutes : null,
      travelMinutes: typeof travelMinutes === "number" ? travelMinutes : null,
      startedAt: nowDate,
      expiresAt: new Date(nowDate.getTime() + CARD_TTL_MS),
    });
    return true;
  } catch (err) {
    if (logger) logger.warn("liveActivity: card marker write failed", {err});
    return false;
  }
}

/**
 * The employee's current card marker, or null when no card is live.
 * @param {!Object} deps `{db, logger}`.
 * @param {{employeeDocId: string}} args
 * @return {!Promise<?Object>}
 */
async function readCardMarker(deps, {employeeDocId}) {
  const {db, logger} = deps;
  if (!employeeDocId) return null;
  try {
    const snap = await db
        .collection(CARDS_COLLECTION).doc(employeeDocId).get();
    return snap && snap.exists ? (snap.data() || null) : null;
  } catch (err) {
    if (logger) logger.warn("liveActivity: card marker read failed", {err});
    return null;
  }
}

/**
 * Refreshes the marker's `startTime`/phase after a reschedule. This merges
 * rather than overwriting like `writeCardMarker` does, so `appointmentId`/
 * `startedAt`/`expiresAt` are preserved. Without this, the on-site backstop —
 * which keys its flip off this field — would fire at the old start time.
 * Never throws.
 * @param {!Object} deps `{db, logger}`.
 * @param {{employeeDocId: string, startTime: *, phase: string}} args
 * @return {!Promise<boolean>}
 */
async function setCardStart(deps, {employeeDocId, startTime, phase}) {
  const {db, logger} = deps;
  if (!employeeDocId) return false;
  try {
    await db.collection(CARDS_COLLECTION).doc(employeeDocId)
        .set({startTime: startTime || null, phase}, {merge: true});
    return true;
  } catch (err) {
    if (logger) logger.warn("liveActivity: card start write failed", {err});
    return false;
  }
}

/**
 * Drops the employee's card marker once the card has been ended.
 * @param {!Object} deps `{db, logger}`.
 * @param {{employeeDocId: string}} args
 * @return {!Promise<boolean>}
 */
async function clearCardMarker(deps, {employeeDocId}) {
  const {db, logger} = deps;
  if (!employeeDocId) return false;
  try {
    await db.collection(CARDS_COLLECTION).doc(employeeDocId).delete();
    return true;
  } catch (err) {
    if (logger) logger.warn("liveActivity: card marker clear failed", {err});
    return false;
  }
}

/**
 * Card markers still in the `travel` phase whose `startTime` has passed —
 * the on-site flip backstop's candidate set. Never throws.
 * @param {!Object} deps `{db, now, logger}`.
 * @param {{limit: (number|undefined)}=} args
 * @return {!Promise<!Array<!Object>>}
 */
async function listCardsDueForOnSite(deps, args) {
  const {db, now, logger} = deps;
  const nowDate = now || new Date();
  try {
    // Filtered in the query, not post-limit, so a batch of already-flipped
    // cards can't consume the whole cap and starve the ones actually due.
    const snap = await db
        .collection(CARDS_COLLECTION)
        .where("phase", "==", PHASE_TRAVEL)
        .where("startTime", "<=", nowDate)
        .limit((args && args.limit) || PRUNE_MAX)
        .get();
    return _rows(snap);
  } catch (err) {
    if (logger) logger.warn("liveActivity: on-site query failed", {err});
    return [];
  }
}

/**
 * Deletes one registry row when APNs reports the activity gone (410 /
 * BadDeviceToken) or after the server ends a card. Never throws.
 * @param {!Object} deps `{logger}`.
 * @param {{ref: !Object}} args The `ref` from a listed row.
 * @return {!Promise<boolean>} True when the row is gone.
 */
async function deleteActivityToken(deps, {ref}) {
  if (!ref || typeof ref.delete !== "function") return false;
  try {
    await ref.delete();
    return true;
  } catch (err) {
    if (deps && deps.logger) {
      deps.logger.warn("liveActivity: token delete failed", {err});
    }
    return false;
  }
}

/**
 * Deletes rows of `query` whose `expiresAt` has passed, bounded by `cap` —
 * hitting the cap just defers the remainder to the next run. Never throws.
 * @param {!Object} deps `{now, logger}`.
 * @param {!Object} collection A collection or collection-group ref.
 * @param {number} cap
 * @param {string} label Distinguishes the two sweeps in the warn lines.
 * @return {!Promise<{pruned: number}>}
 */
async function _pruneExpired(deps, collection, cap, label) {
  const {now, logger} = deps;
  let rows = [];
  try {
    const snap = await collection
        .where("expiresAt", "<=", now || new Date())
        .limit(cap)
        .get();
    rows = _rows(snap);
  } catch (err) {
    if (logger) logger.warn(`liveActivity: ${label} prune query failed`, {err});
    return {pruned: 0};
  }
  // Chunked concurrency rather than one round-trip at a time. The expired set
  // is usually tiny, but the loop is bounded by `cap` (400), not by that
  // assumption, and this runs TWICE — tokens and card markers — inside the
  // daily digest invocation, which also carries `runWaveDaily`. The chunk
  // keeps per-row failure isolation (`deleteActivityToken` never throws) and
  // stops a full cap firing 400 deletes at Firestore at once.
  let pruned = 0;
  for (const chunk of _chunk(rows, PRUNE_CHUNK)) {
    const done = await Promise.all(
        chunk.map((row) => deleteActivityToken(deps, row)));
    pruned += done.filter(Boolean).length;
  }
  if (rows.length === cap && logger) {
    logger.warn(`liveActivity: ${label} prune cap hit; deferred`, {cap});
  }
  return {pruned};
}

/**
 * Deletes token rows whose `expiresAt` has passed — the TTL sweep (see the
 * design doc's "Still open" section) for a card the server never got to end.
 * @param {!Object} deps `{db, now, logger}`.
 * @param {{limit: (number|undefined)}=} args
 * @return {!Promise<{pruned: number}>}
 */
function pruneExpiredActivityTokens(deps, args) {
  return _pruneExpired(
      deps,
      deps.db.collectionGroup("liveActivityTokens"),
      (args && args.limit) || PRUNE_MAX,
      "token",
  );
}

/**
 * Deletes card markers whose `expiresAt` has passed — the backstop for a card
 * that was started but whose end push never landed.
 * @param {!Object} deps `{db, now, logger}`.
 * @param {{limit: (number|undefined)}=} args
 * @return {!Promise<{pruned: number}>}
 */
function pruneExpiredCardMarkers(deps, args) {
  return _pruneExpired(
      deps,
      deps.db.collection(CARDS_COLLECTION),
      (args && args.limit) || PRUNE_MAX,
      "card",
  );
}

module.exports = {
  KIND_PUSH_TO_START,
  KIND_UPDATE,
  CARDS_COLLECTION,
  // The three below are exported for unit tests, which assert against the
  // constants rather than restating their literals — same convention as
  // employee_accounts_admin.js.
  IN_QUERY_MAX,
  PRUNE_MAX,
  CARD_TTL_MS,
  listPushToStartTokens,
  listUpdateTokens,
  deleteActivityToken,
  pruneExpiredActivityTokens,
  writeCardMarker,
  readCardMarker,
  setCardStart,
  clearCardMarker,
  listCardsDueForOnSite,
  pruneExpiredCardMarkers,
};
