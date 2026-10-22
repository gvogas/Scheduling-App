"use strict";

const {resolveBaseline} = require("../scripts/deploy/baseline");

const sha = "a".repeat(40);
const nextSha = "b".repeat(40);
const bootstrap = {project: "schedulingapp-88727", sha, runId: 1};
const steps = (values) => Object.entries(values).map(([name, conclusion]) =>
  ({name, conclusion}));
const deploy = (values, extra = {}) => [{name: "Deploy to production",
  conclusion: "success", steps: steps({"Deploy": "success",
    "Export diff (deletions abort non-interactively)": "success",
    "Verify by name": "success", ...values}), ...extra}];
const report = {project: bootstrap.project, sourceSha: nextSha, runId: 2,
  complete: true, expectedCount: 1,
  results: [{state: "ACTIVE", runtime: "nodejs24", issues: []}]};

test("rules-only releases do not replace the functions source baseline", () => {
  const runs = [{id: 2}, {id: 1, head_sha: sha}];
  const jobs = (id) => id === 2 ? deploy({"Verify by name": "skipped",
    "Export diff (deletions abort non-interactively)": "skipped"}) : deploy({});
  expect(resolveBaseline(bootstrap, runs, jobs, () => null))
      .toEqual({sha, runId: 1});
});

test("verified source survives a failed log PR job", () => {
  expect(resolveBaseline(bootstrap, [{id: 2, conclusion: "failure"}],
      () => deploy({"Verify deployed health and critical configuration":
        "success"}), () => report)).toEqual({sha: nextSha, runId: 2});
});

test.each(["failure", "cancelled"])("partial %s blocks an older baseline",
    (conclusion) => {
      expect(() => resolveBaseline(bootstrap, [{id: 2}, {id: 1, head_sha: sha}],
          (id) => id === 2 ? deploy({"Deploy": conclusion,
            "Verify by name": "skipped"}) : deploy({}), () => null))
          .toThrow(/unverified functions attempt/);
    });

test.each([
  {...report, project: "different"}, {...report, runId: 99},
  {...report, sourceSha: "short"}, {...report, results: []},
  {...report, results: [{state: "ACTIVE", runtime: "nodejs24",
    issues: ["drift"]}]},
])("invalid verification evidence fails closed: %j", (value) => {
  expect(() => resolveBaseline(bootstrap, [{id: 2}], () => deploy({
    "Verify deployed health and critical configuration": "success",
  }), () => value)).toThrow(/Invalid deployment verification/);
});

test("actual completion order wins on historical reruns", () => {
  const runs = [{id: 2}, {id: 1, head_sha: sha}];
  const jobs = (id) => id === 2 ? deploy({
    "Verify deployed health and critical configuration": "success",
  }, {completed_at: "2026-10-18T10:00:00Z"}) :
    deploy({}, {completed_at: "2026-10-19T10:00:00Z"});
  expect(resolveBaseline(bootstrap, runs, jobs, () => report))
      .toEqual({sha, runId: 1});
});

test("unknown legacy release cannot fall back silently", () => {
  expect(() => resolveBaseline(bootstrap, [{id: 2}], () => deploy({}),
      () => null)).toThrow(/newer deployment/);
  expect(() => resolveBaseline(bootstrap, [], () => [], () => null))
      .toThrow(/No verified functions baseline/);
});

test("reviewed no-change reconciliation never applies to a rerun", () => {
  const failed = {id: 2, head_sha: nextSha, run_attempt: 1};
  const completedAt = "2026-10-12T13:46:03Z";
  const reviewed = {...bootstrap, reconciledAttempts: [{runId: 2,
    runAttempt: 1, completedAt, headSha: nextSha, baselineSha: sha,
    outcome: "no-functions-updated"}]};
  const jobs = (id) => id === 2 ? deploy({"Deploy": "failure",
    "Verify by name": "skipped"}, {completed_at: completedAt}) : deploy({});
  expect(resolveBaseline(reviewed, [failed, {id: 1, head_sha: sha}],
      jobs, () => null)).toEqual({sha, runId: 1});
  expect(() => resolveBaseline(reviewed, [{...failed, run_attempt: 2},
    {id: 1, head_sha: sha}], jobs, () => null)).toThrow(/unverified functions/);
});
