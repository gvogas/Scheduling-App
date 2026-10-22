"use strict";

const {execFileSync} = require("child_process");
const {readFileSync, writeFileSync, mkdirSync} = require("fs");
const {dirname} = require("path");

/**
 * Selects the latest verified functions release, including failed log-PR runs.
 * @param {!Object} bootstrap Reviewed initial deployment provenance.
 * @param {!Array<!Object>} runs Completed main deployment runs.
 * @param {function(number): !Array<!Object>} jobs Fetches a run's jobs.
 * @param {function(!Object): !Object} artifact Fetches sanitized verification.
 * @return {!Object} Verified source sha and run id.
 */
function resolveBaseline(bootstrap, runs, jobs, artifact) {
  if (bootstrap.project !== "schedulingapp-88727") {
    throw new Error("Unexpected bootstrap project");
  }
  const candidates = runs.map((run, index) => {
    const deploy = jobs(run.id).find((job) =>
      job.name === "Deploy to production");
    const time = Date.parse(deploy?.completed_at || run.updated_at || "") ||
      -index;
    return {run, deploy, time};
  }).filter((entry) => entry.deploy && entry.deploy.conclusion !== "skipped")
      .sort((a, b) => b.time - a.time);
  for (const {run, deploy} of candidates) {
    const steps = new Map((deploy.steps || []).map((step) =>
      [step.name, step.conclusion]));
    const names = steps.get("Verify by name");
    const attempted = steps.get("Deploy");
    if (!attempted || attempted === "skipped") continue;
    if (names === "skipped" && steps.get(
        "Export diff (deletions abort non-interactively)") === "skipped") {
      continue;
    }
    if (attempted !== "success" || names !== "success") {
      const reconciled = (bootstrap.reconciledAttempts || []).some((entry) =>
        entry.runId === run.id && entry.runAttempt === run.run_attempt &&
        entry.completedAt === deploy.completed_at &&
        entry.headSha === run.head_sha && entry.baselineSha === bootstrap.sha &&
        entry.outcome === "no-functions-updated");
      if (reconciled) continue;
      throw new Error("An unverified functions attempt needs reconciliation");
    }
    if (steps.get("Verify deployed health and critical configuration") ===
        "success") {
      const report = artifact(run);
      if (report.project !== bootstrap.project || report.runId !== run.id ||
          report.complete !== true ||
          report.expectedCount !== report.results?.length ||
          !/^[a-f0-9]{40}$/.test(report.sourceSha || "") ||
          !Array.isArray(report.results) || report.results.length === 0 ||
          report.results.some((row) => row.state !== "ACTIVE" ||
            row.runtime !== "nodejs24" || !Array.isArray(row.issues) ||
            row.issues.length !== 0)) {
        throw new Error("Invalid deployment verification artifact");
      }
      return {sha: report.sourceSha, runId: run.id};
    }
    if (run.id === bootstrap.runId && run.head_sha === bootstrap.sha &&
        /^[a-f0-9]{40}$/.test(bootstrap.sha)) {
      return {sha: bootstrap.sha, runId: run.id};
    }
    throw new Error("A newer deployment lacks verified configuration evidence");
  }
  throw new Error("No verified functions baseline; bounded history exhausted");
}

/**
 * Calls GitHub without printing tokens or raw diagnostic output.
 * @param {string} endpoint GitHub API path.
 * @param {boolean=} binary Whether to return a zip buffer.
 * @return {*} Parsed JSON or binary content.
 */
function github(endpoint, binary = false) {
  const output = execFileSync("gh", ["api", endpoint], {
    encoding: binary ? undefined : "utf8", maxBuffer: 4 * 1024 * 1024,
    timeout: 30000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return binary ? output : JSON.parse(output);
}

/**
 * Reads exactly the expected JSON member from a bounded workflow artifact.
 * @param {string} repository GitHub owner/repository.
 * @param {!Object} run Workflow run metadata.
 * @return {!Object} Sanitized deployment report.
 */
function readArtifact(repository, run) {
  const listed = github(`repos/${repository}/actions/runs/${run.id}/artifacts`);
  const artifact = (listed.artifacts || []).find((entry) =>
    entry.name === `deployed-configuration-${run.id}` && !entry.expired);
  if (!artifact || artifact.size_in_bytes > 2 * 1024 * 1024) {
    throw new Error("Missing, expired or oversized deployment artifact");
  }
  const zip = github(`repos/${repository}/actions/artifacts/${artifact.id}/zip`,
      true);
  const source = "import io,json,sys,zipfile; " +
    "z=zipfile.ZipFile(io.BytesIO(sys.stdin.buffer.read())); " +
    "i=z.getinfo('deployed-config.json'); " +
    "assert i.file_size <= 2097152; " +
    "print(json.dumps(json.loads(z.read(i))))";
  return JSON.parse(execFileSync("python3", ["-c", source], {
    input: zip, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"],
  }));
}

/**
 * Resolves a protected workflow baseline, or records a successful new one.
 * @param {!Array<string>} argv Mode and paths/repository or release metadata.
 * @return {number} Exit status.
 */
function main(argv) {
  const [mode, file, repository, sha, runId] = argv;
  if (mode === "record") {
    if (!/^[a-f0-9]{40}$/.test(sha || "") || !/^\d+$/.test(runId || "")) {
      throw new Error("Invalid verified release metadata");
    }
    mkdirSync(dirname(file), {recursive: true});
    writeFileSync(file, JSON.stringify({project: "schedulingapp-88727",
      sha, runId: Number(runId), verification: "healthy-configuration",
      evidence: `https://github.com/${repository}/actions/runs/${runId}`,
    }, null, 2) + "\n");
    return 0;
  }
  if (mode !== "resolve" || !/^[\w.-]+\/[\w.-]+$/.test(repository || "")) {
    throw new Error("Expected resolve file owner/repository");
  }
  const bootstrap = JSON.parse(readFileSync(file, "utf8"));
  const runs = github(`repos/${repository}/actions/workflows/deploy.yml/runs?` +
    "status=completed&branch=main&per_page=30").workflow_runs;
  const baseline = resolveBaseline(bootstrap, runs,
      (id) => github(`repos/${repository}/actions/runs/${id}/jobs?per_page=100`)
          .jobs,
      (run) => readArtifact(repository, run));
  console.log(baseline.sha);
  return 0;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (_) {
    console.error("::error::Cannot verify deployment baseline; reconcile " +
      "the latest functions attempt and its sanitized verification artifact");
    process.exitCode = 1;
  }
}
module.exports = {resolveBaseline, main};
