"use strict";

/**
 * @fileoverview Maintains the denormalized `jobCount` on client docs.
 *
 * The count is recomputed with a Firestore `count()` aggregate and written
 * ABSOLUTELY — never `FieldValue.increment`. This trigger runs with
 * `retry: true`, and a retried event would double-count an increment; an
 * absolute write is idempotent by construction. Same principle as
 * `propagateClientEdits`.
 *
 * Cost is ~1 aggregate read per appointment write that creates, deletes or
 * reassigns a job. Backfill is lazy: a client's count self-heals on its next
 * appointment write, and a row renders no count until the field exists.
 *
 * @module client_job_count
 */

const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const {debounceRecount} = require("./recount_claim");
const {isCancelledStatus} = require("./time_utils");
const {adminFirestore} = require("./admin_firestore");

/** Firestore `NOT_FOUND` — the client was deleted out from under the job. */
const NOT_FOUND = 5;

/**
 * Reads a doc's `clientId` as a non-empty trimmed string, or "".
 * @param {?Object} data Appointment document fields, or null.
 * @return {string}
 */
function clientIdOf(data) {
  if (!data) return "";
  const raw = data.clientId;
  const id = typeof raw === "string" ? raw.trim() : "";
  // A "/", "." or ".." would make doc() throw synchronously, and this trigger
  // is retry:true — an unhandled throw becomes a redelivery storm on one
  // poisoned event. `isValidDocIdField` in firestore.rules screens `clientId`
  // on the app's paths, but the Admin SDK and the console bypass rules
  // entirely, so a malformed clientId can still reach here.
  if (id.includes("/") || id === "." || id === "..") return "";
  return id;
}

/**
 * Which client docs need their `jobCount` recomputed after this write.
 *
 * Creates and deletes touch one client; a reassignment touches both. Personal
 * jobs carry no `clientId` and are skipped.
 *
 * An unchanged `clientId` ALSO recounts when the job's cancelled-ness flipped,
 * because the aggregate excludes cancelled jobs — without this the count only
 * corrects itself on some later write that happens to move `clientId`, so a
 * cancellation left the client reading one job too many indefinitely. The gate
 * is cancelled-ness and NOT "the status changed", so an ordinary
 * `pending -> done` edit still costs zero reads.
 *
 * @param {?Object} beforeData Appointment fields before the write, or null.
 * @param {?Object} afterData Appointment fields after the write, or null.
 * @return {!Array<string>} Deduped client doc ids, possibly empty.
 */
function clientsToRecount(beforeData, afterData) {
  const before = clientIdOf(beforeData);
  const after = clientIdOf(afterData);
  if (before === after) {
    if (!after) return [];
    const wasCancelled = isCancelledStatus(beforeData && beforeData.status);
    const isCancelled = isCancelledStatus(afterData && afterData.status);
    return wasCancelled === isCancelled ? [] : [after];
  }
  const ids = [];
  if (before) ids.push(before);
  if (after) ids.push(after);
  return ids;
}

/**
 * The `jobCount` this client's appointments add up to.
 *
 * Exported because `scripts/recount-client-jobs.js` has to answer exactly the
 * same question for the backfill, and a second spelling of the
 * inclusion-exclusion below is a backfill that disagrees with the trigger —
 * which would look like the trigger being broken, on whichever clients the
 * script had touched most recently.
 *
 * @param {!Object} db Firestore instance.
 * @param {string} clientId Client doc id.
 * @return {!Promise<number>}
 */
async function countJobsFor(db, clientId) {
  const base = db.collection("appointments").where("clientId", "==", clientId);
  // A multi-day run is ONE job stored as one document per work day, so a
  // document count would read 5 for a Monday-to-Friday booking — on a badge
  // captioned "jobs". The later days are exactly the documents carrying
  // `dayIndex > 1`: a single-day job omits the field entirely and day 1 stores
  // 1, and an inequality filter excludes a document missing the field, so this
  // subtraction needs no backfill and no per-document read. Served by the
  // (clientId ASC, dayIndex ASC) composite.
  // Cancelled visits are not jobs. Subtracting them — rather than filtering to
  // an allowlist of live statuses — is what keeps a legacy `confirmed` or a
  // doc with no status counted, which fails in the safe direction.
  //
  // The fourth term is the inclusion-exclusion correction, not a guard: one
  // live 5-day run plus one cancelled 5-day run is 10 - 8 - 5 = -3 without it,
  // and the right answer is 1, so clamping at 0 would also be wrong.
  //
  // Accepted limitation: a Firestore `where` cannot lowercase, so a
  // console- or Admin-SDK-written "Cancelled" still counts.
  // `isValidAppointmentStatus` holds every CLIENT write to the lowercase set.
  const laterRunDaysOf = (q) => q.where("dayIndex", ">", 1);
  const cancelledOf = (q) => q.where("status", "==", "cancelled");
  const [total, laterRunDays, cancelled, cancelledLaterRunDays] =
    await Promise.all([
      base.count().get(),
      laterRunDaysOf(base).count().get(),
      cancelledOf(base).count().get(),
      laterRunDaysOf(cancelledOf(base)).count().get(),
    ]);
  return (
    total.data().count -
    laterRunDays.data().count -
    cancelled.data().count +
    cancelledLaterRunDays.data().count
  );
}

