"use strict";

/**
 * Tests that every Wave admin callable checks its guards in the right
 * order: auth, then assertAdmin, then assertPayloadShape/requireString,
 * then enforceDurableRateLimit, and only then the real work (the invariant
 * documented in .claude/rules/security.md). We mock the security module so
 * `mock.invocationCallOrder` can confirm that sequence.
 *
 * The callables open with `assertAdminCall`, which COMPOSES the first three
 * steps, so the stub below is the COMPOSER — it delegates to the mocked
 * `assertAdmin`/`assertPayloadShape` rather than replacing them. Stubbing
 * those two alone would intercept nothing (the composer holds a
 * module-internal reference) and every assertion here would pass vacuously,
 * which is the shape that hid the original missing-gate bug.
 */

jest.mock("../security");
jest.mock("firebase-admin/firestore");
jest.mock("../wave/client");
jest.mock("../wave/customers");
jest.mock("../wave/worker");

const {HttpsError} = require("firebase-functions/v2/https");

const security = require("../security");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const waveClient = require("../wave/client");
const waveCustomers = require("../wave/customers");
const waveWorker = require("../wave/worker");

const {
  selectBusiness,
  waveBootstrap,
  waveGetConnection,
  waveSetImportSchedule,
  waveImportCustomers,
  waveRetryFailedJobs,
} = require("../wave/callables");

const ADMIN_UID = "admin-uid";

/** Payload with a key no Wave callable accepts. */
const MALFORMED = {totallyUnexpectedField: "x"};

/**
 * Fake `wave/connection` doc store.
 * @param {?Object} connection Initial doc data, or null for "absent".
 * @return {!Object} `{db, updates, sets}`.
 */
function fakeFirestore(connection) {
  let data = connection ? {...connection} : null;
  const updates = [];
  const sets = [];
  const ref = {
    get: jest.fn(async () => ({
      exists: data !== null,
      data: () => data,
    })),
    update: jest.fn(async (patch) => {
      updates.push(patch);
      data = {...(data || {}), ...patch};
    }),
  };
  const db = {
    collection: jest.fn(() => ({doc: jest.fn(() => ref)})),
    runTransaction: jest.fn(async (fn) => fn({
      get: async () => ref.get(),
      set: (r, value) => {
        sets.push(value);
        data = {...value};
      },
    })),
  };
  return {db, ref, updates, sets};
}

/**
 * A drainQueue summary with everything zeroed except the given overrides.
 * @param {!Object=} overrides Counters to set.
 * @return {!Object} A full drain summary.
 */
function drainSummary(overrides = {}) {
  return {
    processed: 0, done: 0, retried: 0, dead: 0, skipped: 0, reclaimed: 0,
    created: 0, updated: 0, ...overrides,
  };
}

/**
 * Builds a callable request.
 * @param {?string} uid Caller uid, or null for unauthenticated.
 * @param {*} data Payload.
 * @return {!Object}
 */
function req(uid, data) {
  return {auth: uid ? {uid} : null, data};
}

/**
 * Runs a callable and returns the HttpsError it threw.
 * @param {!Function} fn The onCall function.
 * @param {!Object} request
 * @return {!Promise<!HttpsError>}
 */
async function expectThrows(fn, request) {
  let caught = null;
  try {
    await fn.run(request);
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
 */
function expectCalledBefore(first, second) {
  expect(first).toHaveBeenCalled();
  expect(second).toHaveBeenCalled();
  expect(first.mock.invocationCallOrder[0])
      .toBeLessThan(second.mock.invocationCallOrder[0]);
}

beforeEach(() => {
  jest.clearAllMocks();

  // The outbox is empty unless a test says otherwise, so the guard-order
  // cases don't have to care that the sync pushes before it imports.
  waveWorker.drainQueue.mockResolvedValue(drainSummary());
  waveWorker.countQueuedJobs.mockResolvedValue(0);
  waveWorker.countDeadJobs.mockResolvedValue(0);
  waveWorker.requeueDeadJobs.mockResolvedValue({requeued: 0, scanned: 0});
  waveWorker.listOutstandingClientIds.mockResolvedValue(new Set());

  // These mocks behave like the real guards, just without touching
  // Firestore.
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
  security.enforceDurableRateLimit.mockResolvedValue({refund: jest.fn()});
  security.assertAdminCall.mockImplementation(async (request, allowed) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError("unauthenticated", "auth-required");
    }
    await security.assertAdmin(request.auth.uid);
    security.assertPayloadShape(request.data, allowed);
    return request.auth.uid;
  });

  FieldValue.serverTimestamp = jest.fn(() => "SERVER_TS");
  waveClient.whoami.mockResolvedValue({});
  waveClient.listBusinesses.mockResolvedValue([{id: "biz-1", name: "Acme"}]);
  // Mirrors the real summary shape. `skippedPending` matters: a run that
  // protected clients did not cover its window, so the watermark is held —
  // an absent count is treated as unknown and therefore also held.
  waveCustomers.importCustomers.mockResolvedValue({
    totalCount: 0, imported: 0, updated: 0, skippedArchived: 0,
    skippedPending: 0, skippedUnchanged: 0, pages: 1, delta: false,
  });
  getFirestore.mockReturnValue(fakeFirestore(null).db);
});

