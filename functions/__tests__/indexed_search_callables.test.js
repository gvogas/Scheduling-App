"use strict";

/**
 * Handler tests for the three `indexed_search` CALLABLES.
 *
 * The two existing suites cover the pure helpers (`historyScope`,
 * `mayReadHistoryDoc`, the conflict overlap rule); nothing drove the handlers,
 * so the guard ORDER, the early returns, the read-cap warns and the
 * re-verification pass were all unexercised at 18% function coverage.
 *
 * Everything pure is the REAL module — `search_tokens`, `time_utils`,
 * `day_slice_utils`, `client_name_utils`, `requireNumberInRange`. Stubbing any
 * of those would turn "a token hit is a prefilter, never the answer" into a
 * test of the stub.
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
  const {HttpsError} = require("firebase-functions/v2/https");
  const mock = {
    APP_CHECK: {enforceAppCheck: true},
    optionalString: actual.optionalString,
    requireNumberInRange: actual.requireNumberInRange,
    shortHash: actual.shortHash,
    assertPayloadShape: jest.fn(),
    enforceDurableRateLimit: jest.fn(),
  };
  // Both composers are stubbed, because both are what the callables open with.
  mock.assertAdminCall = jest.fn(async (req, allowedKeys) => {
    if (!req.auth || !req.auth.uid) {
      throw new HttpsError("unauthenticated", "auth-required");
    }
    if (mock.profile.role !== "admin") {
      throw new HttpsError("permission-denied", "admin-required");
    }
    mock.assertPayloadShape(req.data, allowedKeys);
    return req.auth.uid;
  });
  mock.assertActiveCall = jest.fn(async (req, allowedKeys) => {
    if (!req.auth || !req.auth.uid) {
      throw new HttpsError("unauthenticated", "auth-required");
    }
    mock.assertPayloadShape(req.data, allowedKeys);
    return {...mock.profile, uid: req.auth.uid};
  });
  mock.profile = {role: "admin", docId: "e-admin"};
  return mock;
});

const {HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");
const security = require("../security");
const {
  searchClients,
  searchHistory,
  findAppointmentConflicts,
  serializeValue,
} = require("../indexed_search");

const UID = "caller-uid";

/**
 * A chainable Firestore query stub returning `docs`, recording constraints.
 * @param {!Array<!Object>} docs Documents each `.get()` resolves to.
 * @return {!Object} A db whose `calls` lists every constraint chain built.
 */
function dbReturning(docs) {
  const calls = [];
  const db = {
    calls,
    collection: jest.fn((name) => {
      const chain = {name, where: [], orderBy: null, limit: null};
      calls.push(chain);
      const q = {
        where: (f, op, v) => {
          chain.where.push([f, op, v]);
          return q;
        },
        orderBy: (f, d) => {
          chain.orderBy = [f, d];
          return q;
        },
        limit: (n) => {
          chain.limit = n;
          return q;
        },
        get: async () => ({docs: docs.map(makeDoc)}),
      };
      return q;
    }),
  };
  return db;
}

/**
 * @param {!Object} entry `{id, ...fields}`.
 * @return {!Object} A query document snapshot stub.
 */
function makeDoc(entry) {
  const {id, ...data} = entry;
  return {id, data: () => data};
}

/**
 * Invokes a callable and returns the HttpsError it threw.
 * @param {!Object} callable The onCall wrapper.
 * @param {!Object} request Callable request.
 * @return {!Promise<!Object>} The caught error.
 */
async function expectRejection(callable, request) {
  let caught = null;
  try {
    await callable.run(request);
  } catch (e) {
    caught = e;
  }
  expect(caught).toBeInstanceOf(HttpsError);
  return caught;
}

beforeEach(() => {
  jest.clearAllMocks();
  security.profile = {role: "admin", docId: "e-admin"};
});

describe("serializeValue", () => {
  test("a Firestore Timestamp becomes the Flutter millis shape", () => {
    expect(serializeValue({toMillis: () => 1234}))
        .toEqual({millisecondsSinceEpoch: 1234});
  });

  test("a Date becomes the same shape", () => {
    expect(serializeValue(new Date(99)))
        .toEqual({millisecondsSinceEpoch: 99});
  });

  test("null and undefined pass straight through", () => {
    expect(serializeValue(null)).toBeNull();
    expect(serializeValue(undefined)).toBeUndefined();
  });

  test("it recurses through arrays and nested maps", () => {
    expect(serializeValue({
      a: [new Date(1), {b: new Date(2)}],
      c: "plain",
      d: 7,
    })).toEqual({
      a: [{millisecondsSinceEpoch: 1}, {b: {millisecondsSinceEpoch: 2}}],
      c: "plain",
      d: 7,
    });
  });
});

