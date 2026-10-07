"use strict";

const {
  FLAG_DEFAULTS,
  FLAG_KEYS,
  readFlags,
  createFlagCache,
} = require("../feature_flags_policy");

describe("FLAG_DEFAULTS", () => {
  test("every feature is on and no build is blocked", () => {
    expect(FLAG_DEFAULTS).toEqual({
      feature_address_autocomplete: true,
      feature_presence: true,
      feature_live_activities: true,
      feature_wave_sync: true,
      min_supported_build: 0,
    });
    expect(FLAG_KEYS).toEqual(Object.keys(FLAG_DEFAULTS));
  });
});

describe("readFlags", () => {
  test("reads booleans and the number through the evaluated config", () => {
    const config = {
      getBoolean: (k) => k !== "feature_wave_sync",
      getNumber: () => 93,
    };
    expect(readFlags(config)).toEqual({
      feature_address_autocomplete: true,
      feature_presence: true,
      feature_live_activities: true,
      feature_wave_sync: false,
      min_supported_build: 93,
    });
  });

  test("a non-finite build number falls back to 0", () => {
    const config = {getBoolean: () => true, getNumber: () => NaN};
    expect(readFlags(config).min_supported_build).toBe(0);
  });
});

describe("createFlagCache", () => {
  const logger = () => ({warn: jest.fn(), info: jest.fn()});

  test("reuses a load within the TTL and reloads after it", async () => {
    let t = 0;
    const loader = jest.fn(async () => ({...FLAG_DEFAULTS}));
    const cache = createFlagCache({loader, now: () => t, ttlMs: 60_000,
      logger: logger()});
    await cache.get();
    t = 59_999;
    await cache.get();
    expect(loader).toHaveBeenCalledTimes(1);
    t = 60_000;
    await cache.get();
    expect(loader).toHaveBeenCalledTimes(2);
  });

  test("a failed FIRST load fails open to the defaults and warns", async () => {
    const log = logger();
    const cache = createFlagCache({
      loader: async () => {
        throw new Error("no app");
      },
      now: () => 0, ttlMs: 60_000, logger: log,
    });
    await expect(cache.get()).resolves.toEqual(FLAG_DEFAULTS);
    expect(log.warn).toHaveBeenCalledTimes(1);
  });

  test("a failed reload keeps the last good values", async () => {
    let t = 0;
    const loader = jest.fn()
        .mockResolvedValueOnce({...FLAG_DEFAULTS, feature_wave_sync: false})
        .mockRejectedValueOnce(new Error("timeout"));
    const cache = createFlagCache({loader, now: () => t, ttlMs: 60_000,
      logger: logger()});
    await cache.get();
    t = 60_000;
    await expect(cache.get()).resolves.toMatchObject({
      feature_wave_sync: false,
    });
  });

  test("a failure is cached for the TTL too, so it is not retried per call",
      async () => {
        const loader = jest.fn().mockRejectedValue(new Error("down"));
        const cache = createFlagCache({loader, now: () => 0, ttlMs: 60_000,
          logger: logger()});
        await cache.get();
        await cache.get();
        expect(loader).toHaveBeenCalledTimes(1);
      });

  test("concurrent first calls share one load", async () => {
    const loader = jest.fn(async () => ({...FLAG_DEFAULTS}));
    const cache = createFlagCache({loader, now: () => 0, ttlMs: 60_000,
      logger: logger()});
    await Promise.all([cache.get(), cache.get(), cache.get()]);
    expect(loader).toHaveBeenCalledTimes(1);
  });
});
