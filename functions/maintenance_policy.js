"use strict";

/**
 * @fileoverview Pure maintenance POLICY — the retention/deletion decisions
 * behind `maintenance.js`, extracted so they can be tested without the
 * firebase-admin handles wrapped around them.
 *
 * `maintenance.js` resolves a Storage bucket and a Firestore handle at call
 * time, so it cannot be `require()`d outside the emulator. Everything here
 * takes its I/O as injected deps instead, which is the same split
 * `notification_policy` / `notification_utils` already use.
 *
 * This module is the one place the purge's three load-bearing rules live:
 * the status gate, the images-before-doc ordering, and the loop's
 * termination. All three delete data irreversibly if they regress.
 *
 * @module maintenance_policy
 */

const {TERMINAL_STATUSES} = require("./time_utils");
const {hasValidImageMagic} = require("./image_magic");

/** Appointments older than this (by `startTime`) are eligible for purge. */
const HISTORY_RETENTION_YEARS = 2;

/**
 * ONLY terminal appointments are ever purged. A `pending`/`in_progress` job
 * is live work no matter how old its startTime is — widening this set deletes
 * jobs that were never finished.
 *
 * Derived from `time_utils`' TERMINAL_STATUSES rather than restated, so it
 * cannot drift from the other three copies again: this one had dropped the
 * legacy `completed` alias, so such a doc was never eligible for purge at any
 * age and quietly outlived the retention policy. The array form is what
 * Firestore's `where("status", "in", ...)` needs.
 */
const PURGE_STATUSES = [...TERMINAL_STATUSES];

/** Well under Firestore's 500-writes-per-batch ceiling, with headroom. */
const PURGE_BATCH_SIZE = 200;

/** Only these object paths are appointment images. */
const APPOINTMENT_IMAGE_PREFIX = /^appointments\/[^/]+\/images\//;

/**
 * The instant before which terminal history is purgeable.
 * @param {!Date} now
 * @return {!Date}
 */
function historyCutoff(now) {
  const cutoff = new Date(now.getTime());
  cutoff.setFullYear(cutoff.getFullYear() - HISTORY_RETENTION_YEARS);
  return cutoff;
}

/**
 * True when a finalized Storage object is an appointment image and therefore
 * subject to magic-byte validation. Anything else is left alone.
 * @param {string} filePath
 * @return {boolean}
 */
function isAppointmentImagePath(filePath) {
  return APPOINTMENT_IMAGE_PREFIX.test(String(filePath || ""));
}

/**
 * Decides what happens to a finalized Storage object, with the read and the
 * delete injected.
 *
 * **A read failure DELETES the file, deliberately.** The Storage rule trusts
 * the client-provided `contentType`, so this check is the only thing standing
 * between an upload and a file whose bytes were never inspected — and bytes we
 * could not read are bytes we cannot clear. Failing closed costs a user a
 * re-upload; failing open keeps an unvalidated file forever. Keep the
 * asymmetry, and keep it tested: it is the branch that destroys a photo, and
 * it was the one branch with no coverage at all.
 *
 * Both delete paths swallow their own failure — the object simply survives to
 * be re-validated on its next finalize, which beats throwing out of a Storage
 * trigger that has nothing to retry.
 *
 * @param {{
 *   filePath: string,
 *   readHeader: function(): !Promise<!Buffer>,
 *   deleteFile: function(): !Promise<void>,
 *   logger: !Object,
 * }} deps
 * @return {!Promise<string>} One of `skipped`, `kept`, `deleted-unreadable`,
 *     `deleted-invalid`.
 */
async function runImageValidation(deps) {
  const {filePath, readHeader, deleteFile, logger} = deps;
  if (!isAppointmentImagePath(filePath)) return "skipped";

  let buffer;
  try {
    buffer = await readHeader();
  } catch (err) {
    logger.warn("validateUploadedImage: read failed — deleting", {
      filePath,
      err: err.message,
    });
    await deleteFile().catch((delErr) =>
      logger.error("validateUploadedImage: delete after read-fail failed", {
        filePath,
        err: delErr.message,
      }),
    );
    return "deleted-unreadable";
  }

  if (hasValidImageMagic(buffer)) return "kept";

  logger.warn("validateUploadedImage: invalid magic bytes — deleting", {
    filePath,
  });
  await deleteFile().catch((err) =>
    logger.error("validateUploadedImage: delete failed", {
      filePath,
      err: err.message,
    }),
  );
  return "deleted-invalid";
}

/**
 * Purges terminal appointments older than the cutoff: Storage images first,
 * then the docs whose images actually cleared.
 *
 * @param {{
 *   db: !Object,
 *   deleteImages: function(string): !Promise<boolean>,
 *   now: !Date,
 * }} deps `deleteImages` resolves false when a prefix could NOT be cleared.
 * @return {!Promise<{purged: number, imageFailures: number, cutoff: !Date}>}
 */
async function runHistoryPurge(deps) {
  const {db, deleteImages, now} = deps;
  const cutoff = historyCutoff(now);
  const col = db.collection("appointments");

  let purged = 0;
  // A kept doc is refetched on every later page, so count it by id.
  const failedIds = new Set();
  // A plain limit loop advances without a cursor, since cleared docs are
  // deleted. The loop stops when a page makes no progress — meaning all image
  // cleanups failed, so retrying would just repeat them.
  for (;;) {
    const snap = await col
        .where("status", "in", PURGE_STATUSES)
        .where("startTime", "<", cutoff)
        .orderBy("startTime")
        .limit(PURGE_BATCH_SIZE)
        .get();
    if (snap.empty) break;

    // Images FIRST, then only the docs whose prefix actually cleared. The
    // reverse order orphans the bytes forever: nothing would point at them.
    const results = await Promise.all(
        snap.docs.map((doc) => deleteImages(doc.id)),
    );

    const batch = db.batch();
    let deletable = 0;
    snap.docs.forEach((doc, i) => {
      if (results[i]) {
        batch.delete(doc.ref);
        deletable += 1;
      } else {
        failedIds.add(doc.id);
      }
    });
    if (deletable > 0) await batch.commit();
    purged += deletable;

    // No page progress, so bail rather than refetching the same stuck docs
    // forever — the next quarterly run retries them.
    if (deletable === 0) break;
    if (snap.size < PURGE_BATCH_SIZE) break;
  }

  return {purged, imageFailures: failedIds.size, cutoff};
}

module.exports = {
  // Exported for unit tests: the purge is the only unattended, irreversible
  // deletion in the repo, so its bounds are asserted against these rather than
  // against copied literals.
  HISTORY_RETENTION_YEARS,
  PURGE_STATUSES,
  PURGE_BATCH_SIZE,
  historyCutoff,
  isAppointmentImagePath,
  runImageValidation,
  runHistoryPurge,
};
