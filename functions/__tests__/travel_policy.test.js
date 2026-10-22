"use strict";

const {
  MINUTE_MS,
  pruneEstimates,
  readEstimate,
  canDeferRoutes,
  computeLeadMinutes,
} = require("../travel_policy");

const TTL = 10 * MINUTE_MS;

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

  test("a capped lead still defers conservatively", () => {
    const capped = startTimeMillis - 90 * MINUTE_MS - 15 * MINUTE_MS;
    expect(computeLeadMinutes(100_000)).toBe(90);
    expect(canDeferRoutes({seconds: 100_000, startTimeMillis,
      nowMillis: capped - 1})).toBe(true);
    expect(canDeferRoutes({seconds: 100_000, startTimeMillis,
      nowMillis: capped})).toBe(false);
  });
});
