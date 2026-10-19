"use strict";

const {execFileSync} = require("child_process");
const {readFileSync, writeFileSync} = require("fs");
const {declaredExports} = require("./export_diff");

/**
 * Storage finalization follows its bucket; other exports use the app region.
 * @param {string} name Export name.
 * @return {string} Expected deployment region.
 */
function regionFor(name) {
  return name === "validateUploadedImage" ? "us-east1" : "us-central1";
}

/**
 * Keeps only non-secret operational fields and reports unhealthy deployments.
 * @param {string} name Expected export.
 * @param {!Object} actual Cloud Functions v2 describe output.
 * @return {!Object} Sanitized verification result.
 */
function inspectConfig(name, actual) {
  const service = actual.serviceConfig || {};
  const issues = [];
  if (actual.state !== "ACTIVE") issues.push("function-not-active");
  if (actual.buildConfig?.runtime !== "nodejs24") {
    issues.push("unexpected-runtime");
  }
  if (String(actual.name || "").split("/").pop() !== name) {
    issues.push("unexpected-name");
  }
  if (!String(actual.name || "").includes(`/locations/${regionFor(name)}/`)) {
    issues.push("unexpected-region");
  }
  if (name === "waveUpsertCustomer") {
    if (service.maxInstanceRequestConcurrency !== 1) {
      issues.push("wave-concurrency-must-be-one");
    }
    if (service.maxInstanceCount !== 2) issues.push("wave-instance-limit");
    if (service.timeoutSeconds !== 300) issues.push("wave-timeout");
    if (actual.eventTrigger?.retryPolicy !== "RETRY_POLICY_RETRY") {
      issues.push("wave-retry-disabled");
    }
  }
  return {name, state: actual.state || "UNKNOWN",
    region: regionFor(name),
    runtime: actual.buildConfig?.runtime || null,
    concurrency: service.maxInstanceRequestConcurrency ?? null,
    maxInstances: service.maxInstanceCount ?? null,
    timeoutSeconds: service.timeoutSeconds ?? null, issues};
}

/**
 * Verifies every export and writes sanitized evidence even on failure.
 * @param {!Array<string>} argv Index path, project, output path.
 * @param {function(string): !Object=} describe Injectable metadata reader.
 * @return {number} Exit status.
 */
function main(argv, describe) {
  const [index, project, output, sourceSha, runId] = argv;
  if (!index || !project || !output) {
    throw new Error("Expected index path, project and output path");
  }
  const read = describe || ((name) => JSON.parse(execFileSync("gcloud", [
    "functions", "describe", name, "--gen2", `--region=${regionFor(name)}`,
    `--project=${project}`, "--format=json",
  ], {encoding: "utf8", timeout: 20000,
    stdio: ["ignore", "pipe", "pipe"]})));
  const declared = declaredExports(readFileSync(index, "utf8"));
  const report = {project, sourceSha, runId: runId ? Number(runId) : null,
    expectedCount: declared.length, complete: false, results: []};
  const save = () => writeFileSync(output, JSON.stringify(report, null, 2) + "\n");
  save();
  for (const name of declared) {
    try {
      report.results.push(inspectConfig(name, read(name)));
    } catch (_) {
      report.results.push({name, issues: ["metadata-read-failed"]});
    }
    save();
  }
  report.complete = true;
  save();
  const failures = report.results.filter((result) => result.issues.length > 0);
  if (failures.length) {
    console.error(`::error::Configuration drift in ${failures.length} exports`);
  }
  return failures.length ? 1 : 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));
module.exports = {inspectConfig, main, regionFor};
