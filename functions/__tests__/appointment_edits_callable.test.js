"use strict";

jest.mock("firebase-admin/firestore", () => ({
  ...jest.requireActual("firebase-admin/firestore"),
  getFirestore: jest.fn(),
}));
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));
jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  const mock = {
    APP_CHECK: {enforceAppCheck: true},
    requireDocId: actual.requireDocId,
    optionalString: actual.optionalString,
    requireNumberInRange: actual.requireNumberInRange,
    shortHash: actual.shortHash,
    assertPayloadShape: jest.fn(),
    assertActiveCall: jest.fn(),
    enforceDurableRateLimit: jest.fn(async () => {}),
  };
  // The callable opens with the COMPOSER, so that is what the suite stubs.
  mock.assertAdminCall = jest.fn(async (req, allowedKeys, maxBytes) => {
    if (!req.auth || !req.auth.uid) {
      throw new (require("firebase-functions/v2/https").HttpsError)(
          "unauthenticated", "auth-required");
    }
    mock.assertPayloadShape(req.data, allowedKeys, maxBytes);
    return req.auth.uid;
  });
  return mock;
});

const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const security = require("../security");
const {saveAppointmentEdits} = require("../appointment_edits");
const {readEditableRecord} = require("../appointment_edit_policy");

const UID = "admin-uid";
const START = Date.UTC(2026, 9, 19, 9);
const END = Date.UTC(2026, 9, 19, 10);
const form = (extra = {}) => ({title: "Visit", notes: "", status: "pending",
  startTime: START, endTime: END, ...extra});

/**
 * A db that records transaction use. `booked` lists the appointment documents
 * every crew-window query returns; `rows` the documents a ref read finds.
 * @param {!Array<!Object>=} booked `{id, ...fields}` rows the scan reads.
 * @param {!Object=} rows Stored records keyed by path.
 * @return {!Object} Fake Firestore.
 */
function emptyDb(booked = [], rows = {}) {
  const scans = [];
  const query = (chain) => ({
    where: (f, op, v) => query({...chain, where: [...chain.where, [f, op, v]]}),
    select: (...fields) => query({...chain, select: fields}),
    limit: (n) => query({...chain, limit: n}),
    startAfter: () => query(chain),
    chain,
  });
  const tx = {
    get: async (target) => {
      if (!target.chain) {
        return {exists: Boolean(rows[target.path]),
          data: () => rows[target.path]};
      }
      scans.push(target.chain);
      return {docs: booked.map(({id, ...data}) => ({id, data: () => data}))};
    },
    create: jest.fn(), update: jest.fn(), delete: jest.fn(),
  };
  return {
    scans,
    tx,
    collection: (name) => ({
      doc: (id) => ({path: `${name}/${id}`}),
      ...query({name, where: [], limit: null}),
    }),
    runTransaction: jest.fn(async (body) => body(tx)),
  };
}

/**
 * Invokes the callable and returns the HttpsError it threw.
 * @param {!Object} data Payload.
 * @param {?Object=} auth Caller auth.
 * @return {!Promise<!Object>} The caught error.
 */
