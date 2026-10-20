"use strict";

const {Timestamp, FieldValue} = require("firebase-admin/firestore");
const {commitAppointmentEdits} = require("../appointment_edits");
const {readEditableRecord, appointmentEditPatch,
  validateEditedAppointment} = require("../appointment_edit_policy");

const form = (extra = {}) => ({title: "Visit", clientId: "", notes: "old",
  status: "pending", startTime: Date.UTC(2026, 9, 19, 9),
  endTime: Date.UTC(2026, 9, 19, 10), ...extra});
const stored = (extra = {}) => readEditableRecord(form(extra));

/**
 * Transaction boundary double with retry and mutation hooks.
 * @param {!Object} rows Records keyed by collection/id.
 * @param {?Function=} beforeRead Optional mutation before transaction reads.
 * @return {!Object} Firestore boundary and recorded committed writes.
 */
function database(rows, beforeRead = null) {
  const writes = [];
  const db = {
    collection: (collection) => ({
      doc: (id) => ({path: `${collection}/${id}`}),
    }),
    runTransaction: async (body) => {
      if (beforeRead) beforeRead(rows);
      const pending = [];
      const result = await body({
        get: async (ref) => ({exists: Boolean(rows[ref.path]),
          data: () => rows[ref.path]}),
        update: (ref, data) => pending.push({kind: "update", ref, data}),
        create: (ref, data) => pending.push({kind: "create", ref, data}),
        delete: (ref) => pending.push({kind: "delete", ref}),
      });
      for (const write of pending) {
        if (write.kind === "delete") delete rows[write.ref.path];
        else rows[write.ref.path] = {...rows[write.ref.path], ...write.data};
        writes.push(write);
      }
      return result;
    },
    writes,
  };
  return db;
}

describe("dirty appointment edits", () => {
  test("notes preserve a crew completion and newer contact data", () => {
    const base = stored();
    const desired = stored({notes: "new notes"});
    const current = {...base, status: "done", clientPhone: "new phone",
      fieldNotes: "crew update"};
    expect(appointmentEditPatch(base, desired, current))
        .toEqual({notes: "new notes"});
  });

  test("conflicting changes to the same field are rejected", () => {
    expect(() => appointmentEditPatch(stored(), stored({notes: "mine"}),
        stored({notes: "theirs"}))).toThrow("appointment-edit-conflict");
  });

  test("an identical acknowledged edit is idempotent", () => {
    const desired = stored({notes: "mine"});
    expect(appointmentEditPatch(stored(), desired, desired)).toEqual({});
  });

  test("an explicit status edit conflicts with a newer terminal status", () => {
    expect(() => appointmentEditPatch(stored(),
        stored({status: "in_progress"}), stored({status: "done"})))
        .toThrow("appointment-edit-conflict");
  });

  test("a deliberate reopen compares the terminal state being reopened", () => {
    expect(appointmentEditPatch(stored({status: "done"}), stored(),
        stored({status: "done"}))).toEqual({status: "pending"});
  });

  test.each(["pictureCount", "editRevision", "startedAt", "unknown"])(
      "client cannot submit server field %s", (field) => {
        expect(() => readEditableRecord(form({[field]: 1})))
            .toThrow("invalid-appointment-fields");
      });

  test("invalid spans are refused while an unwidened legacy span is editable",
      () => {
        const legacy = stored({endTime: Date.UTC(2026, 10, 19, 9)});
        expect(() => validateEditedAppointment(legacy, null))
            .toThrow("invalid-appointment-span");
        expect(() => validateEditedAppointment(legacy, legacy)).not.toThrow();
      });

  test("a legacy doc with no stored status stays editable", () => {
    const legacy = stored({});
    delete legacy.status;
    expect(() => validateEditedAppointment(legacy, legacy)).not.toThrow();
  });

  test.each([0, 15, 1.5, "2"])("a day label of %j is refused", (value) => {
    expect(() => readEditableRecord(form({dayIndex: value})))
        .toThrow("invalid-appointment-day");
    expect(() => readEditableRecord(form({dayCount: value})))
        .toThrow("invalid-appointment-day");
  });

  test("run labels inside 1..14 with dayIndex <= dayCount are accepted",
      () => {
        for (const [dayIndex, dayCount] of [[1, 1], [3, 5], [14, 14]]) {
          expect(() => validateEditedAppointment(
              stored({dayIndex, dayCount}), null)).not.toThrow();
        }
      });

  test("a dayIndex past its dayCount is refused", () => {
    expect(() => validateEditedAppointment(
        stored({dayIndex: 4, dayCount: 3}), null))
        .toThrow("invalid-appointment-day");
    expect(() => validateEditedAppointment(stored({dayIndex: 4,
      dayCount: 3}), stored({dayIndex: 3, dayCount: 3})))
        .toThrow("invalid-appointment-day");
  });

  test("an unchanged legacy run label stays editable", () => {
    const legacy = {...stored(), dayIndex: 4, dayCount: 3};
    expect(() => validateEditedAppointment(legacy, legacy)).not.toThrow();
  });
});

