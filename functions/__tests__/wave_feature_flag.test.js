"use strict";

jest.mock("../security", () => {
  const actual = jest.requireActual("../security");
  return {
    ...actual,
    assertAdminCall: jest.fn(async (req) => req.auth.uid),
    enforceDurableRateLimit: jest.fn().mockResolvedValue({
      refund: jest.fn().mockResolvedValue(undefined),
    }),
  };
});
jest.mock("../feature_flags", () => {
  const {HttpsError} = require("firebase-functions/v2/https");
  return {
    getFeatureFlags: jest.fn(async () => ({feature_wave_sync: false})),
    assertFeatureEnabled: jest.fn(async () => {
      throw new HttpsError("failed-precondition", "feature-disabled");
    }),
  };
});

const security = require("../security");
const {assertFeatureEnabled} = require("../feature_flags");
const {drainQueue} = require("../wave/dispatch");
const {
  waveBootstrap,
  waveRetryFailedJobs,
  waveImportCustomers,
} = require("../wave/callables");

const ADMIN = {uid: "admin-uid"};

test("a paused drain claims nothing and reports paused", async () => {
  const db = {
    collection: jest.fn(() => {
      throw new Error("must not read the queue");
    }),
    runTransaction: jest.fn(),
  };
  const summary = await drainQueue({db, logger: {info: jest.fn()}});
  expect(summary).toMatchObject({paused: true, processed: 0, done: 0,
    dead: 0});
  expect(db.collection).not.toHaveBeenCalled();
  expect(db.runTransaction).not.toHaveBeenCalled();
});

test.each([
  ["waveBootstrap", waveBootstrap],
  ["waveRetryFailedJobs", waveRetryFailedJobs],
  ["waveImportCustomers", waveImportCustomers],
])("%s refuses while paused, before the limiter", async (name, fn) => {
  await expect(fn.run({data: {}, auth: ADMIN}))
      .rejects.toMatchObject({message: "feature-disabled"});
  expect(assertFeatureEnabled).toHaveBeenCalledWith("feature_wave_sync", name);
  expect(security.enforceDurableRateLimit).not.toHaveBeenCalled();
});
