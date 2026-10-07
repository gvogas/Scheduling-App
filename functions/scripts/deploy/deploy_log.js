"use strict";

// Reads and appends the Deploy log table in docs/DEPLOYMENT.md.

const {readFileSync, writeFileSync} = require("fs");

const ROW = /^\| \d{4}-\d{2}-\d{2}/;

/**
 * Line range of the Deploy log table: header line to its last row.
 * @param {!Array<string>} lines The document split by line.
 * @return {?{start: number, end: number}} Inclusive indexes, or null.
 */
function tableRange(lines) {
  const heading = lines.findIndex((l) => l.trim() === "## Deploy log");
  if (heading < 0) return null;
  const start = lines.findIndex((l, i) => i > heading &&
    l.startsWith("| Date |"));
  if (start < 0) return null;
  // The real log has blank lines between rows, so run to the next heading.
  let end = start;
  for (let i = start + 1; i < lines.length && !lines[i].startsWith("#"); i++) {
    if (lines[i].startsWith("|")) end = i;
  }
  return {start, end};
}

/**
 * The commit of the newest Deploy log row that names one.
 * @param {string} markdown The runbook.
 * @return {?string} A short or full sha, or null.
 */
function lastDeployedSha(markdown) {
  const lines = markdown.split("\n");
  const range = tableRange(lines);
  if (!range) return null;
  for (let i = range.end; i > range.start; i--) {
    if (!ROW.test(lines[i])) continue;
    const match = (lines[i].split("|")[2] || "").match(/`([0-9a-f]{7,40})`/);
    if (match) return match[1];
  }
  return null;
}

/**
 * Inserts `row` after the Deploy log table's last row.
 * @param {string} markdown The runbook.
 * @param {string} row A formatted table row.
 * @return {string} The updated runbook.
 */
function appendRow(markdown, row) {
  const lines = markdown.split("\n");
  const range = tableRange(lines);
  if (!range) throw new Error("Deploy log table not found");
  lines.splice(range.end + 1, 0, row);
  return lines.join("\n");
}

/**
 * One Deploy log row for a workflow run.
 * @param {{date: string, sha: string, targets: string, count: string,
 *     runUrl: string}} entry What was deployed.
 * @return {string} The row.
 */
function formatRow({date, sha, targets, count, runUrl}) {
  return `| ${date} | \`${sha.slice(0, 8)}\` | ${targets} | ${count} | ` +
    `Deploy workflow [run](${runUrl}). Notes: what changed, prompts seen, ` +
    "and what still stands. |";
}

/**
 * Reads `--key=value` options.
 * @param {!Array<string>} argv Arguments.
 * @return {!Object<string, string>} Parsed options.
 */
function options(argv) {
  const out = {};
  for (const arg of argv) {
    const match = arg.match(/^--([a-z-]+)=(.*)$/);
    if (match) out[match[1]] = match[2];
  }
  return out;
}

/**
 * CLI: `last-sha <file>` or `append <file> --date= --sha= --targets=
 * --count= --run-url=`.
 * @param {!Array<string>} argv Arguments after node + script.
 * @return {number} Exit code.
 */
function main(argv) {
  const [command, file, ...rest] = argv;
  if (command === "last-sha") {
    console.log(lastDeployedSha(readFileSync(file, "utf8")) || "");
    return 0;
  }
  if (command === "append") {
    const o = options(rest);
    writeFileSync(file, appendRow(readFileSync(file, "utf8"), formatRow({
      date: o.date, sha: o.sha, targets: o.targets, count: o.count,
      runUrl: o["run-url"],
    })));
    return 0;
  }
  console.error("usage: deploy_log.js last-sha|append <file> [options]");
  return 1;
}

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}

module.exports = {lastDeployedSha, appendRow, formatRow, main};