/**
 * Recomputes and writes `jobCount` for one client.
 * @param {!Object} db Firestore instance.
 * @param {string} clientId Client doc id.
 * @return {!Promise<void>}
 */
async function recountOne(db, clientId) {
  const jobCount = await countJobsFor(db, clientId);
  try {
    // update(), not set({merge:true}) — a client removed out-of-band (the app
    // has no delete path, but the Admin SDK and console bypass that) must not
    // be resurrected as a stub doc holding nothing but a count.
    await db.collection("clients").doc(clientId).update({jobCount});
  } catch (err) {
    if (err && err.code === NOT_FOUND) return;
    throw err;
  }
}

/**
 * Admin-SDK-only claim ledger that collapses one booking batch's N recounts
 * into one aggregate per client. Nothing client-side may read or write it.
 */
const CLIENT_RECOUNT_CLAIMS = "clientRecountClaims";

/**
 * How long the claiming invocation waits before recounting, to absorb the rest
 * of its batch's triggers. A multi-day run commits up to 14 day-documents (a
 * repeat series up to 16) in ONE batch, every one carrying the same
 * `clientId` — so without this, one Save fired 14-16 `count()` aggregates and
 * 14-16 writes at the SAME client doc within milliseconds, against Firestore's
 * ~1 write/sec/document guidance, and each of those writes re-fired
 * `propagateClientEdits`. Correctness never depends on this number: see
 * `debounceRecount` for why the release/aggregate order is what matters.
 */
const RECOUNT_SETTLE_MS = 2000;

/**
 * True when this appointment can be one of a BATCH of writes that share a
 * `clientId` — the only case the debounce above is worth paying for.
 *
 * The debounce costs `RECOUNT_SETTLE_MS` of BILLED wall-clock plus a claim
 * `create()` and `delete()`, so on an ordinary single create or delete it
 * takes the write from 2 Firestore writes to 4 and adds 2 s to the
 * invocation — doubling the common path to save on the rare one. The batch it
 * absorbs is only reachable two ways, and both are stamped on the document
 * itself, so no extra read is needed to tell them apart:
 *
 * - a multi-day RUN, which commits one day-document per day (`dayCount` > 1);
 * - a REPEAT series, whose occurrences all carry the root's id in `seriesId`.
 *
 * `seriesId` is tested for merely being non-empty, NOT for differing from this
 * document's own id: `add_event_controller.dart` writes the series ROOT in the
 * same `WriteBatch` as its siblings and gives it `seriesId == its own id`, so
 * excluding it would leave the root recounting alone and its siblings
 * collapsing to a second recount — two aggregates where the point is one.
 *
 * Errs toward debouncing: a false positive costs the old behaviour, while a
 * false negative is the 14-16 same-document writes/second this exists to stop.
 * @param {?Object} data Appointment fields, or null.
 * @return {boolean}
 */
function mayShareABatch(data) {
  if (!data) return false;
  const dayCount = Number(data.dayCount);
  if (Number.isFinite(dayCount) && dayCount > 1) return true;
  return typeof data.seriesId === "string" && data.seriesId.trim() !== "";
}

const recountClientJobs = onDocumentWritten(
    {
      document: "appointments/{appointmentId}",
      region: "us-central1",
      // Safe to retry: every write is an absolute recount.
      retry: true,
    },
    async (event) => {
      const before = event.data && event.data.before;
      const after = event.data && event.data.after;
      const beforeData = before && before.exists ? before.data() : null;
      const afterData = after && after.exists ? after.data() : null;
      const ids = clientsToRecount(beforeData, afterData);
      if (ids.length === 0) return;

      // A delete leaves only `before` to read the batch markers off.
      const batched = mayShareABatch(afterData || beforeData);
      const db = adminFirestore().getFirestore();
      // The two ids of a reassignment are independent client docs — run them
      // concurrently rather than paying two serial round trips of billed time.
      await Promise.all(ids.map(async (clientId) => {
        try {
          if (batched) {
            await debounceRecount(
                CLIENT_RECOUNT_CLAIMS,
                clientId,
                () => recountOne(db, clientId),
                {db, logger, settleMs: RECOUNT_SETTLE_MS},
            );
          } else {
            await recountOne(db, clientId);
          }
        } catch (err) {
          logger.error("recountClientJobs failed", {clientId, err});
          throw err;
        }
      }));
    },
);

module.exports = {
  clientsToRecount,
  mayShareABatch,
  recountClientJobs,
  // Exported so the adapter test can assert the ledger this debounces in. The
  // name has to match the deny-all block in `firestore.rules` AND the TTL
  // policy in `firestore.indexes.json`, and a typo in it is silent: the claim
  // fails open on every call and the debounce simply never engages.
  CLIENT_RECOUNT_CLAIMS,
  RECOUNT_SETTLE_MS,
  // Exported for __tests__/client_job_count.test.js. Both of its decisions —
  // update() over set({merge:true}), and swallowing NOT_FOUND while rethrowing
  // everything else so `retry: true` still means something — are silent when
  // wrong, so they are asserted directly rather than through the trigger.
  countJobsFor,
  recountOne,
  NOT_FOUND,
};
