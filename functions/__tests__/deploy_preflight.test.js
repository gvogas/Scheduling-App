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

describe("deploy workflow parity", () => {
  const fs = require("fs");
  const path = require("path");
  const yml = fs.readFileSync(path.join(__dirname, "..", "..", ".github",
      "workflows", "deploy.yml"), "utf8")
      .replace(/\r/g, "");
  const block = yml.match(/^ {6}targets:\n(?: {8}.*\n)+/m)[0];
  const options = [...block.matchAll(/^ {10}- (\S+)$/gm)].map((m) => m[1]);

  test("the workflow lists targets and plan() accepts every one", () => {
    expect(options.length).toBeGreaterThan(0);
    for (const option of options) {
      expect(() => plan("demo-audit", option)).not.toThrow();
    }
  });
});

test("a partial grant lists exactly the permissions not granted", async () => {
  const scope = plan("demo-audit", "firestore:rules");
  const granted = scope.permissions.slice(0, 1);
  const request = jest.fn(async () => ({ok: true, status: 200,
    json: async () => ({permissions: granted})}));
  const result = await preflight("demo-audit", "firestore:rules", "t", request);
  expect(result.checks).toEqual([{name: "target-permissions", ok: false,
    status: 200, missing: scope.permissions.slice(1)}]);
});

describe("main", () => {
  const {main} = require("../scripts/deploy/preflight");
  let errorSpy;
  beforeEach(() => {
    errorSpy = jest.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => {
    errorSpy.mockRestore();
  });
  const run = async (argv, exec, request) => {
    const write = jest.fn();
    const status = await main(argv, {exec, write, request});
    return {status, write, report: write.mock.calls[0] &&
      JSON.parse(write.mock.calls[0][1])};
  };

  test("an invalid impersonation identity is rejected, not executed",
      async () => {
        const exec = jest.fn();
        const {status, report} = await run(["storage", "demo-audit", "out.json",
          "evil@example.com"], exec);
        expect(exec).not.toHaveBeenCalled();
        expect(status).toBe(1);
        expect(report.checks).toEqual([{name: "authentication", ok: false,
          error: "deployment-token-unavailable"}]);
      });

  test("an invalid target throws before anything is written", async () => {
    const write = jest.fn();
    await expect(main(["bogus", "demo-audit", "out.json"], {write}))
        .rejects.toThrow("Invalid deployment preflight scope");
    expect(write).not.toHaveBeenCalled();
  });

  test("impersonation stderr maps to impersonation-unavailable", async () => {
    const exec = () => {
      throw Object.assign(new Error("x"), {stderr: "Failed to impersonate"});
    };
    const {status, report} = await run(["storage", "demo-audit", "out.json",
      "dep@demo-audit.iam.gserviceaccount.com"], exec);
    expect(status).toBe(1);
    expect(report.checks[0].error).toBe("impersonation-unavailable");
  });

  test("other token failures map to deployment-token-unavailable", async () => {
    const exec = () => {
      throw Object.assign(new Error("x"), {stderr: "gcloud not found"});
    };
    const {report} = await run(["storage", "demo-audit", "out.json"], exec);
    expect(report.checks[0].error).toBe("deployment-token-unavailable");
  });

  test("success writes the report to the output path and returns 0",
      async () => {
        const scope = plan("demo-audit", "storage");
        const request = jest.fn(async (_url, options) =>
          options.method === "POST" ? {ok: true, status: 200,
            json: async () => ({permissions: scope.permissions})} :
            {ok: true, status: 200});
        const exec = jest.fn(() => "tok\n");
        const {status, write, report} = await run(
            ["storage", "demo-audit", "out.json"], exec, request);
        expect(status).toBe(0);
        expect(write.mock.calls[0][0]).toBe("out.json");
        expect(report.checks.every((c) => c.ok)).toBe(true);
        expect(JSON.stringify(report)).not.toContain("tok");
        expect(errorSpy).not.toHaveBeenCalled();
      });

  test("a failed check returns 1 and emits the error annotation", async () => {
    const request = jest.fn(async (_url, options) => options.method === "POST" ?
      {ok: true, status: 200, json: async () => ({permissions: []})} :
      {ok: true, status: 200});
    const {status} = await run(["storage", "demo-audit", "out.json"],
        () => "tok", request);
    expect(status).toBe(1);
    expect(errorSpy.mock.calls[0][0]).toMatch(/^::error::/);
  });
});
