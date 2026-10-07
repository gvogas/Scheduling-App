"use strict";

const {
  WaveValidationError,
  upsertCustomer,
  importCustomers,
  sanitizeInputErrors,
} = require("../wave/customers");
const {WaveApiError} = require("../wave/client");
const {mappedFieldsHash, fromWaveCustomer} = require("../wave/mappers");

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

// Stable serverTimestamp sentinel so writes are assertable.
const TS = {__serverTimestamp: true};
const now = () => TS;

/**
 * Fake client document snapshot.
 * @param {Object|null} data Document data, or null for a missing doc.
 * @return {!Object}
 */
function snap(data) {
  return {
    exists: data !== null,
    data: () => data,
  };
}

/**
 * Fake `clients/{id}` doc ref that records update() calls and serves
 * `freshData` (or `data` if unset) as the write-back re-read snapshot.
 * @param {Object|null} data Initial snapshot data.
 * @param {Object=} freshData Snapshot data for the write-back re-read.
 * @return {!Object}
 */
function clientRef(data, freshData) {
  const ref = {
    updates: [],
    _data: data,
    _fresh: freshData !== undefined ? freshData : data,
    get: jest.fn(() => Promise.resolve(snap(ref._data))),
  };
  // The transaction re-reads via tx.get(ref) — serve the fresh snapshot.
  ref._txGet = () => Promise.resolve(snap(ref._fresh));
  return ref;
}

/**
 * Minimal fake Firestore for upsert: a single clients/{id} ref + a
 * wave/connection doc, plus runTransaction.
 * @param {!Object} ref The clients doc ref from clientRef().
 * @param {Object=} opts Connection doc options (`businessId`).
 * @return {!Object}
 */
function upsertDb(ref, opts = {}) {
  const connectionData = opts.businessId !== undefined ?
    {businessId: opts.businessId} : {businessId: "biz-1"};
  return {
    collection: (name) => ({
      doc: (id) => {
        if (name === "clients") return ref;
        if (name === "wave" && id === "connection") {
          return {get: () => Promise.resolve(snap(connectionData))};
        }
        throw new Error(`unexpected doc ${name}/${id}`);
      },
    }),
    runTransaction: async (fn) => {
      const tx = {
        get: (r) => r._txGet(),
        update: (r, u) => r.updates.push(u),
        set: (r, u) => r.updates.push(u),
      };
      return fn(tx);
    },
  };
}

/** A representative full client doc (mapped fields). */
const CLIENT = {
  name: "Acme Corp",
  firstName: "Jane",
  lastName: "Doe",
  email: "jane@acme.com",
  phone: "514-555-1234",
  mobile: "514-555-9876",
  address: "3450 Main St",
  apt: "12",
  city: "Montreal",
  province: "QC",
  country: "Canada",
  postalCode: "H3Z 2Y7",
};

/**
 * Builds a graphql mock that returns each response in sequence and records the
 * mutation + variables of every call.
 * @param {...*} results Values to resolve in order (or Errors to reject).
 * @return {!Function} The mock graphql.
 */
function graphqlSeq(...results) {
  let i = 0;
  const fn = jest.fn((_query, _variables) => {
    const r = results[Math.min(i, results.length - 1)];
    i++;
    if (r instanceof Error) return Promise.reject(r);
    return Promise.resolve(r);
  });
  return fn;
}

// graphql `data` envelope builders for customerCreate / customerPatch.
const createOk = (id) => ({
  customerCreate: {
    didSucceed: true,
    inputErrors: [],
    customer: {id, name: "Acme Corp"},
  },
});

const createFail = (inputErrors) => ({
  customerCreate: {didSucceed: false, inputErrors, customer: null},
});

const patchOk = (id) => ({
  customerPatch: {
    didSucceed: true,
    inputErrors: [],
    customer: {id, name: "Acme Corp"},
  },
});

const patchFail = (inputErrors) => ({
  customerPatch: {didSucceed: false, inputErrors, customer: null},
});

// ---------------------------------------------------------------------------
// upsertCustomer — no-op
// ---------------------------------------------------------------------------

