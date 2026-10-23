"use strict";

const {
  MINUTE_MS,
  ESTIMATE_TTL_MS,
  pruneEstimates,
  readEstimate,
  canDeferRoutes,
  computeLeadMinutes,
} = require("../travel_policy");

const TTL = ESTIMATE_TTL_MS;

describe("readEstimate", () => {
  test.each([
    ["a fresh hit", 0, 5 * MINUTE_MS, 600],
    ["a hit exactly at the TTL", 0, TTL, 600],
    ["an expired hit", 0, TTL + 1, null],
  ])("%s", (_label, atMs, nowMs, expected) => {
    const cache = new Map([["k", {seconds: 600, atMs}]]);
    expect(readEstimate(cache, "k", nowMs)).toBe(expected);
  });

  test("a missing key is null", () => {
    expect(readEstimate(new Map(), "k", 0)).toBeNull();
  });

  test("an expired hit is evicted on read", () => {
    const cache = new Map([["k", {seconds: 60, atMs: 0}]]);
    readEstimate(cache, "k", TTL + 1);
    expect(cache.has("k")).toBe(false);
  });
});

describe("pruneEstimates", () => {
  test("drops only the expired entries", () => {
    const cache = new Map([
      ["old", {seconds: 1, atMs: 0}],
      ["new", {seconds: 2, atMs: TTL}],
    ]);
    pruneEstimates(cache, TTL + 1);
    expect([...cache.keys()]).toEqual(["new"]);
  });
});

describe("canDeferRoutes", () => {
  const startTimeMillis = 10_000 * MINUTE_MS;
  // 600 s drive -> 10 + 10 buffer = 20 min lead; skip margin 15 min.
  const edge = startTimeMillis - 20 * MINUTE_MS - 15 * MINUTE_MS;

  test.each([
    ["no cached estimate", null, edge - 1, false],
    ["well before the margin", 600, edge - 1, true],
    ["exactly at the margin", 600, edge, false],
    ["past the margin", 600, edge + 1, false],
  ])("%s", (_label, seconds, nowMillis, expected) => {
    expect(canDeferRoutes({seconds, startTimeMillis, nowMillis}))
        .toBe(expected);
  });

  test("a fresh estimate defers to within five minutes of leaving", () => {
    const fresh = startTimeMillis - 20 * MINUTE_MS - 5 * MINUTE_MS;
    const at = (now, age) => canDeferRoutes({seconds: 600, startTimeMillis,
      nowMillis: now, estimatedAtMillis: now - age * MINUTE_MS});
    expect(at(fresh - 1, 5)).toBe(true);
    expect(at(fresh, 5)).toBe(false);
    // Six minutes old is no longer fresh: back to the fifteen-minute margin.
    expect(at(fresh - 1, 6)).toBe(false);
    expect(at(edge - 1, 6)).toBe(true);
  });

  test("a 30-minute lead pair costs 5 Routes calls, not 7", () => {
    // Sweeps every 5 min from T-90 to the send; each computed estimate is
    // the same 20-minute drive (lead 30), cached as the sweep would.
    const start = 10_000 * MINUTE_MS;
    const cache = new Map();
    let calls = 0;
    for (let t = start - 90 * MINUTE_MS; t <= start; t += 5 * MINUTE_MS) {
      const seconds = readEstimate(cache, "k", t);
      const deferred = canDeferRoutes({seconds, startTimeMillis: start,
        nowMillis: t, estimatedAtMillis: seconds == null ? null :
          cache.get("k").atMs});
      if (deferred) continue;
      calls += 1;
      cache.set("k", {seconds: 1200, atMs: t});
      if (t >= start - 30 * MINUTE_MS) break;
    }
    expect(calls).toBe(5);
  });

  test("a capped lead still defers conservatively", () => {
    const capped = startTimeMillis - 90 * MINUTE_MS - 15 * MINUTE_MS;
    expect(computeLeadMinutes(100_000)).toBe(90);
    expect(canDeferRoutes({seconds: 100_000, startTimeMillis,
      nowMillis: capped - 1})).toBe(true);
    expect(canDeferRoutes({seconds: 100_000, startTimeMillis,
      nowMillis: capped})).toBe(false);
  });
});
