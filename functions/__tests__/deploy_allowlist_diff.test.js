"use strict";

const {
  extractAllowlists,
  removedKeys,
  compareTrees,
  gitTrees,
  main,
} = require("../scripts/deploy/allowlist_diff");

const BASE = `
async function createHandler(req) {
  await assertAdminCall(req, new Set([
    "email",
    "isAdmin", // #compat-1.47.0
  ]));
}
const placesAutocomplete = onCall({}, async (req) => {
  const uid = await assertAdminCall(
      req,
      new Set(["input", "sessionToken"]),
  );
});
const waveBootstrap = onCall({}, async (req) => {
  await assertAdminCall(req, new Set());
});
function deleteAccount(req) {
  assertPayloadShape(req.data, new Set());
}
`;

describe("extractAllowlists", () => {
  test("keys each inline set by its owning function or onCall const", () => {
    const sets = extractAllowlists(BASE);
    expect([...sets.get("createHandler")]).toEqual(["email", "isAdmin"]);
    expect([...sets.get("placesAutocomplete")])
        .toEqual(["input", "sessionToken"]);
    expect([...sets.get("waveBootstrap")]).toEqual([]);
    expect([...sets.get("deleteAccount")]).toEqual([]);
  });

  test("handles assertActiveCall and a one-line multi-key set", () => {
    const sets = extractAllowlists(
        "async function f(req) {\n" +
        "  const p = await assertActiveCall(\n" +
        "      req, new Set([\"a\", \"b\"]));\n}\n");
    expect([...sets.get("f")]).toEqual(["a", "b"]);
  });

  test("ignores the definitions and commented mentions", () => {
    const sets = extractAllowlists(
        "async function assertAdminCall(req, allowedKeys) {\n" +
        "  // assertAdminCall(req, ALLOWED) is how it is called\n" +
        "  * assertPayloadShape(req.data, allowedKeys)\n}\n");
    expect(sets.size).toBe(0);
  });

  test("FAILS LOUDLY on a set it cannot read", () => {
    const bad = (body) => () => extractAllowlists(
        `function f(req) {\n  ${body}\n}\n`);
    expect(bad("assertAdminCall(req, ALLOWED);")).toThrow(/line 2/);
    expect(bad("assertPayloadShape(data, new Set([\"a\"]));"))
        .toThrow(/cannot read/);
    expect(bad("assertAdminCall(req, new Set([\"a\", KEY]));"))
        .toThrow(/line 2/);
    expect(bad("assertActiveCall(req, new Set([...KEYS]));"))
        .toThrow(/line 2/);
  });
});

describe("removedKeys", () => {
  test("a dropped key is reported", () => {
    const head = BASE.replace("\"isAdmin\", // #compat-1.47.0\n", "");
    expect(removedKeys(extractAllowlists(BASE), extractAllowlists(head)))
        .toEqual({removed: [{owner: "createHandler", key: "isAdmin"}],
          missingOwners: []});
  });

  test("an added key is fine", () => {
    const head = BASE.replace("\"email\",", "\"email\", \"phone\",");
    expect(removedKeys(extractAllowlists(BASE), extractAllowlists(head)))
        .toEqual({removed: [], missingOwners: []});
  });

  test("a vanished owner is reported separately, not as removals", () => {
    const head = BASE.replace("function deleteAccount", "function gone");
    expect(removedKeys(extractAllowlists(BASE), extractAllowlists(head)))
        .toEqual({removed: [], missingOwners: ["deleteAccount"]});
  });
});

describe("compareTrees", () => {
  const files = (map) => ({
    list: () => Object.keys(map),
    read: (f) => (f in map ? map[f] : null),
  });

  test("reports removals and vanished owners per file", () => {
    const head = BASE.replace("\"isAdmin\", // #compat-1.47.0\n", "");
    const gone = "function goneHandler(req) {\n" +
      "  assertPayloadShape(req.data, new Set([\"x\"]));\n}\n";
    const result = compareTrees(
        files({"a.js": BASE, "gone.js": gone}), files({"a.js": head}));
    expect(result.removed).toEqual(
        [{file: "a.js", owner: "createHandler", key: "isAdmin"}]);
    expect(result.missingOwners).toEqual(
        [{file: "gone.js", owner: "goneHandler"}]);
  });

  test("a file new at HEAD is fine, and security.js is skipped", () => {
    const result = compareTrees(
        files({}),
        files({"new.js": BASE, "security.js": "assertPayloadShape(a, b);"}));
    expect(result).toEqual({removed: [], missingOwners: []});
  });

  test("an owner that moved files is still compared, by name", () => {
    const head = BASE.replace("\"isAdmin\", // #compat-1.47.0\n", "");
    const result = compareTrees(
        files({"old.js": BASE}), files({"admin.js": head}));
    expect(result.missingOwners).toEqual([]);
    expect(result.removed).toEqual(
        [{file: "admin.js", owner: "createHandler", key: "isAdmin"}]);
  });

  test("an owner defined in two HEAD files stays a vanished owner", () => {
    const result = compareTrees(
        files({"old.js": BASE}), files({"a.js": BASE, "b.js": BASE}));
    expect(result.removed).toEqual([]);
    expect(result.missingOwners).toContainEqual(
        {file: "old.js", owner: "createHandler"});
  });

  test("an unreadable HEAD file throws rather than skipping", () => {
    expect(() => compareTrees(
        files({"a.js": BASE}),
        files({"a.js": "function f(r) { assertAdminCall(r, X); }"})))
        .toThrow(/a\.js/);
  });
});

describe("gitTrees and main against a fake git", () => {
  /**
   * A git runner whose `show` fails for every file.
   * @param {!Array<string>} listed Files `ls-tree` reports at the base.
   * @return {function(!Array<string>): string} The runner.
   */
  function brokenShow(listed) {
    return (args) => {
      if (args[0] === "ls-tree") return listed.join("\n") + "\n";
      if (args[0] === "ls-files") return "";
      if (args[0] === "show") throw new Error("fatal: bad object");
      return "";
    };
  }

  test("a file absent from the base listing reads as null", () => {
    expect(gitTrees("abc1234", brokenShow(["a.js"])).base.read("b.js"))
        .toBeNull();
  });

  test("a listed base file git cannot show throws", () => {
    expect(() => gitTrees("abc1234", brokenShow(["a.js"])).base.read("a.js"))
        .toThrow(/bad object/);
  });

  test("main exits 1 when git fails on a listed file", () => {
    const spy = jest.spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(main(["abc1234"], brokenShow(["a.js"]))).toBe(1);
      expect(spy.mock.calls.join("\n")).toMatch(/could not run/);
    } finally {
      spy.mockRestore();
    }
  });
});
