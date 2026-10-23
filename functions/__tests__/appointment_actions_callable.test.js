"use strict";

/**
 * Guard-chain tests for the `restoreAppointmentStatus` CALLABLE — the Undo
 * behind the mobile "mark complete".
 *
 * The module had 0% function coverage: only its pure `mayRestore` helper was
 * reachable, and nothing drove the handler, so the order of its guards and
 * every throw inside the transaction were unexercised. That matters here
 * because the callable REVERSES a terminal status, and the two things stopping
 * a technician from reopening somebody else's closed job — `assertActiveCall`
 * and `mayRestore` — are both inside it.
 *
 * `optionalString` is the REAL one: it is pure, and stubbing it would hide
 * exactly the trim/control-char rejection the id guard leans on.
 */

jest.mock("firebase-admin/firestore");
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
    optionalString: actual.optionalString,
    // Real, not a stub: the point of the log assertion is that the raw uid
    // never reaches the log line, and a `hash:${uid}` stub would contain it.
    shortHash: actual.shortHash,
    assertPayloadShape: jest.fn(),
    enforceDurableRateLimit: jest.fn(),
  };
  // The callable opens with the COMPOSER, so that is what the suite stubs —
  // intercepting a step it composes internally would assert nothing.
  mock.assertActiveCall = jest.fn(async (req, allowedKeys) => {
    if (!req.auth || !req.auth.uid) {
      throw new (require("firebase-functions/v2/https").HttpsError)(
          "unauthenticated", "auth-required");
    }
    mock.assertPayloadShape(req.data, allowedKeys);
    return {...mock.profile, uid: req.auth.uid};
  });
  mock.profile = {role: "admin", docId: "e-admin"};
  return mock;
});

const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const security = require("../security");
const {
  mayRestore,
  withinRestoreWindow,
  restoreAppointmentStatus,
} = require("../appointment_actions");

const UID = "caller-uid";

/**
 * A db whose single appointment is `data`, capturing the update.
 * @param {?Object} data Stored appointment fields, or null for missing.
 * @return {!Object} The fake db, with `updates` recording tx.update calls.
 */
function dbWith(data) {
  const updates = [];
  const ref = {id: "a1"};
  const db = {
    updates,
    collection: jest.fn(() => ({doc: jest.fn(() => ref)})),
    runTransaction: jest.fn(async (fn) => fn({
      get: jest.fn(async () => ({
        exists: data !== null,
        data: () => data,
      })),
      update: jest.fn((r, patch) => updates.push({ref: r, patch})),
    })),
  };
  return db;
}

/**
 * Invokes the callable and returns the HttpsError it threw.
 * @param {!Object} request Callable request.
 * @return {!Promise<!Object>} The caught error.
 */