describe("upsertCustomer no-op", () => {
  test("linked + unchanged hash → noop, graphql not called", async () => {
    const hash = mappedFieldsHash(CLIENT);
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "synced", lastSyncedHash: hash},
    };
    const ref = clientRef(data);
    const graphql = jest.fn();
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });
    expect(result).toEqual({status: "noop"});
    expect(graphql).not.toHaveBeenCalled();
    expect(ref.updates).toHaveLength(0);
  });

  test("stale 'pending' is healed to 'synced' on a no-op", async () => {
    // How a doc gets here: an edit marks it pending and enqueues, a second
    // edit puts the mapped fields BACK, and shouldEnqueueClientWrite's rule 2
    // skips that write — so the job the first edit left behind arrives with
    // nothing to push. Nothing else clears the flag, and the client detail
    // badge reads it, so the row would say "Sync pending" forever.
    const hash = mappedFieldsHash(CLIENT);
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "pending", lastSyncedHash: hash},
    };
    const ref = clientRef(data);
    const graphql = jest.fn();
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "noop"});
    expect(graphql).not.toHaveBeenCalled();
    expect(ref.updates).toEqual([
      {"wave.syncState": "synced", "wave.syncError": null},
    ]);
    // Nothing reached Wave just now, so the stamp must keep naming the last
    // real push.
    expect(ref.updates[0]).not.toHaveProperty("wave.lastSyncedAt");
  });

  test("a stale 'error' is healed too", async () => {
    const hash = mappedFieldsHash(CLIENT);
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "error", syncError: "boom", lastSyncedHash: hash},
    };
    const ref = clientRef(data);
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql: jest.fn(), businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "noop"});
    expect(ref.updates).toEqual([
      {"wave.syncState": "synced", "wave.syncError": null},
    ]);
  });

  test("an edit landing during the no-op is NOT marked synced", async () => {
    // The heal re-reads inside the transaction precisely for this: marking it
    // synced here would put "Synced with Wave" on a client whose change is
    // still sitting in the outbox — the exact lie the heal exists to remove.
    const hash = mappedFieldsHash(CLIENT);
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "pending", lastSyncedHash: hash},
    };
    const fresh = {
      ...data,
      name: "Acme Corp Renamed",
    };
    const ref = clientRef(data, fresh);
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql: jest.fn(), businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "noop"});
    expect(ref.updates).toHaveLength(0);
  });

  test("a doc with no lastSyncedHash is left alone", async () => {
    // Nothing has demonstrably reached Wave, so there is no evidence the
    // pending flag is stale — healing here would claim a push that never
    // happened. Only reachable on a doc linked out-of-band.
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "pending"},
    };
    const ref = clientRef(data);
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql: graphqlSeq(patchOk("wave-1")),
      businessId: "biz-1", now,
    });

    // No hash to match, so this is a real patch rather than a no-op — and the
    // heal never runs.
    expect(result).toEqual({status: "patched", waveCustomerId: "wave-1"});
    expect(ref.updates).not.toContainEqual(
        {"wave.syncState": "synced", "wave.syncError": null},
    );
  });

  test("a doc deleted during the no-op is not resurrected", async () => {
    const hash = mappedFieldsHash(CLIENT);
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "pending", lastSyncedHash: hash},
    };
    const ref = clientRef(data, null);
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql: jest.fn(), businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "noop"});
    expect(ref.updates).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// upsertCustomer — patch
// ---------------------------------------------------------------------------

describe("upsertCustomer contract refusal", () => {
  test("a refused client is BLOCKED, never sent, and never dead-lettered",
      async () => {
        // Last line of defence. The enqueue gate refuses first, but a job
        // queued before the edit — or claimed `inflight` when the edit landed
        // — still arrives here holding a client Wave would refuse. Throwing
        // WaveValidationError would dead-letter it permanently, which is the
        // outcome this whole project exists to remove.
        const ref = clientRef({...CLIENT, name: "", firstName: "",
          lastName: "", type: "business"});
        const graphql = jest.fn();

        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        });

        expect(result.status).toBe("blocked");
        expect(result.problems).toEqual([
          {field: "name", code: "EMPTY", severity: "blocking", detail: null},
        ]);
        expect(graphql).not.toHaveBeenCalled();
        expect(ref.updates).toHaveLength(1);
        expect(ref.updates[0]["wave.syncState"]).toBe("blocked");
      });

  test("an ADVISORY problem still reaches Wave", async () => {
    // Wave accepts it; refusing here would strand a client that syncs fine.
    const ref = clientRef({...CLIENT, phone: "Contact Person"});
    const graphql = graphqlSeq(createOk("wave-9"));

    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result.status).toBe("created");
    expect(graphql).toHaveBeenCalled();
    expect(ref.updates[0]["wave.syncState"]).toBe("synced");
  });
});

describe("upsertCustomer patch", () => {
  test("linked + changed field → patch with id, no businessId", async () => {
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-1",
      wave: {syncState: "synced", lastSyncedHash: "stale-hash"},
    };
    const ref = clientRef(data);
    const graphql = graphqlSeq(patchOk("wave-1"));
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "patched", waveCustomerId: "wave-1"});
    expect(graphql).toHaveBeenCalledTimes(1);
    const [, vars] = graphql.mock.calls[0];
    expect(vars.input.id).toBe("wave-1");
    expect(vars.input).not.toHaveProperty("businessId");
    // Write-back sets synced state + hash, leaves the link untouched.
    expect(ref.updates).toHaveLength(1);
    const u = ref.updates[0];
    expect(u["wave.syncState"]).toBe("synced");
    expect(u["wave.lastSyncedHash"]).toBe(mappedFieldsHash(CLIENT));
    expect(u["wave.syncError"]).toBeNull();
    expect(u).not.toHaveProperty("waveCustomerId");
  });
});

// ---------------------------------------------------------------------------
// upsertCustomer — the linked customer is GONE from Wave
// ---------------------------------------------------------------------------

