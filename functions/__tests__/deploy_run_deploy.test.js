"use strict";

const {spawnSync} = require("child_process");
const path = require("path");

const SCRIPT = path.join(__dirname, "..", "..", "tools", "deploy",
    "run_deploy.sh");
const hasBash = spawnSync("bash", ["--version"]).status === 0;

/**
 * Runs the script with `node -p` standing in for the firebase binary.
 * @param {string} targets The target list.
 * @param {!Object} env Extra environment.
 * @return {!Object} The spawnSync result.
 */
function run(targets, env = {}) {
  return spawnSync("bash", [SCRIPT, targets], {
    encoding: "utf8",
    env: {
      ...process.env,
      PROJECT_ID: "schedulingapp-88727",
      FIREBASE_BIN: process.execPath,
      ...env,
    },
  });
}

(hasBash ? describe : describe.skip)("tools/deploy/run_deploy.sh", () => {
  test("executes the checked array: project, non-interactive, targets", () => {
    const result = run("functions,storage");
    expect(result.stdout).toContain(
        "+ firebase deploy --project schedulingapp-88727 " +
        "--non-interactive --only functions,storage");
  });

  test("a target list carrying --force is refused", () => {
    const result = run("functions --force");
    expect(result.status).toBe(1);
    expect(result.stdout).toContain("--force");
  });

  test("another project is refused", () => {
    const result = run("functions", {PROJECT_ID: "someone-else"});
    expect(result.status).toBe(1);
    expect(result.stdout).toContain("does not name --project");
  });
});
