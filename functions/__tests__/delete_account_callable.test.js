"use strict";

/**
 * Guard-chain tests for the `deleteAccount` CALLABLE.
 *
 * Every PIECE it stands on is already covered — `isReauthStale`,
 * `enforceDurableRateLimit` and `runAccountDeletion` all have their own
 * suites. The WIRING was not covered at all, and this is the app's
 * user-facing irreversible path (Apple App Store Guideline 5.1.1(v)), so the
 * things that can silently regress here are worth pinning:
 *
 *   1. the guard ORDER — auth -> assertPayloadShape -> assertFreshReauth ->
 *      rate limit -> work. `assertFreshReauth` sits ABOVE the limiter on
 *      purpose, per its own comment: "so a stale-auth rejection doesn't burn
 *      one of the caller's deletion slots";
 *   2. the `stale-auth` error code, which is a STRING CONTRACT the Flutter
 *      client branches on to re-prompt for the password;
 *   3. the empty payload allowlist — this callable takes no fields at all;
 *   4. the `onAuthFailure` mapping to `internal/delete-auth-user-failed`.
 */

jest.mock("firebase-admin/firestore");
jest.mock("firebase-admin/auth");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));
jest.mock("../security", () => ({
  APP_CHECK: {enforceAppCheck: true},
  assertPayloadShape: jest.fn(),
  assertFreshReauth: jest.fn(),
  enforceDurableRateLimit: jest.fn(),
}));
jest.mock("../account_policy", () => ({
  runAccountDeletion: jest.fn(),
}));

const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const security = require("../security");
const accountPolicy = require("../account_policy");
const {deleteAccount} = require("../account");

const UID = "caller-uid";

/**
 * Invokes the callable and returns the HttpsError it threw.
 * @param {!Object} request
 * @return {!Promise<!Object>}
 */
async function expectRejection(request) {
  let caught = null;
  try {
    await deleteAccount.run(request);
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

/** A well-formed request from a freshly re-authenticated caller.
 * @return {!Object}
 */
const goodRequest = () => ({auth: {uid: UID, token: {auth_time: 1}}, data: {}});

beforeEach(() => {
  jest.clearAllMocks();
  security.assertPayloadShape.mockImplementation((data, allowed) => {
    if (data === undefined || data === null) return;
    for (const key of Object.keys(data)) {
      if (!allowed.has(key)) {
        throw new HttpsError("invalid-argument", "unexpected-field");
      }
    }
  });
  security.assertFreshReauth.mockImplementation(() => {});
  security.enforceDurableRateLimit.mockResolvedValue({refund: jest.fn()});
  accountPolicy.runAccountDeletion.mockResolvedValue({deleted: true});
  getFirestore.mockReturnValue({});
  getAuth.mockReturnValue({});
});

describe("deleteAccount callable", () => {
  test("an unauthenticated caller is refused first", async () => {
    const err = await expectRejection({auth: null, data: {}});
    expect(err.code).toBe("unauthenticated");
    expect(security.assertFreshReauth).not.toHaveBeenCalled();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    expect(accountPolicy.runAccountDeletion).not.toHaveBeenCalled();
  });

  test("a caller with auth but no uid is refused", async () => {
    const err = await expectRejection({auth: {}, data: {}});
    expect(err.code).toBe("unauthenticated");
  });

  test("the payload allowlist is EMPTY - no fields at all", async () => {
    await deleteAccount.run(goodRequest());
    const [, allowed] = security.assertPayloadShape.mock.calls[0];
    expect([...allowed]).toEqual([]);
  });

  test("an unexpected field is refused", async () => {
    const err = await expectRejection({
      auth: {uid: UID, token: {auth_time: 1}},
      data: {confirm: true},
    });
    expect(err.code).toBe("invalid-argument");
    expect(accountPolicy.runAccountDeletion).not.toHaveBeenCalled();
  });

  test("a stale re-auth surfaces the `stale-auth` code", async () => {
    security.assertFreshReauth.mockImplementation(() => {
      throw new HttpsError("unauthenticated", "stale-auth");
    });
    const err = await expectRejection(goodRequest());
    expect(err.message).toContain("stale-auth");
    expect(accountPolicy.runAccountDeletion).not.toHaveBeenCalled();
  });

  test("a stale re-auth does NOT burn a deletion slot", async () => {
    // The stated reason `assertFreshReauth` runs above the limiter: a user who
    // simply took too long between the password prompt and the tap must not
    // lose one of their five attempts to it.
    security.assertFreshReauth.mockImplementation(() => {
      throw new HttpsError("unauthenticated", "stale-auth");
    });
    await expectRejection(goodRequest());
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("guards run in the documented order", async () => {
    await deleteAccount.run(goodRequest());
    expectCalledBefore(
        security.assertPayloadShape, security.assertFreshReauth);
    expectCalledBefore(
        security.assertFreshReauth, security.enforceDurableRateLimit);
    expectCalledBefore(
        security.enforceDurableRateLimit, accountPolicy.runAccountDeletion);
  });

  test("the limiter is handed to the deletion so it can refund", async () => {
    const refund = jest.fn();
    security.enforceDurableRateLimit.mockResolvedValue({refund});
    await deleteAccount.run(goodRequest());
    const [deps] = accountPolicy.runAccountDeletion.mock.calls[0];
    expect(deps.limiter).toEqual({refund});
  });

  test("onAuthFailure maps to internal/delete-auth-user-failed", async () => {
    await deleteAccount.run(goodRequest());
    const [deps] = accountPolicy.runAccountDeletion.mock.calls[0];
    const err = deps.onAuthFailure();
    expect(err).toBeInstanceOf(HttpsError);
    expect(err.code).toBe("internal");
    expect(err.message).toContain("delete-auth-user-failed");
  });

  test("the caller's own uid is what gets deleted", async () => {
    await deleteAccount.run(goodRequest());
    const [, uid] = accountPolicy.runAccountDeletion.mock.calls[0];
    expect(uid).toBe(UID);
  });

  test("returns the policy's deleted flag to the client", async () => {
    accountPolicy.runAccountDeletion.mockResolvedValue({deleted: false});
    await expect(deleteAccount.run(goodRequest()))
        .resolves.toEqual({deleted: false});
  });
});
