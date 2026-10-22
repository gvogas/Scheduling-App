"use strict";

const {plan, preflight} = require("../scripts/deploy/preflight");

test("Storage checks the pinned CLI default-bucket discovery", () => {
  const scope = plan("demo-audit", "storage");
  expect(scope.requests).toEqual([{name: "storage-discovery",
    permission: "firebasestorage.defaultBucket.get",
    url: "https://firebasestorage.googleapis.com/v1alpha/projects/" +
      "demo-audit/defaultBucket"}]);
  expect(scope.permissions.some((permission) => permission.startsWith(
      "cloudfunctions."))).toBe(false);
});

test("the index read sends no pageSize, which Firestore refuses", () => {
  const {requests} = plan("schedulingapp-88727", "firestore:indexes");
  const read = requests.find((r) => r.name === "indexes-list");
  expect(read.url).toMatch(/\/collectionGroups\/-\/indexes$/);
  expect(read.url).not.toContain("pageSize");
});

test("permission failures report no bearer token", async () => {
  const request = jest.fn(async (_url, options) => options.method === "POST" ?
    {ok: true, status: 200, json: async () => ({permissions: []})} :
    {ok: false, status: 403});
  const result = await preflight("demo-audit", "storage", "secret-bearer",
      request);
  expect(result.checks.every((check) => !check.ok)).toBe(true);
  expect(result.checks[1].permission).toBe("firebasestorage.defaultBucket.get");
  expect(JSON.stringify(result)).not.toContain("secret-bearer");
  expect(request.mock.calls.every(([, options]) =>
    ["POST", "GET"].includes(options.method))).toBe(true);
});

test("all-target preflight is bounded and read-only", async () => {
  const scope = plan("demo-audit", "all");
  const request = jest.fn(async (_url, options) => options.method === "POST" ?
    {ok: true, status: 200, json: async () =>
      ({permissions: scope.permissions})} : {ok: true, status: 200});
  const result = await preflight("demo-audit", "all", "private", request);
  expect(result.checks).toHaveLength(5);
  expect(result.checks.every((check) => check.ok)).toBe(true);
});
