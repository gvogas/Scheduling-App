"use strict";

// Diffs functions/index.js exports against what prod runs, by name.

const {readFileSync} = require("fs");

/**
 * Export names declared in `functions/index.js`.
 * @param {string} source The file's contents.
 * @return {!Array<string>} Sorted names.
 */
function declaredExports(source) {
  const names = [];
  for (const match of source.matchAll(/^exports\.(\w+)\s*=/gm)) {
    names.push(match[1]);
  }
  return names.sort();
}

/**
 * Function names out of `firebase functions:list --json` stdout.
 * @param {string} json The CLI output.
 * @return {!Array<string>} Sorted names.
 */
function liveFunctions(json) {
  const parsed = JSON.parse(json);
  const rows = Array.isArray(parsed.result) ? parsed.result : [];
  return rows
      .map((row) => row.id || row.entryPoint ||
        String(row.name || "").split("/").pop())
      .filter(Boolean)
      .sort();
}

/**
 * Additions and deletions between the declared and the live set.
 * @param {!Array<string>} declared From `declaredExports`.
 * @param {!Array<string>} live From `liveFunctions`.
 * @return {{added: !Array<string>, removed: !Array<string>}} By name.
 */
function diffExports(declared, live) {
  const declaredSet = new Set(declared);
  const liveSet = new Set(live);
  return {
    added: declared.filter((name) => !liveSet.has(name)),
    removed: live.filter((name) => !declaredSet.has(name)),
  };
}

/**
 * CLI: `node export_diff.js <index.js> <live.json> [--after-deploy]`.
 * @param {!Array<string>} argv Arguments after node + script.
 * @return {number} Exit code.
 */
function main(argv) {
  const [indexPath, livePath, mode] = argv;
  const declared = declaredExports(readFileSync(indexPath, "utf8"));
  const live = liveFunctions(readFileSync(livePath, "utf8"));
  const {added, removed} = diffExports(declared, live);
  console.log(JSON.stringify({
    declared: declared.length, live: live.length, added, removed,
  }));
  if (removed.length > 0) {
    console.error(
        `::error::Prod runs ${removed.join(", ")}, which functions/index.js ` +
        "no longer exports. A non-interactive deploy aborts on the deletion " +
        "prompt. Confirm each name is meant to go, delete them explicitly " +
        "from an owner shell (firebase functions:delete <names> --region " +
        "us-central1), then re-run this workflow.");
    return 1;
  }
  if (mode === "--after-deploy" && added.length > 0) {
    console.error(
        `::error::Declared but not live after the deploy: ${added.join(", ")}`);
    return 1;
  }
  return 0;
}

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}

module.exports = {declaredExports, liveFunctions, diffExports, main};
