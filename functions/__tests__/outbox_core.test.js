"use strict";

const {commitOutcome, claimJob} = require("../wave/outbox_core");

/**
 * Minimal transactional Firestore double over one job document.
 * @param {?Object} data Job data, or null for a missing doc.
 * @return {!Object} `{db, ref, updates}`.
 */
function fakeDb(data) {
  const ref = {id: "customerUpsert__c1"};
  const updates = [];
  const db = {
    runTransaction: async (body) => body({
      get: async () => ({exists: data !== null, data: () => data}),
      update: (target, patch) => updates.push({target, patch}),
    }),
  };
  return {db, ref, updates};
}

const CLAIM = new Date("2026-10-20T12:00:00Z");

describe("commitOutcome", () => {
  test("writes while the job is inflight with the same claim", async () => {
    const {db, ref, updates} = fakeDb({status: "inflight", claimedAt: CLAIM});
    expect(await commitOutcome(db, ref, new Date(CLAIM.getTime()),
        {status: "done"})).toBe(true);
    expect(updates).toEqual([{target: ref, patch: {status: "done"}}]);
  });

  test("matches a Timestamp-like stamp by epoch ms", async () => {
    const stamp = {toMillis: () => CLAIM.getTime()};
    const {db, ref, updates} = fakeDb({status: "inflight", claimedAt: stamp});
    expect(await commitOutcome(db, ref, CLAIM, {status: "done"})).toBe(true);
    expect(updates).toHaveLength(1);
  });

  test.each([
    ["a re-claim with a different stamp",
      {status: "inflight", claimedAt: new Date("2030-01-01")}],
    ["a re-enqueued job", {status: "queued", claimedAt: CLAIM}],
    ["an already done job", {status: "done", claimedAt: CLAIM}],
    ["a dead-lettered job", {status: "dead", claimedAt: CLAIM}],
    ["a job with no claim", {status: "inflight"}],
  ])("skips the write for %s", async (_label, data) => {
    const {db, ref, updates} = fakeDb(data);
    expect(await commitOutcome(db, ref, CLAIM, {status: "done"}))
        .toBe(false);
    expect(updates).toEqual([]);
  });

  test("skips the write when the job is gone", async () => {
    const {db, ref, updates} = fakeDb(null);
    expect(await commitOutcome(db, ref, CLAIM, {status: "done"}))
        .toBe(false);
    expect(updates).toEqual([]);
  });

  test("resets the result when the transaction body re-runs", async () => {
    const ref = {};
    let calls = 0;
    const db = {
      runTransaction: async (body) => {
        const tx = {
          get: async () => ({exists: true, data: () => (calls++ === 0 ?
            {status: "inflight", claimedAt: CLAIM} : {status: "queued"})}),
          update: () => {},
        };
        await body(tx);
        await body(tx);
      },
    };
    expect(await commitOutcome(db, ref, CLAIM, {status: "done"}))
        .toBe(false);
  });
});

describe("claimJob", () => {
  const logger = {warn: jest.fn()};
  const due = new Date(CLAIM.getTime() - 1000);

  test("claims a due queued job and stamps the lease", async () => {
    const {db, ref, updates} = fakeDb({status: "queued", nextAttemptAt: due});
    const claimed = await claimJob({db, logger}, {id: "j", ref}, CLAIM);
    expect(claimed.status).toBe("queued");
    expect(updates[0].patch).toEqual({status: "inflight", claimedAt: CLAIM});
  });

  test.each([
    ["an inflight job", {status: "inflight", nextAttemptAt: due}],
    ["a job not yet due",
      {status: "queued", nextAttemptAt: new Date(CLAIM.getTime() + 1000)}],
    ["a job with no due time", {status: "queued"}],
  ])("does not claim %s", async (_label, data) => {
    const {db, ref, updates} = fakeDb(data);
    expect(await claimJob({db, logger}, {id: "j", ref}, CLAIM)).toBeNull();
    expect(updates).toEqual([]);
  });

  test("returns null and warns when the transaction throws", async () => {
    const db = {runTransaction: async () => {
      throw new Error("aborted");
    }};
    expect(await claimJob({db, logger}, {id: "j", ref: {}}, CLAIM))
        .toBeNull();
    expect(logger.warn).toHaveBeenCalled();
  });
});
