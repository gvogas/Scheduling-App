/**
 * @fileoverview The server half of moving appointment photos into the
 * `appointments/{id}/images` subcollection.
 *
 * Two triggers, and the first one is not optional:
 *
 * 1. `cascadeDeleteAppointmentImages` — **Firestore does NOT delete a
 *    subcollection when its parent document is deleted.** The photo documents
 *    survive as orphans: invisible in the console under a parent that no
 *    longer exists, unreachable by every query the app makes, and impossible
 *    to find later without knowing the id. This trigger is the only thing
 *    standing between an ordinary appointment delete and permanent silent
 *    litter, and it must cover all three delete paths — the client's single
 *    delete, its series delete, and `purgeExpiredHistory` (Admin SDK deletes
 *    fire triggers too).
 *
 * 2. `recountAppointmentPictures` — maintains the denormalized `pictureCount`
 *    the card's photo indicator reads, since the card renders on every
 *    range-query surface and cannot afford a subcollection read each. It is
 *    DEBOUNCED per parent through the shared claim ledger in
 *    `recount_claim.js`, which owns the release/aggregate ORDER for both
 *    counters; see `debouncedRecountPictures` for what is photo-specific
 *    about this one.
 *
 * The orchestration lives here rather than in the trigger wiring so it is
 * testable: every body takes an injected `db`, in the same shape as
 * `maintenance_policy.js`.
 */
const {onDocumentDeleted, onDocumentWritten} =
  require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const {getFirestore} = require("firebase-admin/firestore");
const {debounceRecount} = require("./recount_claim");
const {getStorage} = require("firebase-admin/storage");

/**
 * Hand-mirror of `_imagesSubcollection` in
 * `lib/features/calendar/data/firebase_appointments_repository.dart`.
 * `firestore.rules` matches this path literally too — all three must agree.
 */
const IMAGES_SUBCOLLECTION = "images";

/**
 * Admin-SDK-only claim ledger that collapses one photo batch's N recounts
 * into one parent write. Same posture as `appointmentSeriesNotices`: nothing
 * client-side may read or write it.
 */
const RECOUNT_CLAIM_COLLECTION = "appointmentRecountClaims";

/**
 * How long the claiming invocation waits before recounting, to absorb the
 * rest of its batch's triggers. Correctness never depends on this number —
 * see `debounceRecount` in `recount_claim.js` — so it is tuned purely for how
 * much of a batch one recount swallows. A sibling arriving after the window
 * simply recounts again, which is the old behaviour.
 */
const RECOUNT_SETTLE_MS = 2000;

/**
 * The photo count past which one appointment's photos stop being fully
 * readable, and the log line is the only sign of it.
 *
 * It is what STANDS IN for the `pictures` array's 100-entry rules cap on the
 * new shape. **That clause is still in `firestore.rules` and still enforced**
 * — deliberately, for the documents `clear-appointment-picture-arrays.js` has
 * not reached, whose arrays ride along in `request.resource.data` on every
 * ordinary edit. What it guarded was a hard failure: the parent document's
 * 1 MB ceiling, which made an over-full job permanently un-updatable. Moving
 * photos into a subcollection is precisely what makes that unreachable for a
 * job written by a current build, so no equivalent CEILING was needed on the
 * new store.
 *
 * What survives is softer and quieter: `AppointmentImagesStore.fetch` reads at
 * most `scanLimit` (the same 100) photos, so anything past that is invisible
 * in the app with only a client-side warn to say so. Rules cannot count
 * documents in a subcollection, and the picker already caps a job at
 * `maxImagesPerAppointment` (10), so a job that gets here has a modified
 * client behind it. Recording it server-side is what makes that visible at
 * all — keep this number equal to the Dart read cap.
 */
const PICTURE_COUNT_WARN_CAP = 100;

/**
 * The Storage prefix holding one appointment's photo bytes.
 *
 * **The TRAILING SLASH is load-bearing and is why this is its own function.**
 * `deleteFiles({prefix})` matches by string prefix, so without it, deleting
 * appointment `12` would also sweep `appointments/123/...` — a silent
 * cross-appointment data loss, not merely an orphan. Pinned by
 * `__tests__/appointment_images.test.js`.
 * @param {string} appointmentId
 * @return {string} Prefix ending in `/`.
 */
