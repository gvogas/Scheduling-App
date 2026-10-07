"use strict";

const {
  lastDeployedSha,
  appendRow,
  formatRow,
  main,
} = require("../scripts/deploy/deploy_log");

const DOC = [
  "# Deploying",
  "",
  "## Deploy log",
  "",
  "Keep this current.",
  "",
  "| Date | Commit | Targets | Fns live | Notes |",
  "|---|---|---|---|---|",
  "| 2026-09-29 | `cc38be5d` | functions | 32 | fixes |",
  "| 2026-09-30 | (uncommitted at deploy time) | functions | 32 | x |",
  "",
  "### A subsection after the table",
  "",
  "| 2026-01-01 | `deadbeef` | not | the | log |",
  "",
  "## Next section",
].join("\n");

describe("lastDeployedSha", () => {
  test("returns the newest row's sha, skipping rows without one", () => {
    expect(lastDeployedSha(DOC)).toBe("cc38be5d");
  });

  test("returns null when there is no Deploy log", () => {
    expect(lastDeployedSha("# nothing here")).toBeNull();
  });
});

describe("a table with blank lines between rows (the real log)", () => {
  const GAPPED = [
    "## Deploy log", "", "| Date | Commit | Targets | Fns live | Notes |",
    "|---|---|---|---|---|", "| 2026-08-01 | `aaaaaaa` | f | 1 | a |", "",
    "| 2026-08-02 | `bbbbbbb` | f | 1 | b |", "", "### Next", "",
  ].join("\n");

  test("reads and appends past the gaps", () => {
    expect(lastDeployedSha(GAPPED)).toBe("bbbbbbb");
    const row = "| 2026-08-03 | `ccccccc` | f | 1 | c |";
    const lines = appendRow(GAPPED, row).split("\n");
    expect(lines[lines.indexOf(row) - 1]).toContain("bbbbbbb");
  });
});

describe("appendRow", () => {
  test("inserts after the table's last row, before the subsection", () => {
    const row = "| 2026-10-07 | `abcdef12` | functions | 34 | new |";
    const lines = appendRow(DOC, row).split("\n");
    const at = lines.indexOf(row);
    expect(lines[at - 1]).toContain("2026-09-30");
    expect(lines[at + 1]).toBe("");
    expect(lastDeployedSha(appendRow(DOC, row))).toBe("abcdef12");
  });

  test("throws when the table is missing", () => {
    expect(() => appendRow("## Deploy log\n\nno table", "| x |"))
        .toThrow(/Deploy log table/);
  });
});

describe("formatRow", () => {
  test("shortens the sha and links the run", () => {
    expect(formatRow({
      date: "2026-10-07",
      sha: "abcdef1234567890",
      targets: "functions",
      count: "34",
      runUrl: "https://github.com/o/r/actions/runs/1",
    })).toBe(
        "| 2026-10-07 | `abcdef12` | functions | 34 | Deploy workflow " +
        "[run](https://github.com/o/r/actions/runs/1). Notes: what " +
        "changed, prompts seen, and what still stands. |");
  });
});

describe("formatRow notes", () => {
  const entry = {
    date: "2026-10-07", sha: "abcdef1234", targets: "functions",
    count: "32", runUrl: "https://x/1",
  };

  test("a notes value replaces the placeholder and is kept to one cell", () => {
    const row = formatRow({...entry, notes: "No-op | redeploy\nall green"});
    expect(row).toBe(
        "| 2026-10-07 | `abcdef12` | functions | 32 | Deploy workflow " +
        "[run](https://x/1). No-op / redeploy all green |");
  });

  test("blank notes fall back to the placeholder", () => {
    expect(formatRow({...entry, notes: "  "})).toContain("Notes: what changed");
  });
});

describe("main", () => {
  const fs = require("fs");
  const os = require("os");
  const path = require("path");

  /**
   * Runs `main` on a temp copy of DOC with console silenced.
   * @param {!Array<string>} args Arguments, with `FILE` standing for the doc.
   * @return {{code: number, text: string, out: !Array<string>}} Result.
   */
  function run(args) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "deploy-log-"));
    const file = path.join(dir, "DEPLOYMENT.md");
    fs.writeFileSync(file, DOC);
    const out = [];
    jest.spyOn(console, "log").mockImplementation((s) => out.push(s));
    jest.spyOn(console, "error").mockImplementation(() => {});
    try {
      const code = main(args.map((a) => (a === "FILE" ? file : a)));
      return {code, text: fs.readFileSync(file, "utf8"), out};
    } finally {
      jest.restoreAllMocks();
      fs.rmSync(dir, {recursive: true, force: true});
    }
  }

  test("last-sha prints the newest sha", () => {
    expect(run(["last-sha", "FILE"]).out).toEqual(["cc38be5d"]);
  });

  test("append writes the formatted row into the file", () => {
    const result = run(["append", "FILE", "--date=2026-10-07",
      "--sha=abcdef1234567890", "--targets=functions", "--count=34",
      "--run-url=https://x/1"]);
    expect(result.code).toBe(0);
    expect(lastDeployedSha(result.text)).toBe("abcdef12");
  });

  test("an unknown command fails", () => {
    expect(run(["nope", "FILE"]).code).toBe(1);
  });
});