async function rejection(data, auth = {uid: UID}) {
  let caught = null;
  try {
    await saveAppointmentEdits.run({auth, data});
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(HttpsError);
  return caught;
}

let db;
beforeEach(() => {
  jest.clearAllMocks();
  db = emptyDb();
  getFirestore.mockReturnValue(db);
});

describe("saveAppointmentEdits options", () => {
  test("a warm instance with room to load every module", () => {
    expect(saveAppointmentEdits.__endpoint).toMatchObject({
      minInstances: 1, availableMemoryMb: 512, timeoutSeconds: 120,
    });
  });

  test("App Check is written inline beside the other options", () => {
    const source = readFileSync(join(__dirname, "..", "appointment_edits.js"),
        "utf8");
    expect(source).toMatch(new RegExp(
        "enforceAppCheck: true, timeoutSeconds: 120, minInstances: 1,\\s*" +
        "memory: \"512MiB\""));
  });
});

describe("saveAppointmentEdits guard chain", () => {
  test("an unauthenticated caller is refused before any work", async () => {
    expect((await rejection({creates: [{id: "a", data: form()}]}, null)).code)
        .toBe("unauthenticated");
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    expect(db.runTransaction).not.toHaveBeenCalled();
  });

  test("the allowlist and byte budget reach the composer", async () => {
    await saveAppointmentEdits.run({auth: {uid: UID},
      data: {creates: [{id: "a", data: form()}]}});
    const [, allowed, maxBytes] = security.assertAdminCall.mock.calls[0];
    expect([...allowed].sort())
        .toEqual(["checkConflicts", "creates", "deletes", "edits"]);
    expect(maxBytes).toBe(4 * 1024 * 1024);
  });

  test.each([
    ["no commands", {}],
    ["empty lists", {edits: [], creates: [], deletes: []}],
    ["401 commands", {creates: Array.from({length: 401},
        (_, i) => ({id: `a${i}`, data: form()}))}],
  ])("%s are refused before the limiter", async (_, data) => {
    expect((await rejection(data)).message)
        .toBe("invalid-appointment-operation");
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    expect(db.runTransaction).not.toHaveBeenCalled();
  });

  test("400 commands are accepted", async () => {
    const result = await saveAppointmentEdits.run({auth: {uid: UID},
      data: {creates: Array.from({length: 400},
          (_, i) => ({id: `a${i}`, data: form()}))}});
    expect(result.appointments).toHaveLength(400);
  });

  test.each([".", ".."])("the id %j is refused before the limiter",
      async (id) => {
        expect((await rejection({creates: [{id, data: form()}]})).message)
            .toBe("invalid-id");
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  test.each([
    ["a duplicate id", {creates: [{id: "a", data: form()}],
      deletes: [{id: "a", base: form()}]}, "duplicate-appointment-id"],
    ["an unknown field", {creates: [{id: "a", data: form({pictureCount: 0})}]},
      "invalid-appointment-fields"],
    ["a day label of 0", {creates: [{id: "a", data: form({dayIndex: 0})}]},
      "invalid-appointment-day"],
    ["a non-boolean checkConflicts", {checkConflicts: "yes",
      creates: [{id: "a", data: form()}]}, "invalid-checkConflicts"],
  ])("%s is refused before the limiter", async (_, data, message) => {
    expect((await rejection(data)).message).toBe(message);
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("the limiter runs after validation and before the transaction",
      async () => {
        await saveAppointmentEdits.run({auth: {uid: UID},
          data: {creates: [{id: "a", data: form()}]}});
        expect(security.enforceDurableRateLimit).toHaveBeenCalledWith(
            "saveAppointmentEdits", UID, 120, 60_000);
        const limited =
          security.enforceDurableRateLimit.mock.invocationCallOrder[0];
        expect(security.assertPayloadShape.mock.invocationCallOrder[0])
            .toBeLessThan(limited);
        expect(db.runTransaction.mock.invocationCallOrder[0])
            .toBeGreaterThan(limited);
      });

  test("a spent rate limit stops the transaction", async () => {
    security.enforceDurableRateLimit.mockRejectedValueOnce(
        new HttpsError("resource-exhausted", "rate-limited"));
    expect((await rejection({creates: [{id: "a", data: form()}]})).code)
        .toBe("resource-exhausted");
    expect(db.runTransaction).not.toHaveBeenCalled();
  });
});

describe("saveAppointmentEdits folded conflict check", () => {
  const crew = (extra = {}) => form({employeeIds: ["e1", "e2"],
    employeeNames: ["Ann", "Bo"], ...extra});
  const booked = {id: "other", status: "pending", employeeIds: ["e2"],
    startTime: new Date(START), endTime: new Date(END)};
  const run = (data) => saveAppointmentEdits.run({auth: {uid: UID}, data});

  test("a booked assignee refuses the save with the window, writing nothing",
      async () => {
        db = emptyDb([booked]);
        getFirestore.mockReturnValue(db);
        const e = await rejection({checkConflicts: true,
          creates: [{id: "a", data: crew()}]});
        expect(e.code).toBe("failed-precondition");
        expect(e.message).toBe("appointment-employee-busy");
        expect(e.details).toEqual(
            {busyEmployeeIds: ["e2"], startMillis: START, endMillis: END});
        expect(security.enforceDurableRateLimit).toHaveBeenCalledTimes(1);
        expect(db.tx.create).not.toHaveBeenCalled();
      });

  test("the scan excludes this operation's own documents and reads inside " +
      "the transaction", async () => {
    db = emptyDb([{...booked, id: "a"}],
        {"appointments/a": readEditableRecord(crew())});
    getFirestore.mockReturnValue(db);
    const result = await run({checkConflicts: true,
      edits: [{id: "a", base: crew(), data: crew({notes: "mine"})}]});
    expect(result.appointments).toHaveLength(1);
    expect(db.scans).toHaveLength(1);
    expect(db.scans[0].where[0]).toEqual(
        ["employeeIds", "array-contains-any", ["e1", "e2"]]);
  });

  test("a free crew saves, one scan per booking", async () => {
    const result = await run({checkConflicts: true, creates: [
      {id: "a", data: crew()},
      {id: "b", data: crew({startTime: START + 86_400_000,
        endTime: END + 86_400_000})},
    ]});
    expect(result.appointments).toHaveLength(2);
    expect(db.scans).toHaveLength(2);
  });

  test("a personal block, a delete and an unassigned job are never scanned",
      async () => {
        db = emptyDb([booked]);
        getFirestore.mockReturnValue(db);
        await run({checkConflicts: true,
          creates: [{id: "p", data: crew({isPersonal: true})},
            {id: "u", data: form()}],
          deletes: [{id: "d", base: crew()}]});
        expect(db.scans).toHaveLength(0);
      });

  test("without the key a clash is not looked for — the old behaviour",
      async () => {
        db = emptyDb([booked]);
        getFirestore.mockReturnValue(db);
        const result = await run({creates: [{id: "a", data: crew()}]});
        expect(result.appointments).toHaveLength(1);
        expect(db.scans).toHaveLength(0);
      });
});