function appointmentImagePrefix(appointmentId) {
  return `appointments/${appointmentId}/${IMAGES_SUBCOLLECTION}/`;
}

/**
 * Deletes every Storage object under one appointment's image prefix.
 *
 * The bucket is resolved INSIDE the call, never at module load — that is what
 * keeps this file requirable (and therefore testable) outside the emulator,
 * the distinction `maintenance.js` had to split a policy module out to get.
 * @param {string} appointmentId
 * @return {!Promise<void>} rejects when the prefix could not be cleared.
 */
async function deleteAppointmentImageBytes(appointmentId) {
  await getStorage()
      .bucket()
      .deleteFiles({prefix: appointmentImagePrefix(appointmentId)});
}

/**
 * Deletes a deleted appointment's photos — the Storage bytes AND the photo
 * documents.
 *
 * **The bytes half is not housekeeping either.** Until the CONTRACT step the
 * client deleted them, enumerating `appointment.pictures` to know which
 * objects to remove; that array is gone, and nothing client-side can
 * enumerate a subcollection it is no longer reading. So this is now the only
 * thing standing between an appointment delete and photos orphaned in
 * Storage — paid for monthly, attached to nothing, with no query that can
 * find them. The prefix is derived from the appointment id rather than from
 * any stored path, so it also sweeps up bytes whose document link never
 * landed.
 *
 * `recursiveDelete` for the documents rather than a hand-rolled paged loop: it
 * is the Admin SDK's own bulk writer, it handles the paging, and
 * `syncUsersByUid` already uses it for `liveActivityTokens` — one way of doing
 * this in the codebase.
 *
 * ORDER: bytes first, documents second — the same rule `purgeExpiredHistory`
 * follows. The photo documents are the last thing pointing at those objects,
 * so dropping them before the bytes are gone loses the trail on a failure.
 *
 * Errors are RETHROWN, unlike most best-effort cleanup here. The trigger runs
 * with `retry: true` and the failure mode it guards against is permanent and
 * invisible; a swallowed error would leave the orphans it exists to prevent
 * with nothing to notice them. Both halves are idempotent, so a retry that
 * repeats the successful half is free.
 * @param {string} appointmentId
 * @param {{db: !Object, deleteImages: !Function}} deps Both injected: the
 *   production caller passes `deleteAppointmentImageBytes` and jest passes a
 *   fake. No default here, so a caller cannot half-wire it.
 * @return {!Promise<void>}
 */
async function purgeAppointmentImages(appointmentId, deps) {
  const {db, deleteImages} = deps;
  await deleteImages(appointmentId);
  const ref = db
      .collection("appointments")
      .doc(appointmentId)
      .collection(IMAGES_SUBCOLLECTION);
  await db.recursiveDelete(ref);
}

/**
 * Recomputes `pictureCount` on the parent from a `count()` aggregate.
 *
 * ABSOLUTE, never an increment — the same rule and the same reason as
 * `recountClientJobs`: this runs with `retry: true`, and a retried
 * `FieldValue.increment` double-counts. The aggregate costs a fraction of a
 * read and photo writes are rare.
 *
 * `update()`, not `set({merge: true})`, so an appointment deleted in the
 * window between the photo write and this recount is never resurrected as a
 * count-only stub. A `not-found` is therefore an expected outcome, not an
 * error: the cascade above has already removed the photos.
 * @param {string} appointmentId
 * @param {!Object} deps `{db, logger}`.
 * @return {!Promise<number>} the count written, or -1 when the parent was gone.
 */
async function recountPictures(appointmentId, deps) {
  const {db, logger: log} = deps;
  const parent = db.collection("appointments").doc(appointmentId);
  let count;
  try {
    count = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(parent);
      if (!snapshot.exists) return -1;
      const aggregate = await tx.get(
          parent.collection(IMAGES_SUBCOLLECTION).count());
      const currentCount = aggregate.data().count;
      tx.update(parent, {pictureCount: currentCount});
      return currentCount;
    });
  } catch (err) {
    if (err && err.code === 5) return -1;
    throw err;
  }
  if (count > PICTURE_COUNT_WARN_CAP && log) {
    log.warn("appointment holds more photos than the app can read", {
      appointmentId,
      count,
      cap: PICTURE_COUNT_WARN_CAP,
    });
  }
  return count;
}

