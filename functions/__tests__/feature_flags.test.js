"use strict";

const mockEvaluate = jest.fn();
const mockGetServerTemplate = jest.fn();
jest.mock("firebase-admin/remote-config", () => ({
  getRemoteConfig: () => ({getServerTemplate: mockGetServerTemplate}),
}));

const {HttpsError} = require("firebase-functions/v2/https");
const {FLAG_DEFAULTS} = require("../feature_flags_policy");
const {
  loadFromRemoteConfig,
  assertFeatureEnabled,
  _resetForTest,
} = require("../feature_flags");

beforeEach(() => {
  mockEvaluate.mockReset();
  mockGetServerTemplate.mockReset();
  mockGetServerTemplate.mockImplementation(
      async () => ({evaluate: mockEvaluate}));
  _resetForTest();
});

test("loadFromRemoteConfig evaluates the server template", async () => {
  mockEvaluate.mockReturnValue({
    getString: (k) => ({
      feature_presence: "false",
      min_supported_build: "90",
    })[k] ?? "true",
  });
  await expect(loadFromRemoteConfig()).resolves.toMatchObject({
    feature_presence: false,
    feature_wave_sync: true,
    min_supported_build: 90,
  });
});

test("assertFeatureEnabled passes while the feature is on", async () => {
  mockEvaluate.mockReturnValue({getString: () => "true"});
  await expect(assertFeatureEnabled("feature_wave_sync", "waveBootstrap"))
      .resolves.toBeUndefined();
});

test("assertFeatureEnabled refuses with failed-precondition when off",
    async () => {
      mockEvaluate.mockReturnValue({
        getString: (k) => k === "feature_wave_sync" ? "false" : "",
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

test("a Remote Config outage fails open, loading with the defaults",
    async () => {
      mockGetServerTemplate.mockRejectedValue(new Error("rc down"));
      await expect(assertFeatureEnabled("feature_wave_sync", "x"))
          .resolves.toBeUndefined();
      expect(mockGetServerTemplate).toHaveBeenCalledWith(
          expect.objectContaining({defaultConfig: FLAG_DEFAULTS}));
    });