async function expectRejection(request) {
  let caught = null;
  try {
    await restoreAppointmentStatus.run(request);
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(HttpsError);
  return caught;
}

/**
 * A well-formed request.
 * @param {!Object=} data Payload overrides.
 * @return {!Object} Callable request.
 */
function req(data = {}) {
  return {
    auth: {uid: UID},
    data: {appointmentId: "a1", previousStatus: "pending", ...data},
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  security.profile = {role: "admin", docId: "e-admin"};
  FieldValue.serverTimestamp = jest.fn(() => "TS");
  FieldValue.delete = jest.fn(() => "DELETE");
});

describe("mayRestore", () => {
  test("an admin may restore any appointment", () => {
    expect(mayRestore({role: "admin", docId: "x"}, {})).toBe(true);
    expect(mayRestore({role: "admin"}, {employeeIds: ["e9"]})).toBe(true);
  });

  test("an assigned technician may restore their own", () => {
    expect(mayRestore(
        {role: "employee", docId: "e1"}, {employeeIds: ["e1", "e2"]}))
        .toBe(true);
  });

  test("an unassigned technician may not", () => {
    expect(mayRestore(
        {role: "employee", docId: "e3"}, {employeeIds: ["e1", "e2"]}))
        .toBe(false);
  });

  test("employeeIds is compared as strings, not by identity", () => {
    expect(mayRestore(
        {role: "employee", docId: "7"}, {employeeIds: [7]})).toBe(true);
  });

  test("a technician with no docId is refused, never matched by empty", () => {
    expect(mayRestore(
        {role: "employee", docId: ""}, {employeeIds: [""]})).toBe(false);
  });

  test("a missing or unknown role is refused", () => {
    expect(mayRestore({docId: "e1"}, {employeeIds: ["e1"]})).toBe(false);
    expect(mayRestore(
        {role: "dispatcher", docId: "e1"}, {employeeIds: ["e1"]})).toBe(false);
  });

  test("a non-array employeeIds cannot admit anyone", () => {
    expect(mayRestore({role: "employee", docId: "e1"}, {})).toBe(false);
    expect(mayRestore(
        {role: "employee", docId: "e1"}, {employeeIds: "e1"})).toBe(false);
  });
});

describe("withinRestoreWindow", () => {
  const tech = {role: "employee", docId: "e1"};
  const NOW = Date.parse("2026-10-23T12:00:00Z");
  const ago = (min) => new Date(NOW - min * 60000);

  test("a technician may undo within ten minutes of completedAt", () => {
    expect(withinRestoreWindow(tech, {completedAt: ago(10)}, NOW)).toBe(true);
    expect(withinRestoreWindow(tech, {completedAt: ago(11)}, NOW)).toBe(false);
  });

  test("before the stamp lands, the mark-done updatedAt anchors it", () => {
    expect(withinRestoreWindow(tech, {updatedAt: ago(0)}, NOW)).toBe(true);
  });

  test("a later updatedAt cannot reopen an old completion", () => {
    // The photo touch lets an assignee bump updatedAt; completedAt wins.
    expect(withinRestoreWindow(tech,
        {completedAt: ago(60), updatedAt: ago(0)}, NOW)).toBe(false);
  });

  test("no anchor at all is refused for a technician, not an admin", () => {
    expect(withinRestoreWindow(tech, {}, NOW)).toBe(false);
    expect(withinRestoreWindow({role: "admin"}, {}, NOW)).toBe(true);
  });
});

describe("restoreAppointmentStatus guard chain", () => {
  test("an unauthenticated caller is refused before any read", async () => {
    getFirestore.mockReturnValue(dbWith({status: "done"}));
    const e = await expectRejection({auth: null, data: {}});
    expect(e.code).toBe("unauthenticated");
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("the payload allowlist is exactly the two fields", async () => {
    getFirestore.mockReturnValue(dbWith({status: "done"}));
    await restoreAppointmentStatus.run(req());
    const [, allowed] = security.assertActiveCall.mock.calls[0];
    expect([...allowed].sort()).toEqual(["appointmentId", "previousStatus"]);
  });

  test("a blank or path-bearing appointmentId is refused", async () => {
    getFirestore.mockReturnValue(dbWith({status: "done"}));
    expect((await expectRejection(req({appointmentId: ""}))).message)
        .toMatch(/invalid-appointmentId/);
    expect((await expectRejection(req({appointmentId: "  "}))).message)
        .toMatch(/invalid-appointmentId/);
    expect((await expectRejection(req({appointmentId: "a/b"}))).message)
        .toMatch(/invalid-appointmentId/);
  });

  test("previousStatus must be one a job can be restored TO", async () => {
    getFirestore.mockReturnValue(dbWith({status: "done"}));
    for (const bad of ["done", "cancelled", "", "Pending", "nonsense"]) {
      const e = await expectRejection(req({previousStatus: bad}));
      expect(e.message).toMatch(/invalid-previousStatus/);
    }
  });

  test("both restorable statuses are accepted", async () => {
    for (const good of ["pending", "in_progress"]) {
      const db = dbWith({status: "done"});
      getFirestore.mockReturnValue(db);
      await restoreAppointmentStatus.run(req({previousStatus: good}));
      expect(db.updates[0].patch.status).toBe(good);
    }
  });

  test("the payload is validated BEFORE a rate-limit slot is spent",
      async () => {
        getFirestore.mockReturnValue(dbWith({status: "done"}));
        await expectRejection(req({previousStatus: "nonsense"}));
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  test("the limiter is keyed on the AUTHENTICATED uid", async () => {
    getFirestore.mockReturnValue(dbWith({status: "done"}));
    await restoreAppointmentStatus.run(req());
    expect(security.enforceDurableRateLimit)
        .toHaveBeenCalledWith("restoreAppointmentStatus", UID, 30, 3600000);
  });

  test("a missing appointment is not-found", async () => {
    getFirestore.mockReturnValue(dbWith(null));
    const e = await expectRejection(req());
    expect(e.code).toBe("not-found");
  });

  test("an unassigned technician is refused inside the transaction",
      async () => {
        security.profile = {role: "employee", docId: "e3"};
        const db = dbWith({status: "done", employeeIds: ["e1"]});
        getFirestore.mockReturnValue(db);
        const e = await expectRejection(req());
        expect(e.code).toBe("permission-denied");
        expect(db.updates).toHaveLength(0);
      });

  test("an assigned technician may restore", async () => {
    security.profile = {role: "employee", docId: "e1"};
    const db = dbWith(
        {status: "done", employeeIds: ["e1"], completedAt: new Date()});
    getFirestore.mockReturnValue(db);
    await restoreAppointmentStatus.run(req());
    expect(db.updates).toHaveLength(1);
  });

  test("a technician cannot reopen a job completed long ago", async () => {
    // Reopening, then re-closing, would rewrite the server-owned finish time.
    security.profile = {role: "employee", docId: "e1"};
    const db = dbWith({status: "done", employeeIds: ["e1"],
      completedAt: new Date(Date.now() - 3 * 24 * 3600 * 1000)});
    getFirestore.mockReturnValue(db);
    const e = await expectRejection(req());
    expect(e.code).toBe("failed-precondition");
    expect(e.message).toBe("undo-window-expired");
    expect(db.updates).toHaveLength(0);
  });

  test("an admin may restore a completion of any age", async () => {
    const db = dbWith({status: "done",
      completedAt: new Date(Date.now() - 3 * 24 * 3600 * 1000)});
    getFirestore.mockReturnValue(db);
    await restoreAppointmentStatus.run(req());
    expect(db.updates).toHaveLength(1);
  });

  test("only a COMPLETED job can be restored — cancelled cannot", async () => {
    for (const status of ["pending", "in_progress", "cancelled"]) {
      const db = dbWith({status});
      getFirestore.mockReturnValue(db);
      const e = await expectRejection(req());
      expect(e.code).toBe("failed-precondition");
      expect(db.updates).toHaveLength(0);
    }
  });

  test("the restore clears completedAt and re-stamps updatedAt", async () => {
    const db = dbWith({status: "done"});
    getFirestore.mockReturnValue(db);
    await restoreAppointmentStatus.run(req());
    expect(db.updates[0].patch).toEqual({
      status: "pending",
      completedAt: "DELETE",
      updatedAt: "TS",
    });
  });

  test("the success log hashes the uid rather than printing it", async () => {
    getFirestore.mockReturnValue(dbWith({status: "done"}));
    await restoreAppointmentStatus.run(req());
    const logger = require("firebase-functions/logger");
    const [, payload] = logger.info.mock.calls[0];
    expect(payload.uidHash).toBe(security.shortHash(UID));
    expect(payload.uidHash).toBeTruthy();
    expect(JSON.stringify(payload)).not.toContain(UID);
  });
});