/**
 * Debounces the recount per parent through the shared claim ledger: the first
 * trigger of a photo batch claims the parent, settles, and performs ONE
 * recount; the rest return having done nothing.
 *
 * WHY: `appendAppointmentPictures` writes N image docs in ONE batch, so N
 * triggers land on the SAME parent within milliseconds — against Firestore's
 * ~1 write/sec/document guidance — and, worse, every parent write re-fires
 * `notifyAppointmentChanges`. Ten photos on one job cost 10 recounts and 11
 * notification invocations for a single user action, multiplied again by
 * `retry: true` contention retries.
 *
 * The claim protocol itself — and the release-BEFORE-aggregate ordering that
 * is the whole safety argument — belongs to `recount_claim.js`, which the
 * client `jobCount` counter shares. Don't re-spell it here: that is precisely
 * the second copy the module was extracted to prevent.
 *
 * **IT STILL RECOUNTS ON EVERY WRITE, INCLUDING AN UPDATE THAT CANNOT HAVE
 * MOVED THE COUNT.** `event.data` is deliberately never consulted. An
 * `if (before.exists && after.exists) return` guard was written and then
 * removed on purpose: the only paths it skips are the offline queue replaying
 * `set(..., {merge: true})` on the DERIVED doc id, and a backfill re-run — and
 * those two are the ONLY self-heal this counter has. A recount whose parent
 * `update()` keeps failing exhausts its retry window and leaves `pictureCount`
 * wrong forever, where an idempotent replay repairs it silently. The debounce
 * preserves that: a claim lives seconds and is deleted on the normal path, so
 * a later, separate write always claims afresh and always recounts. Suppress a
 * sibling of the batch in flight, never a replay.
 *
 * Unconditional, unlike `recountClientJobs`: a photo write is ALWAYS part of a
 * batch worth collapsing (`appendAppointmentPictures` commits N image docs at
 * once), so there is no cheap single-write path to gate the settle on.
 * @param {string} appointmentId
 * @param {!Object} deps `{db, logger, now, sleep, settleMs}`.
 * @return {!Promise<{skipped: boolean, count: ?number}>}
 */
async function debouncedRecountPictures(appointmentId, deps) {
  const {skipped, result} = await debounceRecount(
      RECOUNT_CLAIM_COLLECTION,
      appointmentId,
      () => recountPictures(appointmentId, deps),
      {settleMs: RECOUNT_SETTLE_MS, ...deps},
  );
  return {skipped, count: result};
}

// `retry: true` is safe and wanted: recursiveDelete is idempotent (a second
// pass finds nothing), and the orphans this prevents are permanent.
const cascadeDeleteAppointmentImages = onDocumentDeleted(
    {document: "appointments/{appointmentId}", retry: true},
    async (event) => {
      const appointmentId = event.params.appointmentId;
      await purgeAppointmentImages(appointmentId, {
        db: getFirestore(),
        deleteImages: deleteAppointmentImageBytes,
      });
      logger.info("appointment images purged", {appointmentId});
    },
);

// `retry: true` is safe because the write is an absolute count, not a delta —
// and because the claim is released before the aggregate, so a retry re-claims
// instead of suppressing itself. See `debouncedRecountPictures` for the
// ordering rule and for why no before/after guard belongs here.
const recountAppointmentPictures = onDocumentWritten(
    {
      document:
        `appointments/{appointmentId}/${IMAGES_SUBCOLLECTION}/{imageId}`,
      retry: true,
    },
    async (event) => {
      await debouncedRecountPictures(
          event.params.appointmentId, {db: getFirestore(), logger});
    },
);

module.exports = {
  cascadeDeleteAppointmentImages,
  // Exported for `maintenance.js`, so the image prefix has ONE owner.
  deleteAppointmentImageBytes,
  appointmentImagePrefix,
  recountAppointmentPictures,
  purgeAppointmentImages,
  recountPictures,
  debouncedRecountPictures,
  IMAGES_SUBCOLLECTION,
  PICTURE_COUNT_WARN_CAP,
  RECOUNT_CLAIM_COLLECTION,
  RECOUNT_SETTLE_MS,
};
