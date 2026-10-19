"use strict";

const assert = require("node:assert/strict");
const {Timestamp} = require("firebase-admin/firestore");
const {commitAppointmentEdits} = require("../../appointment_edits");

/**
 * Verifies real transaction contention and legacy-client rules behavior.
 * @param {!Object} db Demo emulator Firestore.
 * @param {string} prefix Unique test prefix.
 * @param {!Function} write Authenticated REST writer from the parent harness.
 * @param {!Object} admin The writer's account (`uid`, `docId`).
 * @return {!Promise<void>}
 */
async function verifyAppointmentEdits(db, prefix, write, admin) {
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
  await verifyDirectStatusRules(db, prefix, write);
  await verifySessionEpochRules(prefix, write, admin);
  console.log("Appointment edits: contention and legacy rules checked.");
}

/**
 * Isolates the closed-status and protocol-1 rules on admin direct writes.
 * @param {!Object} db Demo emulator Firestore.
 * @param {string} prefix Unique test prefix.
 * @param {!Function} write Authenticated REST writer from the parent harness.
 * @return {!Promise<void>}
 */
async function verifyDirectStatusRules(db, prefix, write) {
  const seed = (id, data) => db.collection("appointments").doc(id).set({
    title: "Visit", status: "pending",
    startTime: Timestamp.fromMillis(Date.UTC(2026, 9, 19, 9)),
    endTime: Timestamp.fromMillis(Date.UTC(2026, 9, 19, 10)), ...data});
  const status = async (id, from, to, extra = {}) => {
    await seed(id, from);
    const fields = {status: {stringValue: to},
      updatedAt: {timestampValue: new Date().toISOString()}};
    for (const [key, value] of Object.entries(extra)) {
      fields[key] = {stringValue: value};
    }
    return write(`appointments/${id}`, fields, "?" + Object.keys(fields)
        .map((key) => `updateMask.fieldPaths=${key}`).join("&"));
  };

  const legacy = `${prefix}-legacy-status`;
  for (const [from, to] of [["cancelled", "pending"], ["cancelled", "done"],
    ["done", "pending"]]) {
    assert.equal(await status(legacy, {status: from}, to), 403,
        `legacy ${from} -> ${to} must be refused`);
  }
  assert.equal(await status(legacy, {status: "completed"}, "done"), 200,
      "legacy completed -> done is allowed");
  assert.equal(await status(legacy, {status: "done"}, "done", {
    notes: "closing note"}), 200, "a legacy closed job stays editable");

  const guarded = `${prefix}-protocol-status`;
  for (const [from, to] of [["pending", "in_progress"], ["pending", "done"],
    ["in_progress", "done"], ["in_progress", "cancelled"]]) {
    assert.equal(await status(guarded, {status: from, editProtocol: 1}, to,
        {seriesOpId: `${prefix}-op`}), 200,
    `protocol-1 ${from} -> ${to} is allowed`);
  }
  assert.equal(await status(guarded, {status: "in_progress",
    editProtocol: 1}, "pending"), 403, "protocol-1 cannot move backward");
}

/**
 * Pins the `sessionEpoch` bound on a device token row.
 * @param {string} prefix Unique test prefix.
 * @param {!Function} write Authenticated REST writer from the parent harness.
 * @param {!Object} admin The writer's account (`uid`, `docId`).
 * @return {!Promise<void>}
 */
async function verifySessionEpochRules(prefix, write, admin) {
  const token = (sessionEpoch) => write(
      `users/${admin.docId}/fcmTokens/${prefix}-token`, {
        platform: {stringValue: "ios"}, locale: {stringValue: "en"},
        uid: {stringValue: admin.uid}, sessionEpoch,
      });
  assert.equal(await token({integerValue: "1"}), 403,
      "a non-string sessionEpoch must be refused");
  assert.equal(await token({stringValue: "e".repeat(65)}), 403,
      "a sessionEpoch over 64 characters must be refused");
  assert.equal(await token({stringValue: "e".repeat(64)}), 200,
      "a 64-character sessionEpoch is allowed");
}

module.exports = {verifyAppointmentEdits};