// Observed in prod 2026-08-15: two clients whose `waveCustomerId` pointed at a
// deleted Wave customer. `customerPatch` answers NOT_FOUND, which the retry
// taxonomy calls non-retryable, so the job dead-lettered — and because the
// offending id is STORED, every later push and every "Retry failed" press
// re-sent it and failed identically. Permanently unsyncable, with the Settings
// row reading "2 clients failed to sync" forever.
describe("upsertCustomer stale link", () => {
  const notFoundThrow = () => new WaveApiError(
      "graphql", "Wave GraphQL errors: not found",
      [{message: "not found", extensions: {code: "NOT_FOUND"}}],
  );

  const listOnePage = (nodes) => ({
    business: {
      customers: {
        pageInfo: {currentPage: 1, totalPages: 1, totalCount: nodes.length},
        edges: nodes.map((node) => ({node})),
      },
    },
  });

  test("a NOT_FOUND patch relinks to the identity match, never duplicates",
      async () => {
        const data = {
          ...CLIENT,
          waveCustomerId: "wave-gone",
          wave: {syncState: "error", lastSyncedHash: "stale-hash"},
        };
        const ref = clientRef(data);
        const graphql = graphqlSeq(
            notFoundThrow(),
            listOnePage([{
              id: "wave-real",
              name: "Acme Corp",
              email: "jane@acme.com",
              isArchived: false,
            }]),
            patchOk("wave-real"),
        );

        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        });

        expect(result).toEqual({status: "linked", waveCustomerId: "wave-real"});
        // The identity search is what stops a spurious NOT_FOUND minting a
        // second customer for a client that already has one.
        expect(ref.updates[0].waveCustomerId).toBe("wave-real");
      });

  test("no identity match → creates and REPLACES the dead link", async () => {
    // The write-back guard exists to keep a create from stomping an existing
    // link. A link we have just proved dead is the one case that must win, or
    // the doc keeps the missing id and the next push fails the same way.
    const data = {
      ...CLIENT,
      waveCustomerId: "wave-gone",
      wave: {syncState: "error", lastSyncedHash: "stale-hash"},
    };
    const ref = clientRef(data);
    const graphql = graphqlSeq(
        notFoundThrow(), listOnePage([]), createOk("wave-new"),
    );

    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
    expect(ref.updates[0].waveCustomerId).toBe("wave-new");
    expect(ref.updates[0]["wave.syncState"]).toBe("synced");
  });

  test("a link changed concurrently is left alone, not replaced", async () => {
    // Only the id we PROVED dead may be overwritten. Another writer's link is
    // newer and unproven, so it wins.
    const data = {...CLIENT, waveCustomerId: "wave-gone"};
    const fresh = {...CLIENT, waveCustomerId: "wave-concurrent"};
    const ref = clientRef(data, fresh);
    const graphql = graphqlSeq(
        notFoundThrow(), listOnePage([]), createOk("wave-new"),
    );

    await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(ref.updates[0]).not.toHaveProperty("waveCustomerId");
  });

  test("the same verdict from an inputError takes the same route", async () => {
    // Which shape Wave reports it in is Wave's choice; missing one leaves the
    // client just as stuck.
    const data = {...CLIENT, waveCustomerId: "wave-gone"};
    const ref = clientRef(data);
    const graphql = graphqlSeq(
        patchFail([{code: "NOT_FOUND", message: "gone", path: ["id"]}]),
        listOnePage([]),
        createOk("wave-new"),
    );

    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
    expect(ref.updates[0].waveCustomerId).toBe("wave-new");
  });

  test("an ordinary rejection still dead-letters — no unlink", async () => {
    // The heal must stay narrow: it rewrites a client's Wave link, so anything
    // short of a proved-missing customer keeps the old, correct behaviour.
    const data = {...CLIENT, waveCustomerId: "wave-1"};
    const ref = clientRef(data);
    const graphql = graphqlSeq(
        patchFail([{code: "INVALID_EMAIL", message: "bad", path: ["email"]}]),
    );

    await expect(upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    })).rejects.toBeInstanceOf(WaveValidationError);
    expect(graphql).toHaveBeenCalledTimes(1);
    expect(ref.updates[0]["wave.syncState"]).toBe("error");
  });

  test("a transport error is rethrown untouched, never read as a dead link",
      async () => {
        const data = {...CLIENT, waveCustomerId: "wave-1"};
        const ref = clientRef(data);
        const graphql = graphqlSeq(
            new WaveApiError("network", "socket hang up"),
        );

        await expect(upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        })).rejects.toBeInstanceOf(WaveApiError);
        expect(graphql).toHaveBeenCalledTimes(1);
      });
});

// ---------------------------------------------------------------------------
// upsertCustomer — create
// ---------------------------------------------------------------------------

describe("upsertCustomer create", () => {
  test("unlinked → create, write-back sets id + synced + hash", async () => {
    const data = {...CLIENT}; // no waveCustomerId
    const ref = clientRef(data);
    const graphql = graphqlSeq(createOk("wave-new"));
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
    const [, vars] = graphql.mock.calls[0];
    expect(vars.input.businessId).toBe("biz-1");
    expect(ref.updates).toHaveLength(1);
    const u = ref.updates[0];
    expect(u.waveCustomerId).toBe("wave-new");
    expect(u["wave.syncState"]).toBe("synced");
    expect(u["wave.lastSyncedHash"]).toBe(mappedFieldsHash(CLIENT));
    expect(u["wave.lastSyncedAt"]).toBe(TS);
  });

  test("write-back guard: existing id not overwritten on create", async () => {
    const data = {...CLIENT};
    // By write-back time, a concurrent create already linked the doc.
    const fresh = {...CLIENT, waveCustomerId: "wave-concurrent"};
    const ref = clientRef(data, fresh);
    const graphql = graphqlSeq(createOk("wave-mine"));
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "created", waveCustomerId: "wave-mine"});
    const u = ref.updates[0];
    // Guard keeps the existing link, never overwrites it.
    expect(u).not.toHaveProperty("waveCustomerId");
    expect(u["wave.syncState"]).toBe("synced");
  });

  test("businessId read from wave/connection when not injected", async () => {
    const data = {...CLIENT};
    const ref = clientRef(data);
    const graphql = graphqlSeq(createOk("wave-new"));
    await upsertCustomer("c1", {
      db: upsertDb(ref, {businessId: "biz-from-doc"}), graphql, now,
    });
    const [, vars] = graphql.mock.calls[0];
    expect(vars.input.businessId).toBe("biz-from-doc");
  });

  test("write-back no-ops when doc deleted before txn (exists:false)",
      async () => {
        const data = {...CLIENT};
        // The write-back re-read returns a missing snapshot.
        const ref = clientRef(data, null);
        const graphql = graphqlSeq(createOk("wave-new"));
        // Should complete without throwing even though the doc is gone.
        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        });
        expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
        // Guard skipped the update — no writes recorded.
        expect(ref.updates).toHaveLength(0);
      });
});

// ---------------------------------------------------------------------------
// upsertCustomer — validation failure
// ---------------------------------------------------------------------------