describe("server appointment transaction", () => {
  test("returns the merged completion and writes only dirty fields",
      async () => {
        const db = database({"appointments/job": stored({status: "done"})});
        const result = await commitAppointmentEdits(db, {edits: [{
          id: "job", base: form(), data: form({notes: "mine"}),
        }]});
        expect(result.appointments[0].data.status).toBe("done");
        expect(db.writes[0].data).toMatchObject({
          notes: "mine", editRevision: 1, editProtocol: 1,
        });
        expect(db.writes[0].data).not.toHaveProperty("status");
      });

  test("one sibling conflict aborts the entire series operation", async () => {
    const db = database({"appointments/a": stored(),
      "appointments/b": stored({notes: "theirs"})});
    await expect(commitAppointmentEdits(db, {edits: ["a", "b"].map((id) =>
      ({id, base: form(), data: form({notes: "mine"})}))}))
        .rejects.toMatchObject({code: "aborted"});
    expect(db.writes).toEqual([]);
  });

  test("a sibling completed after planning cannot be deleted", async () => {
    const db = database({"appointments/a": stored()}, (rows) => {
      rows["appointments/a"].status = "done";
    });
    await expect(commitAppointmentEdits(db, {deletes: [{
      id: "a", base: form(),
    }]})).rejects.toMatchObject({code: "aborted"});
    expect(db.writes).toEqual([]);
  });

  test("a missing edit target is not recreated", async () => {
    const db = database({});
    await expect(commitAppointmentEdits(db, {edits: [{
      id: "a", base: form(), data: form({notes: "mine"}),
    }]})).rejects.toMatchObject({code: "not-found"});
    expect(db.writes).toEqual([]);
  });

  test("a retry does not duplicate already created occurrences", async () => {
    const db = database({"appointments/a": stored()});
    await commitAppointmentEdits(db, {creates: [{id: "a", data: form()}]});
    expect(db.writes).toEqual([]);
  });

  test("a new link to a deleted client is refused before writing", async () => {
    const db = database({"appointments/a": stored()});
    await expect(commitAppointmentEdits(db, {edits: [{id: "a",
      base: form(), data: form({clientId: "gone"})}]}))
        .rejects.toMatchObject({code: "failed-precondition"});
    expect(db.writes).toEqual([]);
  });

  test("Firestore timestamps are serialized for the client acknowledgement",
      async () => {
        const db = database({"appointments/a": {...stored(),
          completedAt: Timestamp.fromMillis(1234)}});
        const result = await commitAppointmentEdits(db, {edits: [{id: "a",
          base: form(), data: form({notes: "mine"})}]});
        expect(result.appointments[0].data.completedAt)
            .toEqual({millisecondsSinceEpoch: 1234});
      });

  test.each(["done", "completed"])(
      "reopening a %s job deletes its server-owned completedAt",
      async (status) => {
        const db = database({"appointments/a": {...stored(), status,
          completedAt: Timestamp.fromMillis(1234)}});
        const result = await commitAppointmentEdits(db, {edits: [{id: "a",
          base: form({status}), data: form()}]});
        expect(db.writes[0].data.status).toBe("pending");
        expect(db.writes[0].data.completedAt).toBe(FieldValue.delete());
        expect(result.appointments[0].data).not.toHaveProperty("completedAt");
      });

  test("an edit that keeps a job complete keeps its completedAt", async () => {
    const db = database({"appointments/a": {...stored({status: "done"}),
      completedAt: Timestamp.fromMillis(1234)}});
    await commitAppointmentEdits(db, {edits: [{id: "a",
      base: form({status: "done"}), data: form({status: "done",
        notes: "mine"})}]});
    expect(db.writes[0].data).not.toHaveProperty("completedAt");
  });
});
