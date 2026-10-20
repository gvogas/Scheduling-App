"use strict";

const {randomUUID} = require("node:crypto");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {assertAdminCall, enforceDurableRateLimit,
  requireDocId} = require("./security");
const {appointmentHistoryScopes} = require("./search_tokens");
const {isCompletedStatus, serializeValue, toMillis} =
  require("./time_utils");
const {readEditableRecord, appointmentEditPatch,
  validateEditedAppointment, fieldValue, FIELDS} =
  require("./appointment_edit_policy");
const {readConflictWindow} = require("./indexed_search");

/**
 * The first planned record whose crew is already booked, or null.
 * Deletes, personal blocks and this operation's own documents never clash.
 * @param {!Object} db Firestore.
 * @param {!Object} tx Open transaction, so the check and the write are one.
 * @param {!Array<!Object>} planned Planned commands with merged `next`.
 * @param {string} uid Caller, for the scan-cap warn.
 * @return {!Promise<?Object>} `{busyEmployeeIds, startMillis, endMillis}`.
 */
async function firstBusyWindow(db, tx, planned, uid) {
  const excluded = new Set(planned.map((c) => c.id));
  const bookings = planned.filter((c) => c.kind !== "delete" &&
    c.next.isPersonal !== true && (c.next.employeeIds ?? []).length > 0);
  const windows = bookings.map((c) => ({
    employeeIds: [...new Set(c.next.employeeIds)],
    startMillis: toMillis(c.next.startTime),
    endMillis: toMillis(c.next.endTime),
  }));
  const results = await Promise.all(windows.map((window) =>
    readConflictWindow(db, {...window, excludeId: null, clientJobsOnly: false,
      excluded, uid, minimal: true, fetch: (query) => tx.get(query),
      label: "saveAppointmentEdits"})));
  const index = results.findIndex((r) => r.busyEmployeeIds.length > 0);
  if (index < 0) return null;
  const {startMillis, endMillis} = windows[index];
  return {busyEmployeeIds: results[index].busyEmployeeIds,
    startMillis, endMillis};
}

/**
 * Commits a form or series operation under one server transaction.
 * @param {!Object} db Firestore.
 * @param {!Object} payload Callable payload.
 * @param {Function=} onValidated Guarded rate-limit step, before database work.
 * @param {string=} uid Caller, for log hashes only.
 * @return {!Promise<!Object>} Acknowledged current records.
 */
async function commitAppointmentEdits(
    db, payload, onValidated = async () => {}, uid = "") {
  const edits = payload.edits ?? [];
  const creates = payload.creates ?? [];
  const deletes = payload.deletes ?? [];
  if (![edits, creates, deletes].every(Array.isArray) ||
      edits.length + creates.length + deletes.length > 400 ||
      edits.length + creates.length + deletes.length === 0) {
    throw new HttpsError("invalid-argument", "invalid-appointment-operation");
  }
  const checkConflicts = payload.checkConflicts ?? false;
  if (typeof checkConflicts !== "boolean") {
    throw new HttpsError("invalid-argument", "invalid-checkConflicts");
  }
  const commands = [
    ...edits.map((entry) => ({...entry, kind: "edit"})),
    ...creates.map((entry) => ({...entry, kind: "create"})),
    ...deletes.map((entry) => ({...entry, kind: "delete"})),
  ].map((entry) => {
    const id = requireDocId(entry, "id");
    if ([".", ".."].includes(id)) {
      throw new HttpsError("invalid-argument", "invalid-id");
    }
    return {id, kind: entry.kind,
      ref: db.collection("appointments").doc(id),
      base: entry.kind === "create" ? null : readEditableRecord(entry.base),
      desired: entry.kind === "delete" ? null :
        readEditableRecord(entry.data)};
  });
  if (new Set(commands.map((c) => c.id)).size !== commands.length) {
    throw new HttpsError("invalid-argument", "duplicate-appointment-id");
  }
  await onValidated();
  const opId = randomUUID();
  return db.runTransaction(async (tx) => {
    const snapshots = await Promise.all(commands.map((c) => tx.get(c.ref)));
    const planned = commands.map((command, index) => {
      const snapshot = snapshots[index];
      const current = snapshot.exists ? snapshot.data() : null;
      if (command.kind === "delete") {
        if (current && FIELDS.some((field) =>
          fieldValue(field, current[field]) !==
          fieldValue(field, command.base[field]))) {
          throw new HttpsError("aborted", "appointment-edit-conflict");
        }
        return {...command, current};
      }
      if (command.kind === "create" && current) {
        if (FIELDS.some((field) => fieldValue(field, current[field]) !==
            fieldValue(field, command.desired[field]))) {
          throw new HttpsError("already-exists", "appointment-id-conflict");
        }
        return {...command, current, next: current, patch: {}};
      }
      if (command.kind === "edit" && !current) {
        throw new HttpsError("not-found", "appointment-not-found");
      }
      const patch = current ?
        appointmentEditPatch(command.base, command.desired, current) :
        command.desired;
      const next = {...current, ...patch};
      const reopened = Boolean(current) && "status" in patch &&
        isCompletedStatus(current.status) && !isCompletedStatus(patch.status);
      if (reopened) delete next.completedAt;
      validateEditedAppointment(next, current);
      return {...command, current, patch, next, reopened};
    });
    const clientIds = [...new Set(planned.filter((c) => c.next?.clientId &&
      c.next.clientId !== c.current?.clientId).map((c) => c.next.clientId))];
    const clients = await Promise.all(clientIds.map((id) =>
      tx.get(db.collection("clients").doc(id))));
    if (clients.some((doc) => !doc.exists || doc.data().deletionToken)) {
      throw new HttpsError("failed-precondition", "client-unavailable");
    }
    if (checkConflicts) {
      const busy = await firstBusyWindow(db, tx, planned, uid);
      if (busy) {
        throw new HttpsError("failed-precondition",
            "appointment-employee-busy", busy);
      }
    }
    const records = [];
    for (const command of planned) {
      if (command.kind === "delete") {
        if (command.current) tx.delete(command.ref);
        continue;
      }
      const {next, patch, current, reopened} = command;
      if (Object.keys(patch).length > 0) {
        const metadata = {seriesOpId: opId, editProtocol: 1,
          editRevision: (Number.isSafeInteger(current?.editRevision) ?
            current.editRevision : 0) + 1,
          historySearchScopes: appointmentHistoryScopes(next),
          updatedAt: FieldValue.serverTimestamp()};
        if (current) {
          tx.update(command.ref, {...patch, ...metadata,
            ...(reopened ? {completedAt: FieldValue.delete()} : {})});
        } else {
          tx.create(command.ref, {...next, ...metadata, pictureCount: 0,
            createdAt: FieldValue.serverTimestamp()});
        }
      }
      records.push({id: command.id, data: serializeValue(next)});
    }
    return {appointments: records};
  });
}

/** Transactional dirty-field appointment edits, including series operations. */
const saveAppointmentEdits = onCall(
    {enforceAppCheck: true, timeoutSeconds: 120, minInstances: 1,
      memory: "512MiB"}, async (req) => {
      const uid = await assertAdminCall(req,
          new Set(["edits", "creates", "deletes", "checkConflicts"]),
          4 * 1024 * 1024);
      return commitAppointmentEdits(getFirestore(), req.data,
          () => enforceDurableRateLimit(
              "saveAppointmentEdits", uid, 120, 60_000), uid);
    });

module.exports = {saveAppointmentEdits, commitAppointmentEdits};
