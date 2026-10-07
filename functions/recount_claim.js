"use strict";

/**
 * @fileoverview The claim ledger that collapses one batch's N recount triggers
 * into one aggregate write.
 * ONE owner, because the RELEASE-BEFORE-AGGREGATE ordering is the whole design
 * and is silent when wrong. Two counters need it — appointment `pictureCount`
 * (a photo batch writes N image docs under one parent) and client `jobCount`
 * (a run or repeat series writes up to 16 appointments carrying one clientId)
 * — and a second hand-written copy is a second chance to get that order, the
 * staleness takeover, or the fail-open backwards.
 * Every body takes an injected `db`, in the same shape as
 * `maintenance_policy.js`, so the protocol is testable without emulator
 * credentials.
 * @module recount_claim
 */

// One owner, shared with `notification_policy`: both guard a `create()`-based
// at-most-once ledger, and fixing one and not the other yields a duplicate push
// or a suppressed recount, invisibly.
const {ALREADY_EXISTS, isAlreadyExists} = require("./firestore_errors");
const {toMillis} = require("./time_utils");

/**
 * A claim older than this is presumed abandoned (an invocation killed between
 * claiming and releasing) and is taken over.
 */
const CLAIM_STALE_MS = 15 * 1000;

/** Absolute lifetime stamped on `expiresAt` for the Firestore TTL policy. */
const CLAIM_TTL_MS = 5 * 60 * 1000;

/**
 * The body every claim is written with.
 * @param {!Date} nowDate
 * @return {{claimedAt: !Date, expiresAt: !Date}}
 */
function claimBody(nowDate) {
  return {
    claimedAt: nowDate,
    expiresAt: new Date(nowDate.getTime() + CLAIM_TTL_MS),
  };
}

/**
 * Claims `key` in `collection`.
 * @param {string} collection Claim ledger collection.
 * @param {string} key Document id to claim.
 * @param {!Object} deps `{db, logger, now}`.
 * @return {!Promise<boolean>} True when this invocation owns the recount.
 */
async function claimRecount(collection, key, deps) {
  const {db, logger: log, now} = deps;
  const nowDate = now || new Date();
  // Inside the try: `.doc()` throws SYNCHRONOUSLY on a reserved id ("."/".."),
  // and the fail-open contract above has to cover that too — otherwise the one
  // error that precedes the guard is the one it doesn't catch.
  let ref;
  try {
    ref = db.collection(collection).doc(key);
    await ref.create(claimBody(nowDate));
    return true;
  } catch (err) {
    if (!isAlreadyExists(err)) {
      if (log) log.warn("recount claim failed; recounting anyway", {err});
      return true;
    }
  }
  // A claim exists. Take over one older than the window so an invocation killed
  // between claiming and releasing can't suppress recounts until the TTL policy
  // gets round to it — and so a genuinely later write always recounts.
  try {
    const snap = await ref.get();
    // `toMillis` from time_utils, not a fourth inline spelling: this one had no
    // number branch, so a claim stamped as epoch ms read as "no stamp" and was
    // taken over immediately.
    const claimedMs = toMillis(snap.get("claimedAt"));
    if (claimedMs != null &&
        nowDate.getTime() - claimedMs < CLAIM_STALE_MS) {
      return false;
    }
    await ref.set(claimBody(nowDate));
    return true;
  } catch (err) {
    if (log) {
      log.warn("recount claim takeover failed; recounting anyway", {err});
    }
    return true;
  }
}

/**
 * Releases this invocation's claim.
 * @param {string} collection Claim ledger collection.
 * @param {string} key Document id to release.
 * @param {!Object} deps `{db, logger}`.
 * @return {!Promise<void>}
 */
async function releaseRecount(collection, key, deps) {
  const {db, logger: log} = deps;
  try {
    await db.collection(collection).doc(key).delete();
  } catch (err) {
    if (log) log.warn("recount claim release failed", {err});
  }
}

/**
 * Claims `key`, settles to absorb the rest of the batch, releases, then runs
 * `recount`.
 * @param {string} collection Claim ledger collection.
 * @param {string} key Document id to debounce on.
 * @param {function(): !Promise<*>} recount The aggregate to run once.
 * @param {!Object} deps `{db, logger, now, sleep, settleMs}`.
 * @return {!Promise<{skipped: boolean, result: *}>}
 */
async function debounceRecount(collection, key, recount, deps) {
  const mine = await claimRecount(collection, key, deps);
  if (!mine) return {skipped: true, result: null};
  const sleep = deps.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
  const settleMs = deps.settleMs == null ? 2000 : deps.settleMs;
  await sleep(settleMs);
  await releaseRecount(collection, key, deps);
  const result = await recount();
  return {skipped: false, result};
}

module.exports = {
  claimRecount,
  releaseRecount,
  debounceRecount,
  isAlreadyExists,
  CLAIM_STALE_MS,
  CLAIM_TTL_MS,
  ALREADY_EXISTS,
};
