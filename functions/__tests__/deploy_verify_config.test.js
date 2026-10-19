"use strict";

const {inspectConfig} = require("../scripts/deploy/verify_config");

const healthy = {
  name: "projects/demo/locations/us-central1/functions/waveUpsertCustomer",
  state: "ACTIVE", buildConfig: {runtime: "nodejs24"},
  serviceConfig: {maxInstanceRequestConcurrency: 1,
    maxInstanceCount: 2, timeoutSeconds: 300,
    environmentVariables: {SECRET: "must-never-appear"}},
  eventTrigger: {retryPolicy: "RETRY_POLICY_RETRY"},
};

test("healthy output contains no environment or credentials", () => {
  const result = inspectConfig("waveUpsertCustomer", healthy);
  expect(result.issues).toEqual([]);
  expect(JSON.stringify(result)).not.toContain("must-never-appear");
});

test("concurrency drift fails even with the right export name", () => {
  const actual = {...healthy, serviceConfig: {
    ...healthy.serviceConfig, maxInstanceRequestConcurrency: 80,
  }};
  expect(inspectConfig("waveUpsertCustomer", actual).issues)
      .toEqual(["wave-concurrency-must-be-one"]);
});

test("state, runtime, name and retry settings fail independently", () => {
  expect(inspectConfig("waveUpsertCustomer", {}).issues).toEqual([
    "function-not-active", "unexpected-runtime", "unexpected-name",
    "unexpected-region",
    "wave-concurrency-must-be-one", "wave-instance-limit", "wave-timeout",
    "wave-retry-disabled",
  ]);
});

test("Storage validator is verified in its bucket region", () => {
  const actual = {...healthy,
    name: "projects/demo/locations/us-east1/functions/validateUploadedImage"};
  expect(inspectConfig("validateUploadedImage", actual).issues).toEqual([]);
  expect(inspectConfig("validateUploadedImage", {...actual,
    name: actual.name.replace("us-east1", "us-central1")}).issues)
      .toEqual(["unexpected-region"]);
});
