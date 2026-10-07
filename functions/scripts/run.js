#!/usr/bin/env node
"use strict";

// node functions/scripts/run.js <name> [--dry-run|--live] [script args]

const {spawn} = require("child_process");
const path = require("path");
const readline = require("readline/promises");
const {runScript} = require("./_runner");

/**
 * A count reader for the first capture of `pattern`.
 * @param {!RegExp} pattern One capture group holding the count.
 * @return {function(string): ?number} The reader.
 */
function firstNumber(pattern) {
  return (stdout) => {
    const match = stdout.match(pattern);
    return match ? Number(match[1]) : null;
  };
}

/**
 * A count reader summing every capture of a global `pattern`.
 * @param {!RegExp} pattern Global, one capture group per count.
 * @return {function(string): ?number} The reader.
 */
function sumOf(pattern) {
  return (stdout) => {
    const matches = [...stdout.matchAll(pattern)];
    if (matches.length === 0) return null;
    return matches.reduce((total, m) => total + Number(m[1]), 0);
  };
}

/**
 * `backfill.js` prints its stats as JSON: updates and creates always
 * write, orphans only with `--prune-orphans`.
 * @param {string} stdout The dry run's output.
 * @param {!Array<string>} passthrough The operator's script args.
 * @return {?number} The count.
 */
function bridgeCount(stdout, passthrough) {
  const read = (key) => firstNumber(new RegExp(`"${key}": (\\d+)`))(stdout);
  const updated = read("updated");
  const created = read("created");
  if (updated === null || created === null) return null;
  const prune = passthrough.includes("--prune-orphans");
  return updated + created + (prune ? read("orphansFound") || 0 : 0);
}

const REGISTRY = {
  "audit-wave-contract": {file: "audit-wave-contract.js", kind: "read"},
  "count-multi-day-appointments": {
    file: "count-multi-day-appointments.js", kind: "read",
  },
  "seed-emulator": {file: "seed-emulator.js", kind: "emulator"},
  "backfill-client-phone-from-name": {
    file: "backfill-client-phone-from-name.js",
    kind: "retired",
    reason: "superseded 2026-08-14 by backfill-client-name-with-phone; " +
      "re-running it renames clients in Wave",
  },
  "backfill-client-address-street": {
    file: "backfill-client-address-street.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) reduced/),
  },
  "backfill-client-buildings": {
    file: "backfill-client-buildings.js", kind: "write",
    countFrom: firstNumber(/projectionsChanged: (\d+)/),
  },
  "backfill-client-name-digits": {
    file: "backfill-client-name-digits.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) reformatted/),
  },
  "backfill-client-name-with-phone": {
    file: "backfill-client-name-with-phone.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) renamed/),
  },
  "backfill-client-phone-formatting": {
    file: "backfill-client-phone-formatting.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) patched/),
  },
  "backfill-client-sort-fields": {
    file: "backfill-client-sort-fields.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) sort rows patched/),
  },
  "backfill-clients-archived": {
    file: "backfill-clients-archived.js", kind: "write",
    countFrom: firstNumber(/clients: (\d+) patched/),
  },
  "backfill-search-tokens": {
    file: "backfill-search-tokens.js", kind: "write",
    countFrom: sumOf(/: \d+ scanned, (\d+) token rows patched/g),
  },
  "backfill-wave-blocked": {
    file: "backfill-wave-blocked.js", kind: "write",
    countFrom: firstNumber(
        /clients: \d+ scanned, (\d+) verdict rows patched/),
  },
  "backfill": {file: "backfill.js", kind: "write", countFrom: bridgeCount},
  "drain-wave-queue": {
    file: "drain-wave-queue.js", kind: "write",
    countFrom: firstNumber(/queued jobs: (\d+)/),
  },
  "recount-client-jobs": {
    file: "recount-client-jobs.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) job counts patched/),
  },
  "repair-client-address-mojibake": {
    file: "repair-client-address-mojibake.js", kind: "write",
    countFrom: firstNumber(/clients: \d+ scanned, (\d+) repaired/),
  },
};

/**
 * Runs a script in a child node process, teeing stdout when captured.
 * @param {string} file A file in this directory.
 * @param {!Array<string>} args Its arguments.
 * @param {{capture: boolean}} options Whether to collect stdout.
 * @return {!Promise<{code: number, stdout: string}>} The result.
 */
function spawnScript(file, args, {capture}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [path.join(__dirname, file),
      ...args], {stdio: capture ? ["inherit", "pipe", "inherit"] : "inherit"});
    let stdout = "";
    if (capture) {
      child.stdout.on("data", (chunk) => {
        process.stdout.write(chunk);
        stdout += chunk;
      });
    }
    child.on("error", reject);
    child.on("close", (code) => resolve({code: code === null ? 1 : code,
      stdout}));
  });
}

/**
 * Asks one question on the terminal.
 * @param {string} question The prompt.
 * @return {!Promise<string>} The answer.
 */
async function prompt(question) {
  const rl = readline.createInterface(
      {input: process.stdin, output: process.stdout});
  try {
    return await rl.question(question);
  } finally {
    rl.close();
  }
}

if (require.main === module) {
  runScript({
    argv: process.argv.slice(2), registry: REGISTRY, spawnScript, prompt,
    log: console.log, env: process.env,
  }).then((code) => {
    process.exitCode = code;
  }).catch((err) => {
    console.error(err.message);
    process.exitCode = 1;
  });
}

module.exports = {REGISTRY};