describe("upsertCustomer validation failure", () => {
  test("non-phone didSucceed:false → error state, throws, no retry",
      async () => {
        const data = {...CLIENT};
        const ref = clientRef(data);
        const inputErrors = [
          {code: "INVALID_EMAIL", message: "raw wave msg", path: ["email"]},
        ];
        const graphql = graphqlSeq(createFail(inputErrors));
        await expect(upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        })).rejects.toBeInstanceOf(WaveValidationError);

        // No retry: exactly one graphql call.
        expect(graphql).toHaveBeenCalledTimes(1);
        const u = ref.updates[0];
        expect(u["wave.syncState"]).toBe("error");
        // Sanitized — never Wave's raw message.
        expect(u["wave.syncError"]).not.toContain("raw wave msg");
        expect(u["wave.syncError"]).toContain("email");
      });

  test("WaveValidationError carries inputErrors and retryable=false",
      async () => {
        const data = {...CLIENT};
        const ref = clientRef(data);
        const inputErrors = [{code: "MISSING_REQUIRED", path: ["name"]}];
        const graphql = graphqlSeq(createFail(inputErrors));
        let caught;
        try {
          await upsertCustomer("c1", {
            db: upsertDb(ref), graphql, businessId: "biz-1", now,
          });
        } catch (e) {
          caught = e;
        }
        expect(caught).toBeInstanceOf(WaveValidationError);
        expect(caught.retryable).toBe(false);
        expect(caught.inputErrors).toEqual(inputErrors);
      });
});

// ---------------------------------------------------------------------------
// upsertCustomer — phone/mobile create fallback
// ---------------------------------------------------------------------------

describe("upsertCustomer phone/mobile create fallback", () => {
  test("phone-rejected create → retry without phone, then patch, synced",
      async () => {
        const data = {...CLIENT};
        const ref = clientRef(data);
        const phoneErrors = [
          {code: "GENERIC_ERROR", message: "bad", path: ["phone"]},
          {code: "GENERIC_ERROR", message: "bad", path: ["mobile"]},
        ];
        // Create with phone fails, then create without phone succeeds, then
        // patches the phone onto the new id.
        const graphql = graphqlSeq(
            createFail(phoneErrors),
            createOk("wave-new"),
            patchOk("wave-new"),
        );
        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        });

        expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
        expect(graphql).toHaveBeenCalledTimes(3);

        // Call 1: create WITH phone/mobile.
        expect(graphql.mock.calls[0][1].input).toHaveProperty("phone");
        // Call 2: create WITHOUT phone/mobile.
        const retryInput = graphql.mock.calls[1][1].input;
        expect(retryInput).not.toHaveProperty("phone");
        expect(retryInput).not.toHaveProperty("mobile");
        expect(retryInput.businessId).toBe("biz-1");
        // Call 3: patch phone/mobile onto the new id.
        const patchInput = graphql.mock.calls[2][1].input;
        expect(patchInput.id).toBe("wave-new");
        expect(patchInput.phone).toBe(CLIENT.phone);
        expect(patchInput.mobile).toBe(CLIENT.mobile);

        // Final state synced.
        const u = ref.updates[0];
        expect(u["wave.syncState"]).toBe("synced");
        expect(u.waveCustomerId).toBe("wave-new");
      });

  test("phone patch fails → synced hash excludes phone (retries later)",
      async () => {
        const data = {...CLIENT};
        const ref = clientRef(data);
        const phoneErrors = [
          {code: "GENERIC_ERROR", message: "bad", path: ["phone"]},
        ];
        // create-with-phone fails, create-without-phone OK, phone patch FAILS.
        const graphql = graphqlSeq(
            createFail(phoneErrors),
            createOk("wave-new"),
            patchFail(phoneErrors),
        );
        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        });

        expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
        const u = ref.updates[0];
        // The customer ends up linked and synced, but the recorded hash
        // reflects what actually reached Wave — without the phone. That way
        // a later upsert notices the difference and retries the phone
        // instead of treating it as done forever.
        expect(u["wave.syncState"]).toBe("synced");
        expect(u["wave.lastSyncedHash"]).toBe(
            mappedFieldsHash({...CLIENT, phone: "", mobile: ""}),
        );
        expect(u["wave.lastSyncedHash"]).not.toBe(mappedFieldsHash(CLIENT));
      });

  test("mixed errors (phone + email) → not treated as phone fallback",
      async () => {
        const data = {...CLIENT};
        const ref = clientRef(data);
        const mixed = [
          {code: "GENERIC_ERROR", path: ["phone"]},
          {code: "INVALID_EMAIL", path: ["email"]},
        ];
        const graphql = graphqlSeq(createFail(mixed));
        await expect(upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
        })).rejects.toBeInstanceOf(WaveValidationError);
        // No retry — a non-phone error is present.
        expect(graphql).toHaveBeenCalledTimes(1);
      });
});

// ---------------------------------------------------------------------------
// upsertCustomer — crash-retry create idempotency (F2)
// ---------------------------------------------------------------------------

