"use strict";

jest.mock("firebase-admin/firestore", () => ({
  ...jest.requireActual("firebase-admin/firestore"),
  getFirestore: jest.fn(),
}));
jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  const mock = {
    requireDocId: actual.requireDocId,
    assertPayloadShape: jest.fn(),
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

const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const security = require("../security");
const {saveAppointmentEdits} = require("../appointment_edits");

const UID = "admin-uid";
const form = (extra = {}) => ({title: "Visit", notes: "", status: "pending",
  startTime: Date.UTC(2026, 9, 19, 9), endTime: Date.UTC(2026, 9, 19, 10),
  ...extra});

/**
 * A db with no stored rows that records transaction use.
 * @return {!Object} Fake Firestore.
 */
function emptyDb() {
  return {
    collection: () => ({doc: (id) => ({path: `appointments/${id}`})}),
    runTransaction: jest.fn(async (body) => body({
      get: async () => ({exists: false, data: () => null}),
      create: jest.fn(), update: jest.fn(), delete: jest.fn(),
    })),
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
    expect([...allowed].sort()).toEqual(["creates", "deletes", "edits"]);
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
