"use strict";

const {execFileSync} = require("child_process");
const {writeFileSync} = require("fs");

const RULES = ["firebaserules.releases.create",
  "firebaserules.rulesets.create", "firebaserules.releases.update"];
const FUNCTIONS = ["cloudfunctions.functions.list",
  "cloudfunctions.functions.create", "cloudfunctions.functions.get",
  "cloudfunctions.functions.update", "cloudfunctions.functions.delete",
  "cloudfunctions.operations.get", "cloudfunctions.functions.setIamPolicy"];
const INDEXES = ["datastore.indexes.list", "datastore.indexes.create",
  "datastore.indexes.update", "datastore.indexes.delete"];

/**
 * Read-only requests for the selected target, based on the pinned CLI.
 * @param {string} project Firebase project id.
 * @param {string} target Deploy target.
 * @return {!Object} Required permissions and API requests.
 */
function plan(project, target) {
  if (!/^[a-z][a-z0-9-]{4,62}$/.test(project) ||
      !["all", "functions", "storage", "firestore:rules",
        "firestore:indexes"].includes(target)) {
    throw new Error("Invalid deployment preflight scope");
  }
  const all = target === "all";
  const permissions = new Set();
  const requests = [];
  if (all || target === "functions") {
    FUNCTIONS.forEach((permission) => permissions.add(permission));
    for (const region of ["us-central1", "us-east1"]) {
      requests.push({name: `functions-list-${region}`, permission:
        "cloudfunctions.functions.list", url:
          "https://cloudfunctions.googleapis.com/v2/projects/" +
          `${project}/locations/${region}/functions?pageSize=1`});
    }
  }
  if (all || target === "firestore:indexes") {
    INDEXES.forEach((permission) => permissions.add(permission));
    requests.push({name: "indexes-list", permission: "datastore.indexes.list",
      url: "https://firestore.googleapis.com/v1/projects/" +
      `${project}/databases/(default)/collectionGroups/-/indexes?pageSize=1`});
  }
  if (all || target === "storage" || target === "firestore:rules") {
    RULES.forEach((permission) => permissions.add(permission));
  }
  if (all || target === "storage") {
    requests.push({name: "storage-discovery",
      permission: "firebasestorage.defaultBucket.get",
      url: `https://firebasestorage.googleapis.com/v1alpha/projects/${project}` +
      "/defaultBucket"});
  }
  return {permissions: [...permissions], requests};
}

/**
 * Checks permissions without modifying backend resources or IAM.
 * @param {string} project Project id.
 * @param {string} target Selected target.
 * @param {string} token Ephemeral access token, never written or logged.
 * @param {function(string, !Object): !Promise<!Object>=} request Fetch adapter.
 * @return {!Promise<!Object>} Sanitized results only.
 */
async function preflight(project, target, token, request = fetch) {
  const scope = plan(project, target);
  const headers = {"Authorization": `Bearer ${token}`,
    "Content-Type": "application/json", "x-goog-user-project": project};
  const checks = [];
  const options = {headers, redirect: "error",
    signal: AbortSignal.timeout(15000)};
  try {
    const response = await request("https://cloudresourcemanager.googleapis.com" +
      `/v1/projects/${project}:testIamPermissions`, {...options, method: "POST",
      body: JSON.stringify({permissions: scope.permissions})});
    const granted = response.ok ?
      (await response.json()).permissions || [] : [];
    checks.push({name: "target-permissions", ok: response.ok &&
      scope.permissions.every((permission) => granted.includes(permission)),
    status: response.status, missing: scope.permissions.filter((permission) =>
      !granted.includes(permission))});
  } catch (_) {
    checks.push({name: "target-permissions", ok: false,
      error: "permission-check-unavailable"});
  }
  for (const check of scope.requests) {
    try {
      const response = await request(check.url, {...options, method: "GET"});
      checks.push({name: check.name, permission: check.permission,
        ok: response.ok, status: response.status});
      await response.body?.cancel();
    } catch (_) {
      checks.push({name: check.name, permission: check.permission,
        ok: false, error: "read-check-unavailable"});
    }
  }
  return {project, target, checks};
}

/**
 * Runs using the current deployment identity, optionally impersonated locally.
 * @param {!Array<string>} argv Target, project, report path, optional identity.
 * @return {!Promise<number>} Exit status.
 */
async function main(argv) {
  const [target, project, output, identity] = argv;
  plan(project, target);
  let report;
  try {
    const args = ["auth", "print-access-token"];
    if (identity) {
      if (!/^[\w.-]+@[\w.-]+\.iam\.gserviceaccount\.com$/.test(identity)) {
        throw new Error("Invalid deployment identity");
      }
      args.push(`--impersonate-service-account=${identity}`);
    }
    const windows = process.platform === "win32";
    const command = windows ? "powershell.exe" : "gcloud";
    const parameters = windows ? ["-NoProfile", "-NonInteractive", "-Command",
      "& gcloud " + args.map((arg) => `'${arg}'`).join(" ") +
        "; exit $LASTEXITCODE"] : args;
    const token = execFileSync(command, parameters, {encoding: "utf8",
      windowsHide: true, timeout: 20000,
      stdio: ["ignore", "pipe", "pipe"]}).trim();
    report = await preflight(project, target, token);
  } catch (error) {
    const denied = /iam.serviceAccounts.getAccessToken|Failed to impersonate/
        .test(String(error.stderr || ""));
    report = {project, target, checks: [{name: "authentication", ok: false,
      error: denied ? "impersonation-unavailable" :
        "deployment-token-unavailable"}]};
  }
  writeFileSync(output, JSON.stringify(report, null, 2) + "\n");
  const passed = report.checks.every((check) => check.ok);
  if (!passed) {
    console.error("::error::Target-specific deployment preflight " +
    "failed; inspect the sanitized permission report before changing IAM");
  }
  return passed ? 0 : 1;
}

if (require.main === module) {
  main(process.argv.slice(2)).then((status) => {
    process.exitCode = status;
  }).catch(() => {
    console.error("::error::Invalid deployment preflight invocation");
    process.exitCode = 1;
  });
}
module.exports = {plan, preflight, main};
