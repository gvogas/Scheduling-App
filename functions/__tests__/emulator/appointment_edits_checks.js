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
 * Pins the `sessionEpoch` and `kind` bounds on a device token row.
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
  const kinded = (kind) => write(
      `users/${admin.docId}/fcmTokens/${prefix}-fid`, {
        platform: {stringValue: "ios"}, locale: {stringValue: "en"},
        uid: {stringValue: admin.uid}, kind: {stringValue: kind},
      });
  assert.equal(await kinded("fid"), 200, "a fid row is allowed");
  assert.equal(await kinded("token"), 200, "an explicit token row is allowed");
  assert.equal(await kinded("apns"), 403, "an unknown kind must be refused");
}

/**
 * Pins the assignee `allow update` disjuncts and the `fieldNotes` create.
 * @param {!Object} db Demo emulator Firestore.
 * @param {string} prefix Unique test prefix.
 * @param {string} project Demo project.
 * @param {string} firestore REST origin.
 * @param {!Object} assignee Active employee account (`token`, `docId`).
 * @param {!Object} outsider Active employee not on the job.
 * @return {!Promise<void>}
 */
async function verifyAssigneeRules(db, prefix, project, firestore, assignee,
    outsider) {
  const root = `projects/${project}/databases/(default)/documents`;
  const seed = (id, status) => db.collection("appointments").doc(id).set({
    title: "Visit", status, employeeIds: [assignee.docId],
    startTime: Timestamp.fromMillis(Date.UTC(2026, 9, 19, 9)),
    endTime: Timestamp.fromMillis(Date.UTC(2026, 9, 19, 10))});
  const commit = async (user, path, fields, create = false) => {
    const response = await fetch(`${firestore}/v1/${root}:commit`, {
      method: "POST",
      headers: {"Authorization": `Bearer ${user.token}`,
        "Content-Type": "application/json"},
      body: JSON.stringify({writes: [{
        update: {name: `${root}/${path}`, fields},
        updateMask: create ? undefined : {fieldPaths: Object.keys(fields)},
        updateTransforms: [{fieldPath: create ? "createdAt" : "updatedAt",
          setToServerValue: "REQUEST_TIME"}],
        currentDocument: {exists: !create},
      }]}),
    });
    await response.arrayBuffer();
    return response.status;
  };
  const move = async (user, from, to, extra = {}) => {
    const id = `${prefix}-assignee-${from}-${to}-${Object.keys(extra).length}`;
    await seed(id, from);
    return commit(user, `appointments/${id}`,
        {status: {stringValue: to}, ...extra});
  };

  assert.equal(await move(assignee, "pending", "done"), 200,
      "assignee pending -> done is allowed");
  assert.equal(await move(assignee, "pending", "in_progress"), 200,
      "assignee pending -> in_progress is allowed");
  assert.equal(await move(assignee, "cancelled", "done"), 403,
      "assignee cannot complete a cancelled job");
  assert.equal(await move(outsider, "pending", "done"), 403,
      "a non-assignee cannot complete the job");

  const touch = `${prefix}-assignee-touch`;
  await seed(touch, "pending");
  assert.equal(await commit(assignee, `appointments/${touch}`, {}), 200,
      "assignee parent touch is allowed");
  assert.equal(await commit(assignee, `appointments/${touch}`,
      {notes: {stringValue: "extra"}}), 403,
  "a parent touch carrying another key is refused");

  const note = (user, authorId, name) => commit(user,
      `appointments/${touch}/fieldNotes/${prefix}-${name}`, {
        text: {stringValue: "On site"},
        authorId: {stringValue: authorId},
        authorName: {stringValue: "Tech"},
      }, true);
  assert.equal(await note(assignee, assignee.docId, "own"), 200,
      "a field note under the caller's own id is allowed");
  assert.equal(await note(assignee, outsider.docId, "foreign"), 403,
      "a field note with a foreign authorId is refused");
}

module.exports = {verifyAppointmentEdits, verifyAssigneeRules};
