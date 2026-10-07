"use strict";

// The one entry point for the scripts in this directory: dry-run by default,
// and a live run only against a dry-run count taken in the same invocation.

/**
 * Parses the runner's own flags; everything else passes through.
 * @param {!Array<string>} argv Arguments after node + run.js.
 * @return {{name: string, live: boolean, yesCount: ?number,
 *     passthrough: !Array<string>}} The parsed invocation.
 */
function parseRunnerArgs(argv) {
  const [name, ...rest] = argv;
  if (!name || name.startsWith("--")) {
    throw new Error(
        "usage: node functions/scripts/run.js <name> " +
        "[--dry-run|--live [--yes-count=<n>]] [script args]");
  }
  const live = rest.includes("--live");
  if (live && rest.includes("--dry-run")) {
    throw new Error("pass --live or --dry-run, not both");
  }
  let yesCount = null;
  const passthrough = [];
  for (const arg of rest) {
    if (arg === "--live" || arg === "--dry-run") continue;
    if (arg.startsWith("--yes-count=")) {
      const raw = arg.slice("--yes-count=".length);
      if (!/^\d+$/.test(raw)) {
        throw new Error("--yes-count must be a non-negative integer");
      }
      yesCount = Number(raw);
      continue;
    }
    passthrough.push(arg);
  }
  if (yesCount !== null && !live) {
    throw new Error("--yes-count is used only with --live");
  }
  return {name, live, yesCount, passthrough};
}

/**
 * Runs one registered script.
 * @param {{argv: !Array<string>, registry: !Object, spawnScript: !Function,
 *     prompt: !Function, log: !Function, env: !Object}} deps Injected so
 *     the gate is testable without a child process or a terminal.
 * @return {!Promise<number>} The exit code.
 */
async function runScript({argv, registry, spawnScript, prompt, log, env}) {
  const {name, live, yesCount, passthrough} = parseRunnerArgs(argv);
  const entry = registry[name];
  if (!entry) {
    throw new Error(
        `unknown script "${name}". Known: ${Object.keys(registry).join(", ")}`);
  }
  if (entry.kind === "retired") {
    throw new Error(`${name} is retired and must not run: ${entry.reason}`);
  }
  if (entry.kind === "emulator" && !env.FIRESTORE_EMULATOR_HOST) {
    throw new Error(`${name} is emulator-only; set FIRESTORE_EMULATOR_HOST`);
  }
  if (entry.kind !== "write") {
    if (live) throw new Error(`${name} is read-only; drop --live`);
    return (await spawnScript(entry.file, passthrough, {capture: false})).code;
  }

  const dry = await spawnScript(
      entry.file, ["--dry-run", ...passthrough], {capture: true});
  if (dry.code !== 0) return dry.code;
  if (!live) {
    log(`\nDry run only. To apply: node functions/scripts/run.js ${name} ` +
      "--live (it re-runs this dry run first).");
    return 0;
  }

  const count = entry.countFrom(dry.stdout, passthrough);
  if (count === null || Number.isNaN(count)) {
    throw new Error(
        `could not read the dry-run count from ${entry.file}'s output; ` +
        "refusing to run live");
  }
  log(`\ndry-run count: ${count}`);
  if (count === 0) {
    log("Nothing to change. Not running live.");
    return 0;
  }
  const typed = yesCount !== null ? yesCount :
    Number(String(await prompt(
        `Type ${count} to apply it LIVE (anything else aborts): `)).trim());
  if (typed !== count) {
    log(`Aborted: confirmed ${typed}, the dry run just counted ${count}.`);
    return 1;
  }
  return (await spawnScript(entry.file, passthrough, {capture: false})).code;
}

module.exports = {parseRunnerArgs, runScript};