describe("searchClients", () => {
  const req = (data = {}) =>
    ({auth: {uid: UID}, data: {query: "smith", ...data}});

  test("filters constrain the indexed search before its read cap", async () => {
    const db = dbReturning([]);
    getFirestore.mockReturnValue(db);
    await searchClients.run(req({archived: false, buildingKey: "street|city"}));
    expect(db.calls[0].where).toEqual(expect.arrayContaining([
      ["archived", "==", false], ["buildingKey", "==", "street|city"],
    ]));
    expect(db.calls[0].limit).toBe(200);
    await searchClients.run(req({archived: false, type: "commercial"}));
    expect(db.calls[1].where).toContainEqual(["type", "==", "commercial"]);
  });

  test.each([{archived: "false"}, {type: "unknown"},
    {type: "commercial", buildingKey: "x"}])(
      "invalid filter is refused before consuming the limiter: %p",
      async (filter) => {
        await expect(searchClients.run(req(filter)))
            .rejects.toThrow("invalid-client-filter");
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  test("a non-admin is refused — clients are PII", async () => {
    security.profile = {role: "employee", docId: "e1"};
    getFirestore.mockReturnValue(dbReturning([]));
    const e = await expectRejection(searchClients, req());
    expect(e.code).toBe("permission-denied");
  });

  test("an untokenizable query returns empty without reading or rate-limiting",
      async () => {
        const db = dbReturning([]);
        getFirestore.mockReturnValue(db);
        await expect(searchClients.run(req({query: "  "})))
            .resolves.toEqual({clients: []});
        expect(db.collection).not.toHaveBeenCalled();
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  test("it queries searchTokens ordered by name, capped at the read limit",
      async () => {
        const db = dbReturning([]);
        getFirestore.mockReturnValue(db);
        await searchClients.run(req());
        const chain = db.calls[0];
        expect(chain.name).toBe("clients");
        expect(chain.where[0][0]).toBe("searchTokens");
        expect(chain.where[0][1]).toBe("array-contains-any");
        expect(chain.orderBy).toEqual(["name"]);
        expect(chain.limit).toBe(200);
      });

  test("a token hit is a PREFILTER — non-matching documents are dropped",
      async () => {
        getFirestore.mockReturnValue(dbReturning([
          {id: "c1", name: "Smith", firstName: "Ada", lastName: "Smith"},
          {id: "c2", name: "Zzzz", firstName: "Bob", lastName: "Jones"},
        ]));
        const out = await searchClients.run(req({query: "smith"}));
        expect(out.clients.map((c) => c.id)).toEqual(["c1"]);
      });

  test("results come back sorted by display name", async () => {
    getFirestore.mockReturnValue(dbReturning([
      {id: "c2", name: "Smith", firstName: "Zoe", lastName: "Smith"},
      {id: "c1", name: "Smith", firstName: "Ada", lastName: "Smith"},
    ]));
    const out = await searchClients.run(req({query: "smith"}));
    expect(out.clients.map((c) => c.id)).toEqual(["c1", "c2"]);
  });

  test("the answer is capped at 25 even when more match", async () => {
    const many = Array.from({length: 40}, (_, i) => ({
      id: `c${i}`,
      name: "Smith",
      firstName: `N${String(i).padStart(2, "0")}`,
      lastName: "Smith",
    }));
    getFirestore.mockReturnValue(dbReturning(many));
    const out = await searchClients.run(req({query: "smith"}));
    expect(out.clients).toHaveLength(25);
  });

  test("hitting the read cap WARNS — the truncation must not be silent",
      async () => {
        const many = Array.from({length: 200}, (_, i) => ({
          id: `c${i}`, name: "Smith", firstName: "A", lastName: "Smith",
        }));
        getFirestore.mockReturnValue(dbReturning(many));
        await searchClients.run(req({query: "smith"}));
        expect(logger.warn).toHaveBeenCalledWith(
            "searchClients: read cap hit", expect.any(Object));
        const [, payload] = logger.warn.mock.calls[0];
        expect(JSON.stringify(payload)).not.toContain(UID);
      });

  test("a short result set does not warn", async () => {
    getFirestore.mockReturnValue(dbReturning([
      {id: "c1", name: "Smith", firstName: "Ada", lastName: "Smith"},
    ]));
    await searchClients.run(req({query: "smith"}));
    expect(logger.warn).not.toHaveBeenCalled();
  });
});

describe("searchHistory", () => {
  const req = (data = {}) =>
    ({auth: {uid: UID}, data: {query: "smith", ...data}});

  test("an untokenizable query returns empty without reading", async () => {
    const db = dbReturning([]);
    getFirestore.mockReturnValue(db);
    await expect(searchHistory.run(req({query: ""})))
        .resolves.toEqual({appointments: []});
    expect(db.collection).not.toHaveBeenCalled();
    expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
  });

  test("an admin's tokens are scoped `all:` and the status filter is the " +
      "three terminal values", async () => {
    const db = dbReturning([]);
    getFirestore.mockReturnValue(db);
    await searchHistory.run(req());
    const chain = db.calls[0];
    expect(chain.name).toBe("appointments");
    expect(chain.where[0][0]).toBe("historySearchScopes");
    expect(chain.where[0][2].every((t) => t.startsWith("all:"))).toBe(true);
    expect(chain.where[1]).toEqual([
      "status", "in", ["done", "completed", "cancelled"],
    ]);
    expect(chain.orderBy).toEqual(["startTime", "desc"]);
  });

  test("a technician's tokens are pinned to their own scope", async () => {
    security.profile = {role: "employee", docId: "e1"};
    const db = dbReturning([]);
    getFirestore.mockReturnValue(db);
    await searchHistory.run(req());
    expect(db.calls[0].where[0][2].every((t) => t.startsWith("emp:e1:")))
        .toBe(true);
  });

  test("a technician asking for somebody else is refused", async () => {
    security.profile = {role: "employee", docId: "e1"};
    getFirestore.mockReturnValue(dbReturning([]));
    const e = await expectRejection(searchHistory, req({employeeId: "e2"}));
    expect(e.code).toBe("permission-denied");
  });

  test("a returned doc is re-verified against employeeIds, not just tokens",
      async () => {
        security.profile = {role: "employee", docId: "e1"};
        getFirestore.mockReturnValue(dbReturning([
          {id: "a1", clientName: "Smith", employeeIds: ["e1"]},
          // Scope tokens drifted from employeeIds: rules would refuse this.
          {id: "a2", clientName: "Smith", employeeIds: ["e9"]},
        ]));
        const out = await searchHistory.run(req({query: "smith"}));
        expect(out.appointments.map((a) => a.id)).toEqual(["a1"]);
      });

  test("hitting the read cap warns", async () => {
    const many = Array.from({length: 200}, (_, i) => ({
      id: `a${i}`, clientName: "Smith", employeeIds: ["e-admin"],
    }));
    getFirestore.mockReturnValue(dbReturning(many));
    await searchHistory.run(req({query: "smith"}));
    expect(logger.warn).toHaveBeenCalledWith(
        "searchHistory: read cap hit", expect.any(Object));
  });
});

describe("findAppointmentConflicts", () => {
  const DAY = Date.UTC(2026, 4, 12);
  const base = {
    employeeIds: ["e1"],
    startMillis: DAY + 9 * 3600_000,
    endMillis: DAY + 17 * 3600_000,
  };
  const req = (data = {}) => ({auth: {uid: UID}, data: {...base, ...data}});

  test("an end at or before the start is refused", async () => {
    getFirestore.mockReturnValue(dbReturning([]));
    for (const endMillis of [base.startMillis, base.startMillis - 1]) {
      const e = await expectRejection(findAppointmentConflicts,
          req({endMillis}));
      expect(e.message).toMatch(/invalid-endMillis/);
    }
  });

  test("an out-of-range or non-numeric instant is refused", async () => {
    getFirestore.mockReturnValue(dbReturning([]));
    expect((await expectRejection(findAppointmentConflicts,
        req({startMillis: 0}))).code).toBe("invalid-argument");
    expect((await expectRejection(findAppointmentConflicts,
        req({startMillis: "nope"}))).code).toBe("invalid-argument");
  });

  test("a malformed employeeIds payload is refused", async () => {
    getFirestore.mockReturnValue(dbReturning([]));
    const bad = [
      "e1", // not an array
      [""], // empty after trim
      ["  "],
      ["a/b"], // a path, not an id
      ["x".repeat(129)], // over the doc-id cap
      Array.from({length: 501}, () => "e1"), // over the roster cap
    ];
    for (const employeeIds of bad) {
      const e = await expectRejection(findAppointmentConflicts,
          req({employeeIds}));
      expect(e.message).toMatch(/invalid-employeeIds/);
    }
  });

  test("a non-string id is COERCED, not rejected — it simply matches nothing",
      async () => {
        const db = dbReturning([]);
        getFirestore.mockReturnValue(db);
        await findAppointmentConflicts.run(req({employeeIds: [{}, 7]}));
        expect(db.calls[0].where[0][2]).toEqual(["[object Object]", "7"]);
      });

  test("an empty roster returns empty without reading or rate-limiting",
      async () => {
        const db = dbReturning([]);
        getFirestore.mockReturnValue(db);
        await expect(findAppointmentConflicts.run(req({employeeIds: []})))
            .resolves.toEqual({appointments: []});
        expect(db.collection).not.toHaveBeenCalled();
        expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
      });

  test("duplicate ids are collapsed", async () => {
    const db = dbReturning([]);
    getFirestore.mockReturnValue(db);
    await findAppointmentConflicts.run(req({employeeIds: ["e1", "e1", "e2"]}));
    expect(db.calls[0].where[0][2]).toEqual(["e1", "e2"]);
  });

  test("a non-admin asking about anyone else is refused", async () => {
    security.profile = {role: "employee", docId: "e1"};
    getFirestore.mockReturnValue(dbReturning([]));
    const e = await expectRejection(findAppointmentConflicts,
        req({employeeIds: ["e1", "e2"]}));
    expect(e.code).toBe("permission-denied");
  });

  test("a non-admin is narrowed to their own doc id", async () => {
    security.profile = {role: "employee", docId: "e1"};
    const db = dbReturning([]);
    getFirestore.mockReturnValue(db);
    await findAppointmentConflicts.run(req({employeeIds: ["e1"]}));
    expect(db.calls[0].where[0][2]).toEqual(["e1"]);
  });

  test("more than 30 ids are chunked, since array-contains-any caps at 30",
      async () => {
        const ids = Array.from({length: 65}, (_, i) => `e${i}`);
        const db = dbReturning([]);
        getFirestore.mockReturnValue(db);
        await findAppointmentConflicts.run(req({employeeIds: ids}));
        expect(db.calls).toHaveLength(3);
        expect(db.calls[0].where[0][2]).toHaveLength(30);
        expect(db.calls[2].where[0][2]).toHaveLength(5);
      });

  test("the appointment being edited is excluded", async () => {
    getFirestore.mockReturnValue(dbReturning([{
      id: "a1",
      status: "pending",
      startTime: new Date(base.startMillis),
      endTime: new Date(base.endMillis),
    }]));
    const out = await findAppointmentConflicts.run(
        req({excludeAppointmentId: "a1"}));
    expect(out.appointments).toEqual([]);
  });

  test("a terminal appointment never clashes", async () => {
    getFirestore.mockReturnValue(dbReturning([{
      id: "a1",
      status: "done",
      startTime: new Date(base.startMillis),
      endTime: new Date(base.endMillis),
    }]));
    const out = await findAppointmentConflicts.run(req());
    expect(out.appointments).toEqual([]);
  });

  test("clientJobsOnly drops personal blocks", async () => {
    const stored = [{
      id: "a1",
      status: "pending",
      isPersonal: true,
      startTime: new Date(base.startMillis),
      endTime: new Date(base.endMillis),
    }];
    getFirestore.mockReturnValue(dbReturning(stored));
    expect((await findAppointmentConflicts.run(req({clientJobsOnly: true})))
        .appointments).toEqual([]);
    getFirestore.mockReturnValue(dbReturning(stored));
    expect((await findAppointmentConflicts.run(req({clientJobsOnly: false})))
        .appointments).toHaveLength(1);
  });

  test("an overlapping live appointment IS returned, serialized", async () => {
    getFirestore.mockReturnValue(dbReturning([{
      id: "a1",
      status: "pending",
      startTime: new Date(base.startMillis),
      endTime: new Date(base.endMillis),
    }]));
    const out = await findAppointmentConflicts.run(req());
    expect(out.appointments).toHaveLength(1);
    expect(out.appointments[0].data.startTime)
        .toEqual({millisecondsSinceEpoch: base.startMillis});
  });

  test("a row whose stored times do not parse clashes UNCONDITIONALLY — " +
      "fail closed", async () => {
    getFirestore.mockReturnValue(dbReturning([
      {id: "a1", status: "pending", startTime: null, endTime: null},
    ]));
    const out = await findAppointmentConflicts.run(req());
    expect(out.appointments.map((a) => a.id)).toEqual(["a1"]);
  });

  test("hitting the read cap warns", async () => {
    const many = Array.from({length: 500}, (_, i) => ({
      id: `a${i}`,
      status: "pending",
      startTime: new Date(base.startMillis),
      endTime: new Date(base.endMillis),
    }));
    getFirestore.mockReturnValue(dbReturning(many));
    await findAppointmentConflicts.run(req());
    expect(logger.warn).toHaveBeenCalledWith(
        "findAppointmentConflicts: read cap hit", expect.any(Object));
  });
});