describe("upsertCustomer crash-retry create idempotency", () => {
  // A Wave list page whose node matches CLIENT's identity (name + email).
  const matchingNode = {
    id: "wave-existing",
    name: "Acme Corp",
    firstName: "Jane",
    lastName: "Doe",
    email: "jane@acme.com",
    phone: "",
    mobile: "",
    isArchived: false,
    address: null,
  };

  const listPage1 = (nodes) => ({
    business: {
      customers: {
        pageInfo: {currentPage: 1, totalPages: 1, totalCount: nodes.length},
        edges: nodes.map((node) => ({node})),
      },
    },
  });

  test("priorAttempts > 0 + matching Wave customer → linked (patched), " +
    "NO duplicate create", async () => {
    const data = {...CLIENT}; // unlinked
    const ref = clientRef(data);
    // LIST_CUSTOMERS returns the match, then patches it with current fields.
    const graphql = graphqlSeq(
        listPage1([matchingNode]),
        patchOk("wave-existing"),
    );
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
      priorAttempts: 1,
    });

    expect(result).toEqual({status: "linked", waveCustomerId: "wave-existing"});
    expect(graphql).toHaveBeenCalledTimes(2);
    // First call is the list query (has page vars, no input).
    expect(graphql.mock.calls[0][1]).toEqual(
        expect.objectContaining({id: "biz-1", page: 1}));
    // Second call patches the FOUND id with the doc's current fields.
    const patchInput = graphql.mock.calls[1][1].input;
    expect(patchInput.id).toBe("wave-existing");
    expect(patchInput.name).toBe("Acme Corp");
    expect(patchInput).not.toHaveProperty("businessId");
    // Write-back links the found customer.
    const u = ref.updates[0];
    expect(u.waveCustomerId).toBe("wave-existing");
    expect(u["wave.syncState"]).toBe("synced");
  });

  test("priorAttempts > 0 but no match → create proceeds normally",
      async () => {
        const data = {...CLIENT};
        const ref = clientRef(data);
        const graphql = graphqlSeq(
            listPage1([{...matchingNode, email: "someone-else@x.com"}]),
            createOk("wave-new"),
        );
        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
          priorAttempts: 2,
        });

        expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
        // Call 2 is the create (carries businessId).
        expect(graphql.mock.calls[1][1].input.businessId).toBe("biz-1");
      });

  test("archived match is ignored (not linked)", async () => {
    const data = {...CLIENT};
    const ref = clientRef(data);
    const graphql = graphqlSeq(
        listPage1([{...matchingNode, isArchived: true}]),
        createOk("wave-new"),
    );
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
      priorAttempts: 1,
    });
    expect(result.status).toBe("created");
  });

  test("first attempt (priorAttempts 0/absent) → NO Wave search before " +
    "create", async () => {
    const data = {...CLIENT};
    const ref = clientRef(data);
    const graphql = graphqlSeq(createOk("wave-new"));
    const result = await upsertCustomer("c1", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });

    expect(result).toEqual({status: "created", waveCustomerId: "wave-new"});
    expect(graphql).toHaveBeenCalledTimes(1);
    // The single call is the create, not a list.
    expect(graphql.mock.calls[0][1].input.businessId).toBe("biz-1");
  });

  test("retry of a LINKED doc is unaffected (patch path, no search)",
      async () => {
        const data = {
          ...CLIENT,
          waveCustomerId: "wave-1",
          wave: {syncState: "synced", lastSyncedHash: "stale"},
        };
        const ref = clientRef(data);
        const graphql = graphqlSeq(patchOk("wave-1"));
        const result = await upsertCustomer("c1", {
          db: upsertDb(ref), graphql, businessId: "biz-1", now,
          priorAttempts: 3,
        });
        expect(result).toEqual({status: "patched", waveCustomerId: "wave-1"});
        expect(graphql).toHaveBeenCalledTimes(1);
      });
});

// ---------------------------------------------------------------------------
// upsertCustomer — transport error propagation
// ---------------------------------------------------------------------------

