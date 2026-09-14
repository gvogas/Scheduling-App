"use strict";

const {
  enqueueCustomerUpsert,
  shouldEnqueueClientWrite,
} = require("../wave/enqueue");
const {mappedFieldsHash} = require("../wave/mappers");
const {TS, now, fakeRef} = require("./mocks/wave_outbox_fakes");

/**
 * Builds a fake Firestore that holds a single `waveSyncQueue` doc (for
 * enqueue tests).
 * @param {string} jobId
 * @param {Object|null} existingData
 * @return {{db: !Object, ref: !Object}}
 */
function enqueueDb(jobId, existingData = null) {
  const ref = fakeRef(jobId, existingData);
  const db = {
    collection: jest.fn((col) => {
      if (col !== "waveSyncQueue") throw new Error(`unexpected col: ${col}`);
      return {
        doc: jest.fn((id) => {
          if (id !== jobId) throw new Error(`unexpected doc id: ${id}`);
          return ref;
        }),
      };
    }),
  };
  return {db, ref};
}

// ---------------------------------------------------------------------------
// enqueueCustomerUpsert
// ---------------------------------------------------------------------------

describe("enqueueCustomerUpsert", () => {
  test("uses deterministic jobId customerUpsert__<clientId>", async () => {
    const {db, ref} = enqueueDb("customerUpsert__abc123");
    const jobId = await enqueueCustomerUpsert("abc123", {db, now});
    expect(jobId).toBe("customerUpsert__abc123");
    expect(ref.sets).toHaveLength(1);
  });

  test("writes required fields with merge:true", async () => {
    const {db, ref} = enqueueDb("customerUpsert__c1");
    await enqueueCustomerUpsert("c1", {db, now});

    expect(ref.set).toHaveBeenCalledWith(
        expect.objectContaining({
          type: "customerUpsert",
          refPath: "clients/c1",
          status: "queued",
          nextAttemptAt: TS,
          idempotencyKey: "customerUpsert__c1",
          attempts: 0,
          lastError: null,
        }),
        {merge: true},
    );
  });

  test("re-enqueue for same client resets attempts:0, status:queued, " +
    "lastError:null (does NOT create a second doc)", async () => {
    // Simulate an existing job that had failed attempts.
    const existing = {
      type: "customerUpsert",
      refPath: "clients/c1",
      status: "dead",
      attempts: 3,
      lastError: "WaveApiError(auth)",
      idempotencyKey: "customerUpsert__c1",
      nextAttemptAt: new Date(0),
    };
    const {db, ref} = enqueueDb("customerUpsert__c1", existing);
    await enqueueCustomerUpsert("c1", {db, now});

    // Only ONE set() call (merge:true on the same ref — no new doc).
    expect(ref.sets).toHaveLength(1);
    expect(ref.sets[0].opts).toEqual({merge: true});
    expect(ref.sets[0].data.attempts).toBe(0);
    expect(ref.sets[0].data.status).toBe("queued");
    expect(ref.sets[0].data.lastError).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// enqueueCustomerUpsert — payloadHash
// ---------------------------------------------------------------------------

describe("enqueueCustomerUpsert payloadHash", () => {
  test("writes payloadHash when provided", async () => {
    const {db, ref} = enqueueDb("customerUpsert__c1");
    await enqueueCustomerUpsert("c1", {db, now, payloadHash: "abc123"});

    expect(ref.set).toHaveBeenCalledWith(
        expect.objectContaining({payloadHash: "abc123"}),
        {merge: true},
    );
  });

  test("omits payloadHash when not provided", async () => {
    const {db, ref} = enqueueDb("customerUpsert__c1");
    await enqueueCustomerUpsert("c1", {db, now});

    const written = ref.sets[0].data;
    expect(Object.prototype.hasOwnProperty.call(written, "payloadHash"))
        .toBe(false);
  });
});

// ---------------------------------------------------------------------------
// enqueueCustomerUpsert — batch staging (waveUpsertCustomer atomicity)
// ---------------------------------------------------------------------------

describe("enqueueCustomerUpsert batch staging", () => {
  test(
      "stages set(merge) on the provided batch instead of writing",
      async () => {
        const {db, ref} = enqueueDb("customerUpsert__c1");
        const batch = {set: jest.fn()};
        const jobId = await enqueueCustomerUpsert("c1", {
          db, now, batch, payloadHash: "h1",
        });

        expect(jobId).toBe("customerUpsert__c1");
        // The direct write path must NOT run — the caller owns the commit.
        expect(ref.set).not.toHaveBeenCalled();
        expect(batch.set).toHaveBeenCalledTimes(1);
        const [batchRef, data, opts] = batch.set.mock.calls[0];
        expect(batchRef).toBe(ref);
        expect(opts).toEqual({merge: true});
        expect(data).toEqual(expect.objectContaining({
          type: "customerUpsert",
          refPath: "clients/c1",
          status: "queued",
          attempts: 0,
          lastError: null,
          payloadHash: "h1",
        }));
      });
});

// ---------------------------------------------------------------------------
// shouldEnqueueClientWrite
// ---------------------------------------------------------------------------

describe("shouldEnqueueClientWrite", () => {
  // A representative mapped-field set. Individual tests tweak copies of
  // this as needed.
  const base = {
    name: "Acme Co",
    email: "billing@acme.test",
    phone: "514-555-0100",
    address: "100 Main St",
    city: "Montreal",
    province: "QC",
    country: "Canada",
    postalCode: "H2X 1Y4",
  };

  test("enqueues a real mapped-field change (name edited)", () => {
    const before = {...base};
    const after = {...base, name: "Acme Corp"};
    expect(shouldEnqueueClientWrite(before, after)).toBe(true);
  });

  test("skips a wave-only change (worker write-back echo)", () => {
    const before = {...base, wave: {syncState: "queued"}};
    // Only wave.* / waveCustomerId changed — mapped fields are identical.
    const after = {
      ...base,
      waveCustomerId: "wv-123",
      wave: {
        syncState: "synced",
        lastSyncedHash: "stale-different-hash",
        lastSyncedAt: "ts",
      },
    };
    expect(shouldEnqueueClientWrite(before, after)).toBe(false);
  });

  test("skips an unmapped-field-only change (e.g. business contacts)", () => {
    const before = {...base, contacts: [{name: "A"}]};
    const after = {...base, contacts: [{name: "A"}, {name: "B"}]};
    expect(shouldEnqueueClientWrite(before, after)).toBe(false);
  });

  test("skips when after already matches lastSyncedHash (import write)", () => {
    // Import writes the full doc with lastSyncedHash = hash(mapped fields).
    const after = {
      ...base,
      waveCustomerId: "wv-1",
      wave: {syncState: "synced", lastSyncedHash: mappedFieldsHash(base)},
    };
    // before differs in mapped fields, so rule 1 doesn't short-circuit
    // here. What actually suppresses the enqueue is rule 2 — the
    // lastSyncedHash match.
    const before = {...base, name: "Old Name"};
    expect(shouldEnqueueClientWrite(before, after)).toBe(false);
  });

  test("enqueues on create (no before) when not pre-synced", () => {
    const after = {...base};
    expect(shouldEnqueueClientWrite(null, after)).toBe(true);
    expect(shouldEnqueueClientWrite(undefined, after)).toBe(true);
  });

  test("skips on create when import already stamped lastSyncedHash", () => {
    const after = {
      ...base,
      wave: {syncState: "synced", lastSyncedHash: mappedFieldsHash(base)},
    };
    expect(shouldEnqueueClientWrite(null, after)).toBe(false);
  });

  test("enqueues when a mapped field changes even if a stale " +
    "lastSyncedHash is present", () => {
    const after = {
      ...base,
      email: "new@acme.test",
      wave: {syncState: "synced", lastSyncedHash: mappedFieldsHash(base)},
    };
    const before = {...base};
    expect(shouldEnqueueClientWrite(before, after)).toBe(true);
  });
});