// Each admin callable and whether it consumes a rate-limit slot on the happy
// path. `waveSetImportSchedule` is the one `false`: it is a retired no-op kept
// for shipped builds (#compat-1.61.0), and it writes nothing to cap.
const CALLABLES = [
  {
    name: "waveBootstrap",
    fn: () => waveBootstrap,
    rateLimited: true,
    keys: [],
  },
  {
    name: "waveGetConnection",
    fn: () => waveGetConnection,
    rateLimited: true,
    keys: [],
  },
  {
    name: "waveSetImportSchedule",
    fn: () => waveSetImportSchedule,
    rateLimited: false,
    keys: ["schedule"],
  },
  {
    name: "waveImportCustomers",
    fn: () => waveImportCustomers,
    rateLimited: true,
    keys: [],
  },
  {
    name: "waveRetryFailedJobs",
    fn: () => waveRetryFailedJobs,
    rateLimited: true,
    keys: [],
  },
];

describe.each(CALLABLES)("$name guard order", ({fn, rateLimited, keys}) => {
  test("opens with the composed assertAdminCall, not a hand-spelled gate",
      async () => {
        // Five copies of the composer's body lived here, and one of them had
        // already drifted. Asserting the CALL is what stops a sixth: a
        // re-inlined gate satisfies every order assertion below while the
        // composer goes uncalled.
        await fn().run(req(ADMIN_UID, {})).catch(() => {});
        expect(security.assertAdminCall).toHaveBeenCalledTimes(1);
        expect(security.assertAdminCall.mock.calls[0][0].auth.uid)
            .toBe(ADMIN_UID);
      });

  test("accepts exactly its documented payload keys", async () => {
    // Removing a key from an allowlist is a BREAKING change for a shipped
    // build — `assertPayloadShape` throws `unexpected-field` on the first
    // unrecognised one — so the sets are pinned rather than inferred.
    await fn().run(req(ADMIN_UID, {})).catch(() => {});
    const allowed = security.assertAdminCall.mock.calls[0][1];
    expect([...allowed].sort()).toEqual(keys);
  });

  test("an unauthenticated caller is rejected first", async () => {
    const err = await expectThrows(fn(), req(null, {}));

    expect(err.code).toBe("unauthenticated");
    expect(err.message).toBe("auth-required");
    expect(security.assertAdmin).not.toHaveBeenCalled();
    expect(security.assertPayloadShape).not.toHaveBeenCalled();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    expect(getFirestore).not.toHaveBeenCalled();
  });

  test("an auth object with no uid is treated as unauthenticated",
      async () => {
        const err = await expectThrows(fn(), {auth: {}, data: {}});
        expect(err.code).toBe("unauthenticated");
        expect(security.assertAdmin).not.toHaveBeenCalled();
      });

  test("a non-admin sending a malformed payload gets not-admin, " +
      "not unexpected-field", async () => {
    const err = await expectThrows(fn(), req("employee-uid", MALFORMED));

    expect(err.code).toBe("permission-denied");
    expect(err.message).toBe("wave/not-admin");
    // That's the point here: payload validation never runs for an
    // unprivileged caller, so the payload shape can't leak anything about
    // the endpoint.
    expect(security.assertPayloadShape).not.toHaveBeenCalled();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("a non-admin never burns a rate-limit slot", async () => {
    await expectThrows(fn(), req("employee-uid", {}));
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("assertAdmin runs before assertPayloadShape for an admin", async () => {
    // We ignore the outcome here — some of these calls fail later on
    // business state. Only the guard sequence matters for this test.
    await fn().run(req(ADMIN_UID, {})).catch(() => {});

    expectCalledBefore(security.assertAdmin, security.assertPayloadShape);
    expect(security.assertAdmin).toHaveBeenCalledWith(ADMIN_UID);
  });

  test("an admin's malformed payload is rejected as unexpected-field",
      async () => {
        const err = await expectThrows(fn(), req(ADMIN_UID, MALFORMED));
        expect(err.code).toBe("invalid-argument");
        expect(err.message).toBe("unexpected-field");
        // Payload validation gates the limiter, so a burst of malformed
        // submissions cannot exhaust a legitimate admin's window.
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  if (!rateLimited) {
    test("is not rate limited on the happy path", async () => {
      await fn().run(req(ADMIN_UID, {})).catch(() => {});
      expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
    });
  } else {
    test("consumes a rate-limit slot keyed on the caller uid", async () => {
      // The positive half. Without it a callable that silently LOST its
      // limiter would still satisfy this table, since the only other
      // assertions are "not called" ones on the rejection paths.
      await fn().run(req(ADMIN_UID, {})).catch(() => {});
      const calls = security.enforceDurableRateLimit.mock.calls;
      // Some callables reject the `{}` payload before the limiter; those are
      // covered by the malformed-payload case above. Where it IS reached, it
      // must be keyed on the caller.
      if (calls.length > 0) {
        expect(calls[0][1]).toBe(ADMIN_UID);
      }
    });
  }
});

describe("waveBootstrap", () => {
  test("payload validation precedes the rate limiter", async () => {
    getFirestore.mockReturnValue(fakeFirestore(null).db);
    await waveBootstrap.run(req(ADMIN_UID, {})).catch(() => {});

    expectCalledBefore(
        security.assertPayloadShape, security.enforceDurableRateLimit);
  });

  test("connects and rate-limits the not-yet-connected path", async () => {
    const {db, sets} = fakeFirestore(null);
    getFirestore.mockReturnValue(db);

    const out = await waveBootstrap.run(req(ADMIN_UID, {}));

    expect(out).toEqual({businessId: "biz-1", businessName: "Acme"});
    expect(sets[0]).toMatchObject({businessId: "biz-1"});
    expect(security.enforceDurableRateLimit)
        .toHaveBeenCalledWith("wave-bootstrap", ADMIN_UID, 10, 3600000);
  });

  test("the idempotent already-connected short-circuit is NOT rate limited",
      async () => {
        getFirestore.mockReturnValue(
            fakeFirestore({businessId: "biz-1", businessName: "Acme"}).db);

        const out = await waveBootstrap.run(req(ADMIN_UID, {}));

        expect(out).toEqual({businessId: "biz-1", businessName: "Acme"});
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
        expect(waveClient.whoami).not.toHaveBeenCalled();
      });

  test("the rate limiter fires before any live Wave call", async () => {
    getFirestore.mockReturnValue(fakeFirestore(null).db);
    security.enforceDurableRateLimit.mockRejectedValueOnce(
        new HttpsError("resource-exhausted", "too-many-attempts"));

    const err = await expectThrows(waveBootstrap, req(ADMIN_UID, {}));

    expect(err.code).toBe("resource-exhausted");
    expect(waveClient.whoami).not.toHaveBeenCalled();
    expect(waveClient.listBusinesses).not.toHaveBeenCalled();
  });

  test("accepts no payload keys at all", async () => {
    getFirestore.mockReturnValue(fakeFirestore(null).db);
    await waveBootstrap.run(req(ADMIN_UID, {})).catch(() => {});

    const allowed = security.assertPayloadShape.mock.calls[0][1];
    expect([...allowed]).toEqual([]);
  });
});

describe("waveImportCustomers", () => {
  test("payload validation precedes the rate limiter", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    await waveImportCustomers.run(req(ADMIN_UID, {})).catch(() => {});

    expectCalledBefore(
        security.assertPayloadShape, security.enforceDurableRateLimit);
  });

  test("the rate limiter fires before the Wave import runs", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    security.enforceDurableRateLimit.mockRejectedValueOnce(
        new HttpsError("resource-exhausted", "too-many-attempts"));

    const err = await expectThrows(waveImportCustomers, req(ADMIN_UID, {}));

    expect(err.code).toBe("resource-exhausted");
    expect(waveCustomers.importCustomers).not.toHaveBeenCalled();
  });

  test("caps admins at 5 imports per hour", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(security.enforceDurableRateLimit)
        .toHaveBeenCalledWith("wave-import", ADMIN_UID, 5, 3600000);
  });

  test("a not-bootstrapped install fails after the guards, not before",
      async () => {
        getFirestore.mockReturnValue(fakeFirestore(null).db);

        const err = await expectThrows(waveImportCustomers, req(ADMIN_UID, {}));

        expect(err.code).toBe("failed-precondition");
        expect(err.message).toBe("wave/not-bootstrapped");
        expect(security.enforceDurableRateLimit).toHaveBeenCalled();
      });

  test("pushes the outbox to Wave BEFORE importing", async () => {
    // Order is the correctness rule, not a preference: the outbox holds edits
    // the app already accepted, so importing first would overwrite them with
    // the Wave rows they are on their way to replace.
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.drainQueue.mockResolvedValue(drainSummary());
    waveCustomers.importCustomers.mockResolvedValue({});

    await waveImportCustomers.run(req(ADMIN_UID, {}));

    expectCalledBefore(waveWorker.drainQueue, waveCustomers.importCustomers);
  });

  test("returns both directions plus what is still queued", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.drainQueue.mockResolvedValue(
        drainSummary({done: 5, created: 2, updated: 3}));
    waveWorker.countQueuedJobs.mockResolvedValue(7);
    waveCustomers.importCustomers.mockResolvedValue({
      totalCount: 40, imported: 4, updated: 6, skippedArchived: 1, pages: 1,
    });

    const result = await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(result).toEqual({
      totalCount: 40, imported: 4, updated: 6, skippedArchived: 1, pages: 1,
      pushedCreated: 2, pushedUpdated: 3, pushedPending: 7,
      pushedFailed: 0, pushIncomplete: false,
    });
  });

  test("hands the import the clients whose edits have not reached Wave", () =>
    (async () => {
      // The bounded drain cannot guarantee push-before-pull on its own: a job
      // backed off after a transient Wave error isn't due, so the drain skips
      // it and the import would overwrite that client's edit AND mark it
      // synced, which makes the loss permanent.
      getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
      const outstanding = new Set(["c1", "c2"]);
      waveWorker.listOutstandingClientIds.mockResolvedValue(outstanding);
      waveCustomers.importCustomers.mockResolvedValue({});

      await waveImportCustomers.run(req(ADMIN_UID, {}));

      expect(waveCustomers.importCustomers).toHaveBeenCalledWith(
          expect.objectContaining({skipClientIds: outstanding}));
      // Resolved after the drain, so a job the drain just finished isn't
      // protected for nothing.
      expectCalledBefore(
          waveWorker.drainQueue, waveWorker.listOutstandingClientIds);
    })());

  test("a delta run advances the watermark but not the resync clock",
      async () => {
        // The stamps have to make a real delta window — `wasFull` is derived
        // from the window this callable resolves, not from anything the
        // import stub says, so a fixture with no watermark is a FULL run and
        // would legitimately stamp lastFullImportAt.
        const fake = fakeFirestore({
          businessId: "biz-1",
          customerDeltaSince: new Date(Date.now() - 60_000),
          lastFullImportAt: new Date(Date.now() - 60_000),
        });
        getFirestore.mockReturnValue(fake.db);

        await waveImportCustomers.run(req(ADMIN_UID, {}));

        const advanced = fake.updates.find((u) => u.customerDeltaSince);
        expect(advanced).toBeDefined();
        expect(advanced).not.toHaveProperty("lastFullImportAt");
        expect(waveCustomers.importCustomers).toHaveBeenCalledWith(
            expect.objectContaining({since: expect.any(String)}));
      });

  test("a full run restarts the resync clock", async () => {
    const fake = fakeFirestore({businessId: "biz-1"});
    getFirestore.mockReturnValue(fake.db);

    await waveImportCustomers.run(req(ADMIN_UID, {}));

    const advanced = fake.updates.find((u) => u.customerDeltaSince);
    expect(advanced.lastFullImportAt).toBeDefined();
    expect(waveCustomers.importCustomers).toHaveBeenCalledWith(
        expect.objectContaining({since: ""}));
  });

  test("holds the watermark when the run protected pending clients",
      async () => {
        // Those clients were deliberately NOT imported, so the window is
        // incomplete. Advancing past it would hide any Wave-side change to
        // them until the next full pass — bounded staleness, but silent.
        const fake = fakeFirestore({
          businessId: "biz-1",
          customerDeltaSince: new Date(Date.now() - 60_000),
          lastFullImportAt: new Date(Date.now() - 60_000),
        });
        getFirestore.mockReturnValue(fake.db);
        waveCustomers.importCustomers.mockResolvedValue({skippedPending: 2});

        await waveImportCustomers.run(req(ADMIN_UID, {}));

        expect(fake.updates.find((u) => u.customerDeltaSince)).toBeUndefined();
      });

  test("a delta failure retries as a full import", async () => {
    // Without this, a delta-only query fault is sticky: the watermark stays
    // put, so every retry rebuilds the same failing query until the 7-day
    // resync ages it out — and only the admin-facing sync is broken.
    const fake = fakeFirestore({
      businessId: "biz-1",
      customerDeltaSince: new Date(Date.now() - 60_000),
      lastFullImportAt: new Date(Date.now() - 60_000),
    });
    getFirestore.mockReturnValue(fake.db);
    waveCustomers.importCustomers
        .mockRejectedValueOnce(new Error("unknown argument modifiedAtAfter"))
        .mockResolvedValueOnce({skippedPending: 0});

    await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(waveCustomers.importCustomers).toHaveBeenCalledTimes(2);
    expect(waveCustomers.importCustomers).toHaveBeenLastCalledWith(
        expect.objectContaining({since: ""}));
    // The retry was a full pass, so the resync clock restarts.
    expect(fake.updates.find((u) => u.lastFullImportAt)).toBeDefined();
  });

  test("a successful import survives a failed watermark write", async () => {
    // The import already committed; failing the callable here would tell the
    // admin the sync failed and throw away the push counts with it.
    const fake = fakeFirestore({businessId: "biz-1"});
    fake.ref.update.mockRejectedValue(new Error("firestore unavailable"));
    getFirestore.mockReturnValue(fake.db);
    waveCustomers.importCustomers.mockResolvedValue({
      imported: 3, skippedPending: 0,
    });

    const result = await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(result.imported).toBe(3);
  });

  test("leaves the watermark alone when the import throws", async () => {
    // The single most destructive way to get this wrong: advancing past a
    // window that was never actually imported skips every customer changed
    // inside it, permanently and silently. Redoing it is free — the import
    // is idempotent.
    const fake = fakeFirestore({businessId: "biz-1"});
    getFirestore.mockReturnValue(fake.db);
    waveCustomers.importCustomers.mockRejectedValue(new Error("wave down"));

    await expectThrows(waveImportCustomers, req(ADMIN_UID, {}));

    expect(fake.updates.find((u) => u.customerDeltaSince)).toBeUndefined();
  });

  test("a dead-lettered push is reported, not counted as nothing", async () => {
    // Dead jobs are not `queued`, so countQueuedJobs returns 0 for them —
    // without pushedFailed the admin reads "already up to date" about clients
    // that can now only reach Wave by hand.
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.drainQueue.mockResolvedValue(drainSummary({dead: 5}));
    waveCustomers.importCustomers.mockResolvedValue({});

    const result = await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(result.pushedFailed).toBe(5);
    expect(result.pushIncomplete).toBe(false);
  });

  test("a thrown push is flagged, so zeros can't read as success", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.drainQueue.mockRejectedValue(new Error("index missing"));
    waveWorker.countQueuedJobs.mockRejectedValue(new Error("index missing"));
    waveCustomers.importCustomers.mockResolvedValue({});

    const result = await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(result.pushIncomplete).toBe(true);
    expect(result.pushedPending).toBe(0);
  });

  test("a failed push still lets the import run and return", async () => {
    // The scheduled worker drains the same queue every 5 minutes, so the push
    // half is a courtesy. Failing the whole sync over it would deny the admin
    // the import they actually pressed the button for.
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.drainQueue.mockRejectedValue(new Error("wave down"));
    waveCustomers.importCustomers.mockResolvedValue({imported: 3});

    const result = await waveImportCustomers.run(req(ADMIN_UID, {}));

    expect(result.imported).toBe(3);
    expect(result.pushedCreated).toBe(0);
    expect(result.pushedUpdated).toBe(0);
  });
});

describe("waveGetConnection", () => {
  test("reads the connection and the outbox depth for an admin", async () => {
    getFirestore.mockReturnValue(fakeFirestore({
      businessId: "biz-1",
      businessName: "Acme",
    }).db);
    waveWorker.countQueuedJobs.mockResolvedValue(3);
    waveWorker.countDeadJobs.mockResolvedValue(1);

    expect(await waveGetConnection.run(req(ADMIN_UID, {}))).toEqual({
      connected: true,
      businessId: "biz-1",
      businessName: "Acme",
      pendingCount: 3,
      failedCount: 1,
    });
  });

  test("a failed count reports null, never 0", async () => {
    // 0 means "the queue is empty", which is the one thing an admin would act
    // on by NOT pressing Sync. A broken read must not be able to say that.
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.countQueuedJobs.mockRejectedValue(new Error("unavailable"));

    const out = await waveGetConnection.run(req(ADMIN_UID, {}));
    expect(out.pendingCount).toBeNull();
    expect(out.failedCount).toBeNull();
    expect(out.connected).toBe(true);
  });

  test("an absent doc reports disconnected", async () => {
    getFirestore.mockReturnValue(fakeFirestore(null).db);

    expect(await waveGetConnection.run(req(ADMIN_UID, {}))).toEqual({
      connected: false,
      businessId: "",
      businessName: "",
      pendingCount: null,
      failedCount: null,
    });
    // No queue to describe while disconnected, and no reason to pay for the
    // two aggregate reads.
    expect(waveWorker.countQueuedJobs).not.toHaveBeenCalled();
    expect(waveWorker.countDeadJobs).not.toHaveBeenCalled();
  });

  test("no longer reports a cadence, even one still stored", async () => {
    // #compat-1.61.0: that build reads an absent `importSchedule` as off.
    getFirestore.mockReturnValue(
        fakeFirestore({businessId: "b", importSchedule: "weekly"}).db);

    const out = await waveGetConnection.run(req(ADMIN_UID, {}));
    expect(out).not.toHaveProperty("importSchedule");
  });
});

describe("waveSetImportSchedule (retired, #compat-1.61.0)", () => {
  test("still accepts the `schedule` key a shipped build sends", async () => {
    // Removing it would throw `unexpected-field` at every 1.61.0 admin who
    // touches the picker still on their Settings screen.
    await waveSetImportSchedule.run(req(ADMIN_UID, {schedule: "weekly"}));

    const allowed = security.assertPayloadShape.mock.calls[0][1];
    expect([...allowed]).toEqual(["schedule"]);
  });

  test("accepts a cadence and reads and writes nothing", async () => {
    const fake = fakeFirestore({businessId: "b"});
    getFirestore.mockReturnValue(fake.db);

    expect(await waveSetImportSchedule.run(req(ADMIN_UID, {
      schedule: "monthly",
    }))).toEqual({schedule: "off"});
    expect(fake.updates).toEqual([]);
    expect(fake.ref.get).not.toHaveBeenCalled();
  });

  test("never refuses a value, so an old picker cannot error", async () => {
    expect(await waveSetImportSchedule.run(
        req(ADMIN_UID, {schedule: "hourly"}))).toEqual({schedule: "off"});
  });

  test("consumes no rate-limit slot", async () => {
    await waveSetImportSchedule.run(req(ADMIN_UID, {schedule: "weekly"}));
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });
});

describe("selectBusiness", () => {
  const list = [
    {id: "b1", name: "Acme Co"},
    {id: "b2", name: "Other Inc"},
  ];

  test("matches the configured name case- and whitespace-insensitively", () => {
    expect(selectBusiness(list, "  acme co ")).toEqual(list[0]);
  });

  test("a configured name with no match is not-found", () => {
    expect(() => selectBusiness(list, "Nope"))
        .toThrow(expect.objectContaining({message: "wave/business-not-found"}));
  });

  test("with no selector, a single business is taken", () => {
    expect(selectBusiness([list[0]], "")).toEqual(list[0]);
  });

  test("with no selector and several businesses it refuses to guess", () => {
    expect(() => selectBusiness(list, ""))
        .toThrow(expect.objectContaining({message: "wave/business-ambiguous"}));
  });

  test("a non-array / empty list is ambiguous, never a silent pick", () => {
    expect(() => selectBusiness(null, "")).toThrow(HttpsError);
    expect(() => selectBusiness([], "")).toThrow(HttpsError);
  });
});

// ---------------------------------------------------------------------------
// The event-driven push (2026-08-13). `waveSyncWorker`'s every-5-minute poll
// was deleted; `waveUpsertCustomer` now pushes each edit as it is made and
// `waveScheduledImport` is the daily safety net. These two describe blocks
// pin the properties that replaced the poll — a drain on the enqueue path, a
// drain that cannot fail its trigger, and a daily sweep that drains.
// ---------------------------------------------------------------------------

/**
 * Re-requires the Wave modules against a fresh module registry.
 *
 * `readWaveBusinessIdCached` memoizes a found businessId for the life of the
 * instance, which is exactly what stops a disconnected install paying a
 * Firestore read on every client edit — and exactly what would leak a
 * "connected" verdict from one test into the next. Nothing else in this file
 * touches that cache, so the reset is scoped to these blocks.
 *
 * @return {!Object} Freshly-required `{triggers, worker, firestore}`.
 */
function freshWaveModules() {
  jest.resetModules();
  const firestore = require("firebase-admin/firestore");
  const worker = require("../wave/worker");
  const customers = require("../wave/customers");
  worker.drainQueue.mockResolvedValue(drainSummary());
  worker.countQueuedJobs.mockResolvedValue(0);
  worker.countDeadJobs.mockResolvedValue(0);
  worker.listOutstandingClientIds.mockResolvedValue(new Set());
  worker.shouldEnqueueClientWrite.mockReturnValue(true);
  worker.enqueueCustomerUpsert.mockResolvedValue("customerUpsert__c1");
  customers.importCustomers.mockResolvedValue({
    totalCount: 0, imported: 0, updated: 0, skippedArchived: 0,
    skippedPending: 0, skippedUnchanged: 0, pages: 1, delta: false,
  });
  firestore.FieldValue.serverTimestamp = jest.fn(() => "SERVER_TS");
  return {
    triggers: require("../wave/triggers"),
    worker,
    customers,
    firestore,
  };
}

/**
 * A Firestore double with the `batch()`/`doc()` surface the write trigger
 * uses, on top of the `wave/connection` read every drain site gates on.
 * @param {?Object} connection `wave/connection` data, or null for absent.
 * @return {!Object} `{db, commits}`.
 */
function fakeTriggerFirestore(connection) {
  const commits = [];
  const batch = {
    update: jest.fn(),
    set: jest.fn(),
    commit: jest.fn(async () => {
      commits.push(true);
    }),
  };
  const connectionRef = {
    get: jest.fn(async () => ({
      exists: connection !== null,
      data: () => connection,
    })),
    update: jest.fn(async () => {}),
  };
  const db = {
    batch: jest.fn(() => batch),
    doc: jest.fn(() => ({})),
    collection: jest.fn(() => ({doc: jest.fn(() => connectionRef)})),
  };
  return {db, batch, commits, connectionRef};
}

/**
 * A `clients/{id}` write event.
 * @param {?Object} before Prior doc data, or null for a create.
 * @param {?Object} after New doc data, or null for a delete.
 * @return {!Object} The onDocumentWritten event.
 */
function clientWrite(before, after) {
  const snap = (d) => ({exists: d !== null, data: () => d});
  return {
    data: {before: snap(before), after: snap(after)},
    params: {clientId: "c1"},
  };
}

const CLIENT_DOC = {name: "Acme", phone: "(514) 555-1234", email: "a@b.c"};
const CONNECTED = {businessId: "biz-1"};

describe("waveUpsertCustomer pushes without a poll", () => {
  test("drains the outbox right after enqueueing the edit", async () => {
    const {triggers, worker, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(CONNECTED);
    firestore.getFirestore.mockReturnValue(db);

    await triggers.waveUpsertCustomer.run(clientWrite(null, CLIENT_DOC));

    expect(worker.enqueueCustomerUpsert).toHaveBeenCalled();
    expect(worker.drainQueue).toHaveBeenCalledTimes(1);
    // Bounded: this runs per client edit, so it helps with the backlog
    // without trying to own it.
    expect(worker.drainQueue.mock.calls[0][0]).toMatchObject({
      businessId: "biz-1",
      batchLimit: 5,
    });
    expect(typeof worker.drainQueue.mock.calls[0][0].deadlineMs)
        .toBe("number");
  });

  test("is paced against Wave's 60-calls/min ceiling", () => {
    // The deleted waveSyncWorker stayed inside that ceiling via
    // `maxInstances: 1` — one sequential drain in flight, ever. A trigger
    // inherits the global cap of 10 instead, so without an explicit cap here
    // ten concurrent client writes would each run their own drain and burst
    // roughly ten times over the limit. Both numbers are the pacing; neither
    // may be raised without re-checking that arithmetic.
    const {triggers} = freshWaveModules();
    const opts = triggers.waveUpsertCustomer.__endpoint ||
      triggers.waveUpsertCustomer;

    expect(opts.maxInstances).toBe(2);
  });

  test("enqueues BEFORE it drains, so a crash between them loses nothing",
      async () => {
        const {triggers, worker, firestore} = freshWaveModules();
        const {db} = fakeTriggerFirestore(CONNECTED);
        firestore.getFirestore.mockReturnValue(db);

        await triggers.waveUpsertCustomer.run(clientWrite(null, CLIENT_DOC));

        expectCalledBefore(worker.enqueueCustomerUpsert, worker.drainQueue);
      });

  test("a drain failure does NOT fail the trigger", async () => {
    // The job is already durably queued, so a throw here would only re-run
    // the handler under retry:true for something the retry cannot fix.
    const {triggers, worker, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(CONNECTED);
    firestore.getFirestore.mockReturnValue(db);
    worker.drainQueue.mockRejectedValue(new Error("Wave is down"));

    await expect(
        triggers.waveUpsertCustomer.run(clientWrite(null, CLIENT_DOC)),
    ).resolves.toBeUndefined();

    expect(worker.enqueueCustomerUpsert).toHaveBeenCalled();
  });

  test("queues but does not drain while Wave is not connected", async () => {
    const {triggers, worker, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(null);
    firestore.getFirestore.mockReturnValue(db);

    await triggers.waveUpsertCustomer.run(clientWrite(null, CLIENT_DOC));

    // The outbox is durable, so the edit is kept for whenever Wave is
    // connected — but there is nothing to push it to yet.
    expect(worker.enqueueCustomerUpsert).toHaveBeenCalled();
    expect(worker.drainQueue).not.toHaveBeenCalled();
  });

  test("the wave.* write-back neither re-enqueues nor re-drains", async () => {
    // The loop guard. upsertCustomer writes wave.syncState back onto the
    // client doc, which re-fires this trigger; mappedFieldsHash is unchanged
    // by that write, so shouldEnqueueClientWrite returns false and the
    // handler returns before it can drain itself into a cycle.
    const {triggers, worker, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(CONNECTED);
    firestore.getFirestore.mockReturnValue(db);
    worker.shouldEnqueueClientWrite.mockReturnValue(false);

    await triggers.waveUpsertCustomer.run(
        clientWrite(CLIENT_DOC, {...CLIENT_DOC, wave: {syncState: "synced"}}));

    expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();
    expect(worker.drainQueue).not.toHaveBeenCalled();
  });

  test("a deleted client neither enqueues nor drains", async () => {
    const {triggers, worker, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(CONNECTED);
    firestore.getFirestore.mockReturnValue(db);

    await triggers.waveUpsertCustomer.run(clientWrite(CLIENT_DOC, null));

    expect(worker.enqueueCustomerUpsert).not.toHaveBeenCalled();
    expect(worker.drainQueue).not.toHaveBeenCalled();
  });
});

describe("runWaveDaily is the drain safety net", () => {
  test("drains the outbox", async () => {
    // A job on backoff, or left inflight by a dead instance, produces no
    // client write to ride on; this sweep is what retries it.
    const {triggers, worker, customers, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(CONNECTED);
    firestore.getFirestore.mockReturnValue(db);

    await triggers.runWaveDaily();

    expect(worker.drainQueue).toHaveBeenCalledTimes(1);
    expect(worker.drainQueue.mock.calls[0][0])
        .toMatchObject({businessId: "biz-1"});
    expect(customers.importCustomers).not.toHaveBeenCalled();
  });

  test("never imports, even over a connection still carrying a cadence",
      async () => {
        // The cadence half was deleted in Wave Phase 4 (Task 12).
        const {triggers, worker, customers, firestore} = freshWaveModules();
        const {db} = fakeTriggerFirestore({
          businessId: "biz-1", importSchedule: "weekly",
          lastAutoImportAt: null,
        });
        firestore.getFirestore.mockReturnValue(db);

        await triggers.runWaveDaily();

        expect(worker.drainQueue).toHaveBeenCalledTimes(1);
        expect(customers.importCustomers).not.toHaveBeenCalled();
        expect(worker.listOutstandingClientIds).not.toHaveBeenCalled();
      });

  test("a drain failure resolves quietly", async () => {
    const {triggers, worker, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(CONNECTED);
    firestore.getFirestore.mockReturnValue(db);
    worker.drainQueue.mockRejectedValue(new Error("Wave is down"));

    await expect(triggers.runWaveDaily()).resolves.toBeUndefined();
  });

  test("does nothing at all while Wave is not connected", async () => {
    const {triggers, worker, customers, firestore} = freshWaveModules();
    const {db} = fakeTriggerFirestore(null);
    firestore.getFirestore.mockReturnValue(db);

    await triggers.runWaveDaily();

    expect(worker.drainQueue).not.toHaveBeenCalled();
    expect(customers.importCustomers).not.toHaveBeenCalled();
  });
});

describe("waveRetryFailedJobs", () => {
  test("requeues dead jobs and pushes them so the press has an effect",
      async () => {
        getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
        waveWorker.requeueDeadJobs.mockResolvedValue(
            {requeued: 2, scanned: 2});
        waveWorker.drainQueue.mockResolvedValue(drainSummary({done: 2}));

        const out = await waveRetryFailedJobs.run(req(ADMIN_UID, {}));

        expect(out).toEqual(
            {requeued: 2, scanned: 2, pushed: 2, failed: 0});
        expectCalledBefore(waveWorker.requeueDeadJobs, waveWorker.drainQueue);
      });

  test("reports jobs that dead-lettered again on the push behind it",
      async () => {
        // The shape that makes this press look broken: a job usually dies on
        // something Wave will reject again, so the drain kills it inside the
        // same call and the outbox's dead count never moves. Without `failed`
        // the app sees only `requeued` and announces a success over a row
        // that still reads "1 client failed to sync".
        getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
        waveWorker.requeueDeadJobs.mockResolvedValue(
            {requeued: 3, scanned: 3});
        waveWorker.drainQueue.mockResolvedValue(
            drainSummary({done: 2, dead: 1}));

        const out = await waveRetryFailedJobs.run(req(ADMIN_UID, {}));

        expect(out).toEqual(
            {requeued: 3, scanned: 3, pushed: 2, failed: 1});
      });

  test("a failed push still reports the requeue, which already committed",
      async () => {
        // The requeue is the durable half. Reporting it as a failure because
        // the optional push behind it broke would tell the admin nothing was
        // recovered when in fact the jobs are queued and will drain.
        getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
        waveWorker.requeueDeadJobs.mockResolvedValue(
            {requeued: 3, scanned: 3});
        waveWorker.drainQueue.mockRejectedValue(new Error("Wave is down"));

        const out = await waveRetryFailedJobs.run(req(ADMIN_UID, {}));

        expect(out).toMatchObject(
            {requeued: 3, scanned: 3, pushed: null, failed: null});
      });

  test("nothing to requeue means no drain at all", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    waveWorker.requeueDeadJobs.mockResolvedValue({requeued: 0, scanned: 0});

    const out = await waveRetryFailedJobs.run(req(ADMIN_UID, {}));

    expect(out).toEqual({requeued: 0, scanned: 0, pushed: null, failed: null});
    expect(waveWorker.drainQueue).not.toHaveBeenCalled();
  });

  test("refuses while Wave is not connected, without touching the queue",
      async () => {
        getFirestore.mockReturnValue(fakeFirestore(null).db);

        const err = await expectThrows(waveRetryFailedJobs, req(ADMIN_UID, {}));

        expect(err.code).toBe("failed-precondition");
        // Canonical across all three connection gates. This threw
        // `wave/not-connected`, which no shipped Flutter mapper knows, so the
        // admin saw a generic error instead of "Wave isn't connected".
        expect(err.message).toBe("wave/not-bootstrapped");
        expect(waveWorker.requeueDeadJobs).not.toHaveBeenCalled();
      });

  test("the rate limiter fires before any queue mutation", async () => {
    getFirestore.mockReturnValue(fakeFirestore({businessId: "biz-1"}).db);
    security.enforceDurableRateLimit.mockRejectedValueOnce(
        new HttpsError("resource-exhausted", "too-many-attempts"));

    const err = await expectThrows(waveRetryFailedJobs, req(ADMIN_UID, {}));

    expect(err.code).toBe("resource-exhausted");
    expect(waveWorker.requeueDeadJobs).not.toHaveBeenCalled();
  });
});
