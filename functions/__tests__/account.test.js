"use strict";

/**
 * Tests for the pure stale-reauth guard behind deleteAccount. This is the
 * security predicate that decides whether the in-app re-auth is fresh enough
 * to allow an irreversible delete — the delete orchestration itself is
 * integration-heavy and isn't covered here.
 */

const {isReauthStale, REAUTH_MAX_AGE_SECONDS: MAX} = require("../security");
const NOW = 1000000;

describe("isReauthStale", () => {
  test("a fresh re-auth (same instant) is not stale", () => {
    expect(isReauthStale(NOW, NOW, MAX)).toBe(false);
  });

  test("a re-auth exactly at the window edge is still allowed", () => {
    expect(isReauthStale(NOW - MAX, NOW, MAX)).toBe(false);
  });

  test("a re-auth one second past the window is stale", () => {
    expect(isReauthStale(NOW - MAX - 1, NOW, MAX)).toBe(true);
  });

  test("a missing auth_time is treated as stale", () => {
    expect(isReauthStale(undefined, NOW, MAX)).toBe(true);
    expect(isReauthStale(null, NOW, MAX)).toBe(true);
  });

  test("a non-numeric auth_time is treated as stale", () => {
    expect(isReauthStale("1000000", NOW, MAX)).toBe(true);
  });
});
