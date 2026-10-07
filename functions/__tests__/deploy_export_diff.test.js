"use strict";

const {
  declaredExports,
  liveFunctions,
  diffExports,
} = require("../scripts/deploy/export_diff");

describe("declaredExports", () => {
  test("reads every exports.<name> = line, sorted", () => {
    const source = [
      "const a = require(\"./a\");",
      "exports.zeta = a.zeta;",
      "exports.alpha =",
      "  a.alpha;",
      "// exports.commented = nope;",
    ].join("\n");
    expect(declaredExports(source)).toEqual(["alpha", "zeta"]);
  });
});

describe("liveFunctions", () => {
  test("reads ids out of functions:list --json", () => {
    const json = JSON.stringify({
      status: "success",
      result: [{id: "b", region: "us-central1"}, {id: "a"}],
    });
    expect(liveFunctions(json)).toEqual(["a", "b"]);
  });

  test("falls back to the last segment of a resource name", () => {
    const json = JSON.stringify({result: [
      {name: "projects/p/locations/us-central1/functions/deleteAccount"},
    ]});
    expect(liveFunctions(json)).toEqual(["deleteAccount"]);
  });

  test("treats a missing result as no functions", () => {
    expect(liveFunctions("{\"status\":\"success\"}")).toEqual([]);
  });
});

describe("diffExports", () => {
  test("names additions and deletions by NAME, not count", () => {
    // Same count, different set: the 2026-08-14 25 -> 25 swap.
    expect(diffExports(["a", "b", "new"], ["a", "b", "old"])).toEqual({
      added: ["new"],
      removed: ["old"],
    });
  });

  test("an identical set diffs to nothing", () => {
    expect(diffExports(["a"], ["a"])).toEqual({added: [], removed: []});
  });
});

describe("main", () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const {main} = require("../scripts/deploy/export_diff");

  /**
   * Runs `main` against temp files with console output silenced.
   * @param {string} index Contents of the fake index.js.
   * @param {!Array<string>} ids Live function ids.
   * @param {!Array<string>} extra Extra CLI args.
   * @return {number} The exit code.
   */
  function run(index, ids, extra = []) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "export-diff-"));
    const indexPath = path.join(dir, "index.js");
    const livePath = path.join(dir, "live.json");
    fs.writeFileSync(indexPath, index);
    fs.writeFileSync(livePath,
        JSON.stringify({result: ids.map((id) => ({id}))}));
    jest.spyOn(console, "log").mockImplementation(() => {});
    jest.spyOn(console, "error").mockImplementation(() => {});
    try {
      return main([indexPath, livePath, ...extra]);
    } finally {
      jest.restoreAllMocks();
      fs.rmSync(dir, {recursive: true, force: true});
    }
  }

  test("a live function no longer exported fails", () => {
    expect(run("exports.a = 1;", ["a", "old"])).toBe(1);
  });

  test("an addition passes before the deploy", () => {
    expect(run("exports.a = 1;\nexports.b = 2;", ["a"])).toBe(0);
  });

  test("an addition still missing after the deploy fails", () => {
    expect(run("exports.a = 1;\nexports.b = 2;", ["a"],
        ["--after-deploy"])).toBe(1);
  });
});