describe("upsertCustomer transport errors", () => {
  test("WaveApiError(network) propagates unchanged", async () => {
    const data = {...CLIENT};
    const ref = clientRef(data);
    const transport = new WaveApiError("network", "boom");
    const graphql = graphqlSeq(transport);
    let caught;
    try {
      await upsertCustomer("c1", {
        db: upsertDb(ref), graphql, businessId: "biz-1", now,
      });
    } catch (e) {
      caught = e;
    }
    expect(caught).toBe(transport);
    expect(caught).toBeInstanceOf(WaveApiError);
    expect(caught.kind).toBe("network");
    // No write-back on transport failure.
    expect(ref.updates).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// upsertCustomer — missing doc
// ---------------------------------------------------------------------------

describe("upsertCustomer missing doc", () => {
  test("missing client doc → skipped, no graphql call", async () => {
    const ref = clientRef(null);
    const graphql = jest.fn();
    const result = await upsertCustomer("gone", {
      db: upsertDb(ref), graphql, businessId: "biz-1", now,
    });
    expect(result).toEqual({status: "skipped", reason: "missing-doc"});
    expect(graphql).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// not connected (wave/connection businessId missing)
// ---------------------------------------------------------------------------

describe("not connected (missing businessId)", () => {
  test("upsertCustomer rejects when no injected or stored businessId",
      async () => {
        const ref = clientRef({...CLIENT});
        const graphql = jest.fn();
        await expect(
            upsertCustomer("c1", {
              db: upsertDb(ref, {businessId: ""}), graphql, now,
            }),
        ).rejects.toThrow(/not connected/);
        expect(graphql).not.toHaveBeenCalled();
      });

  test("importCustomers rejects when no injected or stored businessId",
      async () => {
        const {db} = importDb([], {businessId: ""});
        const graphql = jest.fn();
        await expect(
            importCustomers({db, graphql, now}),
        ).rejects.toThrow(/not connected/);
        expect(graphql).not.toHaveBeenCalled();
      });
});

// ---------------------------------------------------------------------------
// importCustomers
// ---------------------------------------------------------------------------

/**
 * Builds a fake batch that records set() ops and counts commits.
 * @param {{sets: !Array, commits: number[]}} log Shared mutable log.
 * @return {!Object}
 */
function fakeBatch(log) {
  return {
    set: (ref, data, opts) => log.sets.push({ref, data, opts}),
    update: (ref, data) => log.sets.push({ref, data, update: true}),
    commit: () => {
      log.commits.push(log.sets.length);
      return Promise.resolve();
    },
  };
}

/**
 * Fake Firestore for import: a clients collection whose .get() returns
 * existing docs, .doc() mints auto-id refs, and batches are recorded.
 * @param {!Array<Object>} existingDocs Pre-existing client docs (with .data /
 *   .ref).
 * @param {Object=} opts `businessId` for the connection, and `jobs` — outbox
 *   job docs keyed by job id, read by the import's guarded transaction.
 * @return {!Object} `{db, batchLog, newRefs}`.
 */
function importDb(existingDocs, opts = {}) {
  const batchLog = {sets: [], commits: []};
  const newRefs = [];
  const jobs = opts.jobs || {};
  let autoId = 0;
  // This mirrors upsertDb — an explicit "" still needs to reach
  // readBusinessId as not-connected, so we only fall back to "biz-1" when
  // businessId is left out entirely.
  const connectionData = opts.businessId !== undefined ?
    {businessId: opts.businessId} : {businessId: "biz-1"};
  const waveColl = {
    doc: () => ({get: () => Promise.resolve(snap(connectionData))}),
  };
  const db = {
    collection: (name) => {
      if (name === "clients") {
        const clientsColl = {
          get: () => Promise.resolve({docs: existingDocs}),
          // buildWaveIdIndex projects to waveCustomerId + createdAt rather
          // than pulling whole client docs; select() returns the same shape.
          select: () => clientsColl,
          doc: () => {
            const ref = {id: `auto-${autoId++}`};
            newRefs.push(ref);
            return ref;
          },
        };
        return clientsColl;
      }
      if (name === "wave") return waveColl;
      if (name === "waveSyncQueue") return {doc: (id) => ({id})};
      throw new Error(`unexpected collection ${name}`);
    },
    batch: () => fakeBatch(batchLog),
    // A guarded update lands in the same log as a batched one, so every
    // assertion on `batchLog.sets` reads both write paths.
    runTransaction: async (fn) => fn({
      get: async (ref) => snap(jobs[ref.id] === undefined ?
        null : jobs[ref.id]),
      set: (ref, data, txOpts) => batchLog.sets.push({ref, data, opts: txOpts}),
    }),
  };
  return {db, batchLog, newRefs};
}

// Builds a Wave list-customers page envelope.
const listPage = (currentPage, totalPages, totalCount, nodes) => ({
  business: {
    customers: {
      pageInfo: {currentPage, totalPages, totalCount},
      edges: nodes.map((node) => ({node})),
    },
  },
});

/**
 * A Wave customer node.
 * @param {string} id Wave id.
 * @param {string} name Customer name.
 * @param {Object=} extra Field overrides.
 * @return {!Object}
 */
function waveNode(id, name, extra = {}) {
  return {
    id,
    name,
    firstName: "",
    lastName: "",
    email: `${name}@x.com`,
    phone: "",
    mobile: "",
    isArchived: false,
    address: null,
    ...extra,
  };
}

describe("importCustomers", () => {
  test("paginates 2 pages, skips archived, batches, returns summary",
      async () => {
        const {db, batchLog, newRefs} = importDb([]);
        const graphql = graphqlSeq(
            listPage(1, 2, 3, [
              waveNode("w1", "Alpha"),
              waveNode("w2", "Beta", {isArchived: true}),
            ]),
            listPage(2, 2, 3, [waveNode("w3", "Gamma")]),
        );
        const summary = await importCustomers({
          db, graphql, businessId: "biz-1", pageSize: 100, now,
        });

        expect(graphql).toHaveBeenCalledTimes(2);
        // Page args advance 1 → 2.
        expect(graphql.mock.calls[0][1].page).toBe(1);
        expect(graphql.mock.calls[1][1].page).toBe(2);

        expect(summary).toEqual({
          totalCount: 3,
          imported: 2, // Alpha + Gamma
          updated: 0,
          skippedArchived: 1, // Beta
          skippedPending: 0,
          skippedUnchanged: 0,
          pages: 2,
          delta: false,
        });
        // Two new auto-id docs created; one final commit.
        expect(newRefs).toHaveLength(2);
        expect(batchLog.commits).toHaveLength(1);
        // Each set carries the synced wave sub-map + the waveCustomerId.
        const first = batchLog.sets[0];
        expect(first.data.waveCustomerId).toBe("w1");
        expect(first.data.wave.syncState).toBe("synced");
        expect(first.data.wave.lastSyncedHash).toEqual(expect.any(String));
        // New docs MUST carry createdAt/updatedAt — the clients list orders by
        // createdAt and Firestore hides docs missing it.
        expect(first.data.createdAt).toBe(TS);
        expect(first.data.updatedAt).toBe(TS);
      });

  test("leaves a client alone while its edit is still queued for Wave",
      async () => {
        // The import overwrites every mapped field AND stamps
        // wave.lastSyncedHash from Wave's values — so overwriting a client
        // whose edit hasn't been pushed yet doesn't just lose the edit, it
        // marks it synced: the pending job then hashes the clobbered doc,
        // matches, and no-ops. The change is gone with the row reading
        // "synced" and nothing logged.
        const protectedRef = {id: "pending-doc"};
        const openRef = {id: "open-doc"};
        const {db, batchLog} = importDb([
          {data: () => ({waveCustomerId: "w1"}), ref: protectedRef},
          {data: () => ({waveCustomerId: "w2"}), ref: openRef},
        ]);
        const graphql = graphqlSeq(
            listPage(1, 1, 2, [
              waveNode("w1", "Stale From Wave"),
              waveNode("w2", "Fine To Refresh"),
            ]),
        );

        const summary = await importCustomers({
          db, graphql, businessId: "biz-1", now,
          skipClientIds: new Set(["pending-doc"]),
        });

        expect(summary.skippedPending).toBe(1);
        expect(summary.updated).toBe(1);
        // Only the unprotected client was written.
        expect(batchLog.sets).toHaveLength(1);
        expect(batchLog.sets[0].ref).toBe(openRef);
      });

  test("protects an edit queued AFTER the protect-list was read", async () => {
    // The race a pre-read list cannot close: nothing was outstanding when it
    // was read, then an edit enqueued mid-import. The write's own transaction
    // reads that client's job and leaves the client alone.
    const openRef = {id: "open-doc"};
    const {db, batchLog} = importDb(
        [{data: () => ({waveCustomerId: "w1"}), ref: openRef}],
        {jobs: {"customerUpsert__open-doc": {status: "queued"}}},
    );
    const graphql = graphqlSeq(
        listPage(1, 1, 1, [waveNode("w1", "Stale From Wave")]),
    );

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now, skipClientIds: new Set(),
    });

    expect(summary.skippedPending).toBe(1);
    expect(summary.updated).toBe(0);
    expect(batchLog.sets).toHaveLength(0);
  });

  test("a delta run asks Wave to filter, and says it was a delta", async () => {
    const {db} = importDb([]);
    const graphql = graphqlSeq(listPage(1, 1, 0, []));

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now,
      since: "2026-08-01T00:00:00.000Z",
    });

    const [query, vars] = graphql.mock.calls[0];
    expect(query).toContain("modifiedAtAfter: $since");
    expect(vars.since).toBe("2026-08-01T00:00:00.000Z");
    expect(summary.delta).toBe(true);
  });

  test("a full run sends no modifiedAtAfter at all", async () => {
    // Deliberately a SEPARATE document rather than a nullable variable: a
    // server reading an omitted variable as `modifiedAtAfter: null` would
    // return nothing, i.e. a full import that imports zero and reports
    // success.
    const {db} = importDb([]);
    const graphql = graphqlSeq(listPage(1, 1, 0, []));

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now,
    });

    const [query, vars] = graphql.mock.calls[0];
    expect(query).not.toContain("modifiedAtAfter");
    expect(vars).not.toHaveProperty("since");
    expect(summary.delta).toBe(false);
  });

  test("a delta run that changes nothing reads no client docs", async () => {
    // The index is built lazily precisely for this case — the steady-state
    // sync should cost one Wave call and zero Firestore reads.
    let indexReads = 0;
    const {db} = importDb([]);
    const originalCollection = db.collection.bind(db);
    db.collection = (name) => {
      const coll = originalCollection(name);
      if (name === "clients") {
        const origGet = coll.get.bind(coll);
        coll.get = () => {
          indexReads += 1;
          return origGet();
        };
      }
      return coll;
    };
    const graphql = graphqlSeq(listPage(1, 1, 0, []));

    await importCustomers({
      db, graphql, businessId: "biz-1", now, since: "2026-08-01T00:00:00Z",
    });

    expect(indexReads).toBe(0);
  });

  test("skips a customer whose mapped fields already match", async () => {
    // The equality is exact, not a heuristic: `lastSyncedHash` is taken over
    // the same toWaveCustomerInput projection the write would produce, so a
    // match means the write is byte-identical. Steady state is therefore ~0
    // writes and ~0 waveUpsertCustomer trigger invocations, instead of one
    // of each per customer per press.
    const node = waveNode("w1", "Alpha");
    const settledHash = mappedFieldsHash(fromWaveCustomer(node));
    const {db, batchLog} = importDb([
      {
        data: () => ({
          waveCustomerId: "w1",
          createdAt: TS,
          wave: {lastSyncedHash: settledHash},
        }),
        ref: {id: "settled-doc"},
      },
    ]);
    const graphql = graphqlSeq(listPage(1, 1, 1, [node]));

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now,
    });

    expect(summary.skippedUnchanged).toBe(1);
    // `updated` counts real changes only — it used to count every existing
    // customer written, so an untouched roster reported "650 updated".
    expect(summary.updated).toBe(0);
    expect(batchLog.sets).toHaveLength(0);
  });

  test("still writes a matching doc that is missing createdAt", async () => {
    // The update branch is the only thing that backfills createdAt, and the
    // clients list orders by it — Firestore excludes docs missing an orderBy
    // field, so skipping here would hide a legacy doc from the list forever.
    const node = waveNode("w1", "Alpha");
    const settledHash = mappedFieldsHash(fromWaveCustomer(node));
    const {db, batchLog} = importDb([
      {
        data: () => ({
          waveCustomerId: "w1",
          wave: {lastSyncedHash: settledHash},
        }),
        ref: {id: "legacy-doc"},
      },
    ]);
    const graphql = graphqlSeq(listPage(1, 1, 1, [node]));

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now,
    });

    expect(summary.skippedUnchanged).toBe(0);
    expect(summary.updated).toBe(1);
    expect(batchLog.sets[0].data.createdAt).toBe(TS);
  });

  test("writes when Wave's values have actually changed", async () => {
    const {db, batchLog} = importDb([
      {
        data: () => ({
          waveCustomerId: "w1",
          createdAt: TS,
          wave: {lastSyncedHash: mappedFieldsHash(
              fromWaveCustomer(waveNode("w1", "Old Name")))},
        }),
        ref: {id: "changed-doc"},
      },
    ]);
    const graphql = graphqlSeq(listPage(1, 1, 1, [waveNode("w1", "New Name")]));

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now,
    });

    expect(summary.skippedUnchanged).toBe(0);
    expect(summary.updated).toBe(1);
    expect(batchLog.sets[0].data.name).toBe("New Name");
  });

  test("protects nothing when no skip set is supplied", async () => {
    // Defaulting to an empty set keeps the helper callable in tests, but a
    // production caller that forgets it silently reopens the clobber above.
    const existingRef = {id: "existing-doc"};
    const {db, batchLog} = importDb([
      {data: () => ({waveCustomerId: "w1"}), ref: existingRef},
    ]);
    const graphql = graphqlSeq(listPage(1, 1, 1, [waveNode("w1", "Alpha")]));

    const summary = await importCustomers({
      db, graphql, businessId: "biz-1", now,
    });

    expect(summary.skippedPending).toBe(0);
    expect(batchLog.sets).toHaveLength(1);
  });

  test("idempotent: existing waveCustomerId updates same ref, no duplicate",
      async () => {
        const existingRef = {id: "existing-doc"};
        const existingDoc = {
          data: () => ({waveCustomerId: "w1", name: "Old"}),
          ref: existingRef,
        };
        const {db, batchLog, newRefs} = importDb([existingDoc]);
        const graphql = graphqlSeq(
            listPage(1, 1, 1, [waveNode("w1", "Alpha")]),
        );
        const summary = await importCustomers({
          db, graphql, businessId: "biz-1", now,
        });

        expect(summary.updated).toBe(1);
        expect(summary.imported).toBe(0);
        // No new doc minted — the existing ref is reused.
        expect(newRefs).toHaveLength(0);
        const op = batchLog.sets[0];
        expect(op.ref).toBe(existingRef);
        expect(op.opts).toEqual({merge: true});
        expect(op.data.name).toBe("Alpha");
        // updatedAt is always refreshed. createdAt gets backfilled too, since
        // the existing doc didn't have one — otherwise an earlier import
        // that omitted it would stay hidden forever.
        expect(op.data.updatedAt).toBe(TS);
        expect(op.data.createdAt).toBe(TS);
      });

  test("update preserves an existing createdAt (no overwrite)",
      async () => {
        const existingRef = {id: "existing-doc"};
        const existingDoc = {
          data: () => ({
            waveCustomerId: "w1",
            name: "Old",
            createdAt: {__earlier: true},
          }),
          ref: existingRef,
        };
        const {db, batchLog} = importDb([existingDoc]);
        const graphql = graphqlSeq(
            listPage(1, 1, 1, [waveNode("w1", "Alpha")]),
        );
        await importCustomers({db, graphql, businessId: "biz-1", now});

        const op = batchLog.sets[0];
        // createdAt is left untouched; only updatedAt is refreshed.
        expect(op.data).not.toHaveProperty("createdAt");
        expect(op.data.updatedAt).toBe(TS);
      });

  test("a new client doc carries archived: false", async () => {
    const {db, batchLog} = importDb([]);
    const graphql = graphqlSeq(listPage(1, 1, 1, [waveNode("w1", "Alpha")]));
    await importCustomers({db, graphql, businessId: "biz-1", now});

    // The clients list filters `archived == false` server-side, and Firestore
    // excludes docs missing a filtered field — an import that skipped this
    // would create clients invisible in the list but present in search.
    expect(batchLog.sets[0].data.archived).toBe(false);
  });

  test("the update branch leaves an archived client archived", async () => {
    const existingRef = {id: "existing-doc"};
    const existingDoc = {
      data: () => ({waveCustomerId: "w1", name: "Old", archived: true}),
      ref: existingRef,
    };
    const {db, batchLog} = importDb([existingDoc]);
    const graphql = graphqlSeq(listPage(1, 1, 1, [waveNode("w1", "Alpha")]));
    await importCustomers({db, graphql, businessId: "biz-1", now});

    // Writing archived here would un-archive every archived client on every
    // scheduled import.
    expect(batchLog.sets[0].data).not.toHaveProperty("archived");
  });

  test("reads businessId from wave/connection when not injected", async () => {
    const {db} = importDb([], {businessId: "biz-xyz"});
    const graphql = graphqlSeq(listPage(1, 1, 0, []));
    await importCustomers({db, graphql, now});
    expect(graphql.mock.calls[0][1].id).toBe("biz-xyz");
  });
});

