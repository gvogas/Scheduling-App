"use strict";

const assert = require("node:assert/strict");
const {Timestamp} = require("firebase-admin/firestore");
const {commitAppointmentEdits} = require("../../appointment_edits");

/**
 * Verifies real transaction contention and legacy-client rules behavior.
 * @param {!Object} db Demo emulator Firestore.
 * @param {string} prefix Unique test prefix.
 * @param {!Function} write Authenticated REST writer from the parent harness.
 * @return {!Promise<void>}
 */
async function verifyAppointmentEdits(db, prefix, write) {
  const id = `${prefix}-guarded-edit`;
  const ref = db.collection("appointments").doc(id);
  const base = {title: "Visit", notes: "old", status: "pending",
    startTime: Date.UTC(2026, 9, 19, 9),
    endTime: Date.UTC(2026, 9, 19, 10)};
  const reset = () => ref.set({...base, editProtocol: 1, editRevision: 0,
    startTime: Timestamp.fromMillis(base.startTime),
    endTime: Timestamp.fromMillis(base.endTime)});
  const save = (data) => commitAppointmentEdits(db, {
    edits: [{id, base, data: {...base, ...data}}],
  });

  await reset();
  const sameField = await Promise.allSettled([
    save({notes: "left"}), save({notes: "right"}),
  ]);
  assert.equal(sameField.filter((r) => r.status === "fulfilled").length, 1);
  const conflict = sameField.find((r) => r.status === "rejected");
  assert.equal(conflict.reason.code, "aborted");

  await reset();
  await Promise.all([save({notes: "mine"}), save({address: "new address"})]);
  assert.equal((await ref.get()).data().notes, "mine");
  assert.equal((await ref.get()).data().address, "new address");

  await reset();
  await ref.update({status: "done"});
  const result = await save({notes: "mine"});
  assert.equal(result.appointments[0].data.status, "done");
  assert.equal((await ref.get()).data().status, "done");
  assert.equal(await write(`appointments/${id}`, {
    notes: {stringValue: "legacy overwrite"},
  }, "?updateMask.fieldPaths=notes"), 403);
  assert.equal(await write(`appointments/${id}`, {
    status: {stringValue: "pending"},
  }, "?updateMask.fieldPaths=status"), 403);
  console.log("Appointment edits: contention and legacy rules checked.");
}

module.exports = {verifyAppointmentEdits};
