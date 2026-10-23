"use strict";

/**
 * @fileoverview Appointment action callables whose authorization is richer
 * than Firestore rules can safely express from the client.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const logger = require("firebase-functions/logger");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

const {
  APP_CHECK,
  assertActiveCall,
  enforceDurableRateLimit,
  optionalString,
  shortHash,
} = require("./security");
const {
  isCompletedStatus,
  isTerminalStatus,
  toMillis,
} = require("./time_utils");

const DOC_ID_MAX = 128;
const RESTORABLE_STATUSES = new Set(["pending", "in_progress"]);
const RESTORE_RATE_MAX = 30;
const RESTORE_RATE_WINDOW_MS = 60 * 60 * 1000;
// How long after completion a non-admin may still Undo it.
const RESTORE_WINDOW_MS = 10 * 60 * 1000;

/**
 * True when caller may operate on this appointment.
 * @param {!Object} caller usersByUid profile.
 * @param {!Object} appointment Appointment fields.
 * @return {boolean}
 */
function mayRestore(caller, appointment) {
  if (caller.role === "admin") return true;
  const callerDocId = String(caller.docId || "");
  const ids = Array.isArray(appointment.employeeIds) ?
    appointment.employeeIds.map((id) => String(id)) : [];
  return caller.role === "employee" &&
      callerDocId !== "" &&
      ids.includes(callerDocId);
}

/**
 * True while a non-admin may still undo this completion. Anchors on the
 * server-owned `completedAt`, else (before the stamp lands) on `updatedAt`,
 * which the mark-done rule pins to the write time.
 * @param {!Object} caller usersByUid profile.
 * @param {!Object} appointment Appointment fields.
 * @param {number} nowMs Current epoch ms.
 * @return {boolean}
 */
function withinRestoreWindow(caller, appointment, nowMs) {
  if (caller.role === "admin") return true;
  const anchor = toMillis(appointment.completedAt) ??
    toMillis(appointment.updatedAt);
  return anchor != null && nowMs - anchor <= RESTORE_WINDOW_MS;
}

/**
 * Undo for the mobile "mark complete" action.
 */
const restoreAppointmentStatus = onCall(APP_CHECK, async (req) => {
  const caller = await assertActiveCall(
      req, new Set(["appointmentId", "previousStatus"]));
  const db = getFirestore();
  const appointmentId = optionalString(req.data, "appointmentId", DOC_ID_MAX);
  const previousStatus = optionalString(
      req.data, "previousStatus", DOC_ID_MAX);
  if (!appointmentId || appointmentId.includes("/")) {
    throw new HttpsError("invalid-argument", "invalid-appointmentId");
  }
  if (!RESTORABLE_STATUSES.has(previousStatus)) {
    throw new HttpsError("invalid-argument", "invalid-previousStatus");
  }
  await enforceDurableRateLimit(
      "restoreAppointmentStatus", caller.uid,
      RESTORE_RATE_MAX, RESTORE_RATE_WINDOW_MS);

  const ref = db.collection("appointments").doc(appointmentId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "appointment-not-found");
    }
    const data = snap.data() || {};
    if (!mayRestore(caller, data)) {
      throw new HttpsError("permission-denied", "scope-denied");
    }
    if (!isCompletedStatus(data.status)) {
      throw new HttpsError("failed-precondition", "not-completed");
    }
    if (!withinRestoreWindow(caller, data, Date.now())) {
      throw new HttpsError("failed-precondition", "undo-window-expired");
    }
    if (isTerminalStatus(previousStatus)) {
      throw new HttpsError("invalid-argument", "invalid-previousStatus");
    }

    tx.update(ref, {
      status: previousStatus,
      completedAt: FieldValue.delete(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  logger.info("restoreAppointmentStatus: restored", {
    uidHash: shortHash(caller.uid),
    appointmentId,
    previousStatus,
  });
});

module.exports = {
  mayRestore,
  withinRestoreWindow,
  restoreAppointmentStatus,
};
