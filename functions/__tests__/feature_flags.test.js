"use strict";

const mockEvaluate = jest.fn();
jest.mock("firebase-admin/remote-config", () => ({
  getRemoteConfig: () => ({
    getServerTemplate: jest.fn(async () => ({evaluate: mockEvaluate})),
  }),
}));

const {HttpsError} = require("firebase-functions/v2/https");
const {
  loadFromRemoteConfig,
  assertFeatureEnabled,
  _resetForTest,
} = require("../feature_flags");

beforeEach(() => {
  mockEvaluate.mockReset();
  _resetForTest();
});

test("loadFromRemoteConfig evaluates the server template", async () => {
  mockEvaluate.mockReturnValue({
    getBoolean: (k) => k !== "feature_presence",
    getNumber: () => 90,
  });
  await expect(loadFromRemoteConfig()).resolves.toMatchObject({
    feature_presence: false,
    feature_wave_sync: true,
    min_supported_build: 90,
  });
});

test("assertFeatureEnabled passes while the feature is on", async () => {
  mockEvaluate.mockReturnValue({getBoolean: () => true, getNumber: () => 0});
  await expect(assertFeatureEnabled("feature_wave_sync", "waveBootstrap"))
      .resolves.toBeUndefined();
});

test("assertFeatureEnabled refuses with failed-precondition when off",
    async () => {
      mockEvaluate.mockReturnValue({
        getBoolean: (k) => k !== "feature_wave_sync",
        getNumber: () => 0,
      });
      const call = assertFeatureEnabled("feature_wave_sync", "waveBootstrap");
      await expect(call).rejects.toBeInstanceOf(HttpsError);
      await expect(call).rejects.toMatchObject({
        code: "failed-precondition",
        message: "feature-disabled",
      });
    });

test("an unknown key is a programming error, not a silent pass", async () => {
  await expect(assertFeatureEnabled("feature_nope", "x"))
      .rejects.toThrow(/unknown flag/);
});
