"use strict";

/**
 * Tests for `enforceDurableRateLimit` — the app's only durable rate limiter,
 * guarding deleteAccount, completeEmployeeSetup, createEmployeeAccount,
 * deleteEmployeeAccount and deleteClient.
 *
 * Three of its decisions are load-bearing, documented only in comments, and
 * each silently reversible by a well-meaning "simplification":
 *   1. it stores per-attempt TIMESTAMPS, not a windowStart counter (a counter
 *      lets a caller burst 2x max across the window boundary);
 *   2. a REJECTED attempt is not recorded (or a hammering caller holds the
 *      window full forever);
 *   3. the refund removes exactly its own timestamp and swallows its errors.
 */

jest.mock("firebase-admin/firestore");
jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  warn: jest.fn(),
  debug: jest.fn(),
  error: jest.fn(),
}));

const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const {enforceDurableRateLimit} = require("../security");

/**
 * In-memory Firestore double with real read-modify-write transactions over a
 * single `rateLimits` doc.
 * @param {?Object} seed Initial doc data, or null for "does not exist".
 * @return {!Object} `{db, stored}` where `stored.data` is the live doc.
 */
function makeDb(seed = null) {
  const stored = {data: seed};
  const ref = {};
  const tx = {
    get: async () => ({
      exists: stored.data !== null,
      data: () => stored.data,
    }),
    set: (_ref, value, options) => {
      stored.data = options && options.merge ?
        {...(stored.data || {}), ...value} :
        value;
    },
  };
  const db = {
    collection: () => ({doc: () => ref}),
    runTransaction: async (fn) => fn(tx),
  };
  return {db, stored};
}

/**
 * @param {!Object} stored The doc holder returned by makeDb.
 * @return {number} How many attempts the limiter has recorded.
 */
function attemptCount(stored) {
  return stored.data && Array.isArray(stored.data.attempts) ?
    stored.data.attempts.length :
    0;
}

describe("enforceDurableRateLimit", () => {
  const ROUTE = "deleteAccount";
  const KEY = "uid-123";
  const MAX = 3;
  const WINDOW = 15 * 60 * 1000;

  beforeEach(() => jest.clearAllMocks());

  test("batch units are charged atomically and refunded together", async () => {
    const {db, stored} = makeDb();
    getFirestore.mockReturnValue(db);
    const charged = await enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW,
        "uid", 2);
    expect(attemptCount(stored)).toBe(2);
    await expect(enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW, "uid", 2))
        .rejects.toMatchObject({code: "resource-exhausted"});
    expect(attemptCount(stored)).toBe(2);
    await charged.refund();
    expect(attemptCount(stored)).toBe(0);
  });

  test.each([0, -1, 1.5, 4])("refuses batch cost %s", async (cost) => {
    await expect(enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW, "uid", cost))
        .rejects.toThrow("invalid-rate-limit-cost");
  });

  test("records an attempt and admits a caller under the cap", async () => {
    const {db, stored} = makeDb();
    getFirestore.mockReturnValue(db);

    await enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW);

    expect(attemptCount(stored)).toBe(1);
    expect(stored.data.route).toBe(ROUTE);
    // The TTL stamp is what lets a Firestore policy reap the row.
    expect(stored.data.expiresAt).toBeInstanceOf(Date);
  });

  test("rejects with resource-exhausted at the cap", async () => {
    const now = Date.now();
    const {db} = makeDb({route: ROUTE, attempts: [now, now, now]});
    getFirestore.mockReturnValue(db);

    await expect(enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW))
        .rejects.toMatchObject({
          code: "resource-exhausted",
          message: expect.stringContaining("too-many-attempts"),
        });
  });

  test("a rejected attempt is NOT recorded", async () => {
    const now = Date.now();
    const {db, stored} = makeDb({route: ROUTE, attempts: [now, now, now]});
    getFirestore.mockReturnValue(db);

    await expect(enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW))
        .rejects.toThrow();

    // Recording rejections would let a hammering caller hold the window full
    // forever, so the legitimate owner never recovers.
    expect(attemptCount(stored)).toBe(3);
  });

  test("expired timestamps drop out, freeing the window", async () => {
    const old = Date.now() - WINDOW - 1;
    const {db, stored} = makeDb({route: ROUTE, attempts: [old, old, old]});
    getFirestore.mockReturnValue(db);

    await enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW);

    // All three aged out; only the new attempt survives.
    expect(attemptCount(stored)).toBe(1);
  });

  test("per-attempt timestamps stop a burst across the window boundary",
      async () => {
        const now = Date.now();
        // Two attempts late in the window, one just aged out. A windowStart
        // COUNTER would have reset to zero here and allowed a fresh full max;
        // per-attempt stamps correctly still count the two recent ones.
        const {db, stored} = makeDb({
          route: ROUTE,
          attempts: [now - WINDOW - 1, now - 1000, now - 500],
        });
        getFirestore.mockReturnValue(db);

        await enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW);
        expect(attemptCount(stored)).toBe(3);

        // The 4th live attempt inside the window must be refused.
        await expect(enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW))
            .rejects.toMatchObject({code: "resource-exhausted"});
      });

  test("logs a hashed key, never the raw one", async () => {
    const now = Date.now();
    const email = "someone@example.com";
    const {db} = makeDb({route: ROUTE, attempts: [now, now, now]});
    getFirestore.mockReturnValue(db);

    await expect(
        enforceDurableRateLimit(ROUTE, email, MAX, WINDOW, "email"),
    ).rejects.toThrow();

    const [, payload] = logger.warn.mock.calls[0];
    expect(payload.keyKind).toBe("email");
    expect(payload.keyHash).toEqual(expect.any(String));
    expect(JSON.stringify(payload)).not.toContain(email);
  });

  test("refund removes exactly its own attempt", async () => {
    const earlier = Date.now() - 1000;
    const {db, stored} = makeDb({route: ROUTE, attempts: [earlier]});
    getFirestore.mockReturnValue(db);

    const {refund} = await enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW);
    expect(attemptCount(stored)).toBe(2);

    await refund();

    // The other caller's attempt survives; only ours is given back.
    expect(stored.data.attempts).toEqual([earlier]);
  });

  test("a failing refund is swallowed, not thrown at the caller", async () => {
    const {db} = makeDb();
    getFirestore.mockReturnValue(db);
    const {refund} = await enforceDurableRateLimit(ROUTE, KEY, MAX, WINDOW);

    db.runTransaction = async () => {
      throw new Error("unavailable");
    };

    // Refunding is an optimization on an error path — it must never replace
    // the caller's real error with its own.
    await expect(refund()).resolves.toBeUndefined();
    expect(logger.warn).toHaveBeenCalledWith(
        "enforceDurableRateLimit: refund failed",
        expect.objectContaining({route: ROUTE}),
    );
  });
});