// ---------------------------------------------------------------------------
// sanitizeInputErrors
// ---------------------------------------------------------------------------
// Wave's raw `message` text must never reach our UI or logs — we only ever
// surface messages mapped from a known `code`.
describe("sanitizeInputErrors", () => {
  test("maps a known code to its safe message", () => {
    expect(sanitizeInputErrors([{code: "INVALID_EMAIL"}]))
        .toBe("The customer email address is not valid.");
  });

  test("never echoes Wave's raw message text", () => {
    const raw = "secret-internal-detail-from-wave";
    const out = sanitizeInputErrors([{code: "INVALID_EMAIL", message: raw}]);
    expect(out).not.toContain(raw);
  });

  test("falls back to the generic message for an unknown code", () => {
    expect(sanitizeInputErrors([{code: "SOMETHING_NEW"}]))
        .toBe("Wave rejected the customer data.");
  });

  test("joins distinct codes and de-duplicates repeats", () => {
    const out = sanitizeInputErrors([
      {code: "TOO_LONG"},
      {code: "INVALID_PHONE"},
      {code: "TOO_LONG"},
    ]);
    expect(out).toBe(
        "A customer field is too long for Wave. " +
        "The customer phone number is not valid.");
  });

  test("tolerates non-array and malformed entries", () => {
    expect(sanitizeInputErrors(null)).toBe("Wave rejected the customer data.");
    expect(sanitizeInputErrors([null, {}, {code: 7}]))
        .toBe("Wave rejected the customer data.");
  });
});
