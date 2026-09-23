"use strict";

/** Guard-chain tests for the `deleteClient` CALLABLE. */

jest.mock("firebase-admin/firestore");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));
jest.mock("../security", () => {
  const mock = {
    APP_CHECK: {enforceAppCheck: true},
    assertAdmin: jest.fn(),
    assertPayloadShape: jest.fn(),
    requireDocId: jest.fn(),
    enforceDurableRateLimit: jest.fn(),
    shortHash: jest.fn((value) => `hash:${value}`),
  };
  // `deleteClient` opens with `assertAdminCall`, which composes the three steps
  // below.
  mock.assertAdminCall = jest.fn(async (req, allowedKeys) => {
    if (!req.auth || !req.auth.uid) {
      throw new (require("firebase-functions/v2/https").HttpsError)(
          "unauthenticated", "auth-required");
    }
    await mock.assertAdmin(req.auth.uid);
    mock.assertPayloadShape(req.data, allowedKeys);
    return req.auth.uid;
  });
  return mock;
});

const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const security = require("../security");
const {deleteClient} = require("../clients");

const ADMIN_UID = "admin-uid";

/**
 * Invokes the callable and returns the HttpsError it threw.
 * @param {!Object} request
 * @return {!Promise<!Object>}
 */
async function expectRejection(request) {
  let caught = null;
  try {
    await deleteClient.run(request);
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(HttpsError);
  return caught;
}

/**
 * Relative invocation order of two jest mocks' first calls.
 * @param {!Function} first
 * @param {!Function} second
 * @return {void}
 */
function expectCalledBefore(first, second) {
  expect(first).toHaveBeenCalled();
  expect(second).toHaveBeenCalled();
  expect(first.mock.invocationCallOrder[0])
      .toBeLessThan(second.mock.invocationCallOrder[0]);
}

/**
 * A db whose client has no appointments, so the delete succeeds.
 * @return {!Object}
 */
function cleanDb() {
  let data = {};
  return {
    runTransaction: async (work) => work({
      get: async () => ({exists: true, data: () => data}),
      update: (_ref, patch) => {
        data = {...data, ...patch};
      },
      delete: () => {},
    }),
    collection: () => ({
      doc: () => ({
        get: async () => ({exists: true, id: "c1"}),
        delete: async () => {},
      }),
      where: () => ({
        count: () => ({get: async () => ({data: () => ({count: 0})})}),
      }),
    }),
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  security.assertAdmin.mockImplementation(async (uid) => {
    if (uid !== ADMIN_UID) {
      throw new HttpsError("permission-denied", "wave/not-admin");
    }
  });
  security.assertPayloadShape.mockImplementation((data, allowed) => {
    if (data === undefined || data === null) return;
    for (const key of Object.keys(data)) {
      if (!allowed.has(key)) {
        throw new HttpsError("invalid-argument", "unexpected-field");
      }
    }
  });
  security.requireDocId.mockImplementation((data, field) => data[field]);
  security.enforceDurableRateLimit.mockResolvedValue({refund: jest.fn()});
  getFirestore.mockReturnValue(cleanDb());
});

describe("deleteClient callable", () => {
  test("an unauthenticated caller is refused first", async () => {
    const err = await expectRejection({auth: null, data: {clientId: "c1"}});
    expect(err.code).toBe("unauthenticated");
    expect(security.assertAdmin).not.toHaveBeenCalled();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("a caller with auth but no uid is refused", async () => {
    const err = await expectRejection({auth: {}, data: {clientId: "c1"}});
    expect(err.code).toBe("unauthenticated");
    expect(security.assertAdmin).not.toHaveBeenCalled();
  });

  test("a non-admin is refused and burns NO rate-limit slot", async () => {
    const err = await expectRejection({
      auth: {uid: "employee-uid"},
      data: {clientId: "c1"},
    });
    expect(err.code).toBe("permission-denied");
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("an unexpected field is refused", async () => {
    const err = await expectRejection({
      auth: {uid: ADMIN_UID},
      data: {clientId: "c1", isAdmin: true},
    });
    expect(err.code).toBe("invalid-argument");
    expect(err.message).toContain("unexpected-field");
  });

  test("a malformed payload does NOT consume a limiter slot", async () => {
    // The whole reason validation precedes the limiter: otherwise a burst of
    // junk submissions exhausts a real admin's window.
    await expectRejection({
      auth: {uid: ADMIN_UID},
      data: {clientId: "c1", bogus: 1},
    });
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("guards run in the documented order", async () => {
    await deleteClient.run({auth: {uid: ADMIN_UID}, data: {clientId: "c1"}});
    expectCalledBefore(security.assertAdmin, security.assertPayloadShape);
    expectCalledBefore(
        security.assertPayloadShape, security.enforceDurableRateLimit);
  });

  test("the allowlist is exactly clientId", async () => {
    await deleteClient.run({auth: {uid: ADMIN_UID}, data: {clientId: "c1"}});
    const [, allowed] = security.assertPayloadShape.mock.calls[0];
    expect([...allowed].sort()).toEqual(["clientId"]);
  });

  test("an admin with a clean client completes it", async () => {
    await expect(
        deleteClient.run({auth: {uid: ADMIN_UID}, data: {clientId: "c1"}}),
    ).resolves.toBeUndefined();
    expect(security.enforceDurableRateLimit).toHaveBeenCalled();
  });
});
