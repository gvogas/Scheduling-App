"use strict";

const {readdirSync, readFileSync} = require("fs");
const path = require("path");
const {REGISTRY} = require("../scripts/run");
const {runScript} = require("../scripts/_runner");

const SCRIPTS_DIR = path.join(__dirname, "..", "scripts");

// The text each script's own summary template contains. The count readers
// parse that line, so a reworded summary must fail HERE rather than make the
// live gate unreadable (or, worse, read a different number).
const FRAGMENTS = {
  "backfill-client-address-street": [
    "clients: ${scanned} scanned, ${patched} reduced, ",
  ],
  "backfill-client-buildings": [
    "return {scanned, projectionsChanged, dryRun}", "then(console.log)",
  ],
  "backfill-client-name-digits": [
    "clients: ${scanned} scanned, ${patched} reformatted, ",
  ],
  "backfill-client-name-with-phone": [
    "clients: ${scanned} scanned, ${patched} renamed, ",
  ],
  "backfill-client-phone-formatting": [
    "clients: ${scanned} scanned, ${patched} patched",
  ],
  "backfill-client-sort-fields": [
    "clients: ${clients.scanned} scanned, ",
    "${clients.patched} sort rows patched",
  ],
  "backfill-clients-archived": ["clients: ${patched} patched, "],
  "backfill-search-tokens": [
    "clients: ${clients.scanned} scanned, ",
    "appointments: ${appointments.scanned} scanned, ",
    "${appointments.patched} token rows patched",
  ],
  "backfill-wave-blocked": [
    "clients: ${summary.scanned} scanned, ",
    "${summary.patched} verdict rows patched",
  ],
  "backfill": [
    "JSON.stringify(stats, null, 2)", "updated: 0", "created: 0",
    "orphansFound: 0",
  ],
  "drain-wave-queue": ["queued jobs: ${depth}"],
  "recount-client-jobs": [
    "clients: ${clients.scanned} scanned, ",
    "${clients.patched} job counts patched",
  ],
  "repair-client-address-mojibake": [
    "clients: ${scanned} scanned, ", "${patched} repaired",
  ],
};

const BRIDGE = [
  "[dry-run] Backfill complete:", "{", "  \"scanned\": 9,",
  "  \"updated\": 2,", "  \"created\": 1,", "  \"orphansFound\": 4", "}",
].join("\n");

describe("run.js registry", () => {
  test("covers every script in functions/scripts/", () => {
    const onDisk = readdirSync(SCRIPTS_DIR)
        .filter((f) => f.endsWith(".js") && !f.startsWith("_") &&
          f !== "run.js")
        .sort();
    const registered = Object.values(REGISTRY).map((e) => e.file).sort();
    expect(registered).toEqual(onDisk);
  });

  test("every write script has a count reader", () => {
    for (const [name, entry] of Object.entries(REGISTRY)) {
      if (entry.kind === "write") {
        expect([name, typeof entry.countFrom]).toEqual([name, "function"]);
      }
    }
  });

  test("every write script is pinned by FRAGMENTS", () => {
    const writes = Object.entries(REGISTRY)
        .filter(([, e]) => e.kind === "write").map(([n]) => n).sort();
    expect(Object.keys(FRAGMENTS).sort()).toEqual(writes);
  });

  test.each(Object.entries(FRAGMENTS))(
      "%s: its source still prints the line the count reads",
      (name, fragments) => {
        const source = readFileSync(
            path.join(SCRIPTS_DIR, REGISTRY[name].file), "utf8");
        for (const fragment of fragments) {
          expect(source).toContain(fragment);
        }
      });

  // Each sample is the summary as the script's own template renders it.
  test.each([
    ["backfill-client-address-street",
      "[dry-run] clients: 900 scanned, 12 reduced, 888 left alone", [], 12],
    ["backfill-client-buildings",
      "{ scanned: 900, projectionsChanged: 4, dryRun: true }", [], 4],
    ["backfill-client-name-digits",
      "[dry-run] clients: 900 scanned, 3 reformatted, 897 left alone", [], 3],
    ["backfill-client-name-with-phone",
      "[dry-run] clients: 900 scanned, 5 renamed, 2 skipped (business), " +
      "1 skipped (created on/after 2026-08-14), 3 skipped (no phone), " +
      "4 skipped (already correct)", [], 5],
    ["backfill-client-phone-formatting",
      "[dry-run] clients: 900 scanned, 8 patched — 6 had a number " +
      "reformatted, 2 had their name re-stated", [], 8],
    ["backfill-client-sort-fields",
      "[dry-run] clients: 900 scanned, 9 sort rows patched", [], 9],
    ["backfill-clients-archived",
      "[dry-run] clients: 11 patched, 889 already had the field", [], 11],
    ["backfill-search-tokens",
      "[dry-run] clients: 900 scanned, 2 token rows patched\n" +
      "[dry-run] appointments: 5000 scanned, 3 token rows patched", [], 5],
    ["backfill-wave-blocked",
      "\n[dry-run] clients: 900 scanned, 6 verdict rows patched", [], 6],
    ["backfill", BRIDGE, [], 3],
    ["backfill", BRIDGE, ["--prune-orphans"], 7],
    ["drain-wave-queue",
      "queued jobs: 14\n\n[dry-run] nothing pushed. Drop --dry-run to drain.",
      [], 14],
    ["recount-client-jobs",
      "[dry-run] clients: 900 scanned, 10 job counts patched", [], 10],
    ["repair-client-address-mojibake",
      "[dry-run] clients: 900 scanned, 1 repaired", [], 1],
  ])("%s reads its count", (name, stdout, passthrough, expected) => {
    expect(REGISTRY[name].countFrom(stdout, passthrough)).toBe(expected);
  });

  test("a summary that does not match reads as unknown, never zero", () => {
    for (const entry of Object.values(REGISTRY)) {
      if (entry.kind === "write") {
        expect(entry.countFrom("something else entirely", [])).toBeNull();
      }
    }
  });

  test("the retired phone script is refused and never spawned", async () => {
    const spawnScript = jest.fn();
    for (const extra of [[], ["--live"], ["--live", "--yes-count=1"]]) {
      await expect(runScript({
        argv: ["backfill-client-phone-from-name", ...extra],
        registry: REGISTRY, spawnScript, prompt: jest.fn(),
        log: () => {}, env: {FIRESTORE_EMULATOR_HOST: "x"},
      })).rejects.toThrow(/retired/);
    }
    expect(spawnScript).not.toHaveBeenCalled();
  });
});
