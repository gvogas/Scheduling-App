"use strict";

const {parseRunnerArgs, runScript} = require("../scripts/_runner");

describe("parseRunnerArgs", () => {
  test("defaults to dry-run and passes other args through", () => {
    expect(parseRunnerArgs(["recount", "--verbose"])).toEqual({
      name: "recount", live: false, yesCount: null,
      passthrough: ["--verbose"],
    });
  });

  test("an explicit --dry-run is accepted and not passed through", () => {
    expect(parseRunnerArgs(["recount", "--dry-run"]).passthrough).toEqual([]);
  });

  test("reads --live and --yes-count", () => {
    expect(parseRunnerArgs(["recount", "--live", "--yes-count=12"]))
        .toMatchObject({live: true, yesCount: 12, passthrough: []});
  });

  test.each([
    [[], /usage/],
    [["--live"], /usage/],
    [["recount", "--live", "--dry-run"], /both/],
    [["recount", "--yes-count=3"], /only with --live/],
    [["recount", "--live", "--yes-count=-1"], /non-negative integer/],
    [["recount", "--live", "--yes-count=abc"], /non-negative integer/],
  ])("rejects %j", (argv, message) => {
    expect(() => parseRunnerArgs(argv)).toThrow(message);
  });
});

/**
 * A fake child: the dry run prints `stdout`, the live run prints nothing.
 * @param {string} stdout What the dry run prints.
 * @return {!Object} A jest mock of spawnScript.
 */
function fakeSpawn(stdout) {
  return jest.fn(async (file, args) => ({
    code: 0,
    stdout: args.includes("--dry-run") ? stdout : "",
  }));
}

const REGISTRY = {
  fake: {
    file: "fake.js",
    kind: "write",
    countFrom: (stdout) => {
      const m = stdout.match(/(\d+) patched/);
      return m ? Number(m[1]) : null;
    },
  },
  reader: {file: "reader.js", kind: "read"},
  gone: {file: "gone.js", kind: "retired", reason: "superseded"},
  seed: {file: "seed.js", kind: "emulator"},
};

/**
 * Runs the core with fakes.
 * @param {!Array<string>} argv Runner args.
 * @param {!Object=} overrides Replacement deps.
 * @return {!Promise<{code: number, spawn: !Object, prompt: !Object}>} Result.
 */
async function run(argv, overrides = {}) {
  const spawn = overrides.spawn || fakeSpawn("clients: 7 patched");
  const prompt = overrides.prompt || jest.fn(async () => "7");
  const code = await runScript({
    argv, registry: REGISTRY, spawnScript: spawn, prompt,
    log: () => {}, env: overrides.env || {},
  });
  return {code, spawn, prompt};
}

describe("runScript", () => {
  test("default is a dry run only", async () => {
    const {code, spawn, prompt} = await run(["fake", "--verbose"]);
    expect(code).toBe(0);
    expect(spawn).toHaveBeenCalledTimes(1);
    expect(spawn).toHaveBeenCalledWith(
        "fake.js", ["--dry-run", "--verbose"], {capture: true});
    expect(prompt).not.toHaveBeenCalled();
  });

  test("--live re-runs the dry run, confirms the count, then runs live",
      async () => {
        const {code, spawn, prompt} = await run(["fake", "--live", "-v"]);
        expect(code).toBe(0);
        expect(prompt).toHaveBeenCalledTimes(1);
        expect(spawn.mock.calls).toEqual([
          ["fake.js", ["--dry-run", "-v"], {capture: true}],
          ["fake.js", ["-v"], {capture: false}],
        ]);
      });

  test("a typed count that does not match aborts before the live run",
      async () => {
        const {code, spawn} = await run(["fake", "--live"], {
          prompt: jest.fn(async () => "6"),
        });
        expect(code).toBe(1);
        expect(spawn).toHaveBeenCalledTimes(1);
      });

  test("a stale --yes-count aborts without prompting", async () => {
    const {code, spawn, prompt} =
      await run(["fake", "--live", "--yes-count=5"]);
    expect(code).toBe(1);
    expect(prompt).not.toHaveBeenCalled();
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  test("a matching --yes-count runs live without prompting", async () => {
    const {code, spawn, prompt} =
      await run(["fake", "--live", "--yes-count=7"]);
    expect(code).toBe(0);
    expect(prompt).not.toHaveBeenCalled();
    expect(spawn).toHaveBeenCalledTimes(2);
  });

  test("a zero count never runs live", async () => {
    const {code, spawn} = await run(["fake", "--live"], {
      spawn: fakeSpawn("clients: 0 patched"),
    });
    expect(code).toBe(0);
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  test("an unreadable count refuses the live run", async () => {
    await expect(run(["fake", "--live"], {spawn: fakeSpawn("garbage")}))
        .rejects.toThrow(/could not read/);
  });

  test("a failing dry run stops there", async () => {
    const spawn = jest.fn(async () => ({code: 2, stdout: ""}));
    const {code} = await run(["fake", "--live"], {spawn});
    expect(code).toBe(2);
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  test("a read script runs as-is and refuses --live", async () => {
    const {spawn} = await run(["reader", "--verbose"]);
    expect(spawn).toHaveBeenCalledWith(
        "reader.js", ["--verbose"], {capture: false});
    await expect(run(["reader", "--live"])).rejects.toThrow(/read-only/);
  });

  test("a retired script is always refused", async () => {
    await expect(run(["gone"])).rejects.toThrow(/superseded/);
  });

  test("an emulator script needs FIRESTORE_EMULATOR_HOST", async () => {
    await expect(run(["seed"])).rejects.toThrow(/FIRESTORE_EMULATOR_HOST/);
    const {code} = await run(["seed"], {
      env: {FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080"},
    });
    expect(code).toBe(0);
  });

  test("an unknown name lists the known ones", async () => {
    await expect(run(["nope"])).rejects.toThrow(/fake, reader, gone, seed/);
  });
});
