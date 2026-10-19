"use strict";

const {randomUUID} = require("node:crypto");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {APP_CHECK, assertAdminCall, enforceDurableRateLimit,
  requireDocId} = require("./security");
const {appointmentHistoryScopes} = require("./search_tokens");
const {toMillis} = require("./time_utils");
const {readEditableRecord, appointmentEditPatch,
  validateEditedAppointment, fieldValue, FIELDS} =
  require("./appointment_edit_policy");

/**
 * Commits a form or series operation under one server transaction.
 * @param {!Object} db Firestore.
 * @param {!Object} payload Callable payload.
 * @param {Function=} onValidated Guarded rate-limit step, before database work.
 * @return {!Promise<!Object>} Acknowledged current records.
 */
async function commitAppointmentEdits(
    db, payload, onValidated = async () => {}) {
  const edits = payload.edits ?? [];
  const creates = payload.creates ?? [];
  const deletes = payload.deletes ?? [];
  if (![edits, creates, deletes].every(Array.isArray) ||
      edits.length + creates.length + deletes.length > 400 ||
      edits.length + creates.length + deletes.length === 0) {
    throw new HttpsError("invalid-argument", "invalid-appointment-operation");
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
      validateEditedAppointment(next, current);
      return {...command, current, patch, next};
    });
    const clientIds = [...new Set(planned.filter((c) => c.next?.clientId &&
      c.next.clientId !== c.current?.clientId).map((c) => c.next.clientId))];
    const clients = await Promise.all(clientIds.map((id) =>
      tx.get(db.collection("clients").doc(id))));
    if (clients.some((doc) => !doc.exists || doc.data().deletionToken)) {
      throw new HttpsError("failed-precondition", "client-unavailable");
    }
    const records = [];
    for (const command of planned) {
      if (command.kind === "delete") {
        if (command.current) tx.delete(command.ref);
        continue;
      }
      const {next, patch, current} = command;
      if (Object.keys(patch).length > 0) {
        const metadata = {seriesOpId: opId, editProtocol: 1,
          editRevision: (Number.isSafeInteger(current?.editRevision) ?
            current.editRevision : 0) + 1,
          historySearchScopes: appointmentHistoryScopes(next),
          updatedAt: FieldValue.serverTimestamp()};
        if (current) {
          tx.update(command.ref, {...patch, ...metadata});
        } else {
          tx.create(command.ref, {...next, ...metadata, pictureCount: 0,
            createdAt: FieldValue.serverTimestamp()});
        }
      }
      const data = {...next};
      for (const key of ["startTime", "endTime", "startedAt", "completedAt",
        "createdAt", "updatedAt"]) {
        if (data[key] != null) {
          data[key] = {millisecondsSinceEpoch: toMillis(data[key])};
        }
      }
      records.push({id: command.id, data});
    }
    return {appointments: records};
  });
}

/** Transactional dirty-field appointment edits, including series operations. */
const saveAppointmentEdits = onCall({...APP_CHECK, timeoutSeconds: 120},
    async (req) => {
      const uid = await assertAdminCall(req,
          new Set(["edits", "creates", "deletes"]), 4 * 1024 * 1024);
      return commitAppointmentEdits(getFirestore(), req.data,
          () => enforceDurableRateLimit(
              "saveAppointmentEdits", uid, 120, 60_000));
    });

module.exports = {saveAppointmentEdits, commitAppointmentEdits};
