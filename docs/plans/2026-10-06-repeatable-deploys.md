# Repeatable Deploys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backend deploys run from one approved GitHub Actions workflow that encodes the runbook's ordering and safety rules, and every one-off prod script runs through one runner that refuses a stale dry-run count.

**Architecture:** A `workflow_dispatch`-only `deploy.yml` reuses `ci.yml` (made callable) for lint + tests, authenticates with Workload Identity Federation, runs three small pre-flight checkers (export diff, allowlist superset, TTL drift), deploys indexes first and waits for `READY` when they are in scope, deploys the rest without `--force`, then opens a PR against `dev` that appends the deploy-log row. The checkers live in `functions/scripts/deploy/` so they are linted and tested by the existing functions jest suite and are excluded from the functions upload by `firebase.json`'s `scripts/**` ignore. A separate `functions/scripts/run.js` wraps the 17 existing scripts without changing them.

**Tech Stack:** GitHub Actions, `google-github-actions/auth@v2` + `setup-gcloud@v2`, `firebase-tools@15.25.1` (the pin CI already uses), `peter-evans/create-pull-request@v7`, Node 24, Jest 29.

## Decisions (already taken — do not reopen)

- `.github/workflows/deploy.yml`, **`workflow_dispatch` only, never on push.** Inputs: `ref` (default `main`) and `targets` (choice: `functions`, `firestore:rules`, `firestore:indexes`, `storage`, `all`).
- It runs the **same lint + tests as CI** first (by calling `ci.yml` through `workflow_call`), then `firebase deploy --only <targets> --project schedulingapp-88727 --non-interactive`.
- **It never passes `--force`.** A guard step fails the job if any computed deploy command contains `--force`.
- The deploy job runs in a GitHub **`production` environment with required reviewer approval**.
- **Auth is Workload Identity Federation**, no JSON key. One-time setup is a **manual owner task** (Task 1).
- Every runbook rule a workflow can encode is encoded; the rest are printed as a checklist in the job summary.
- The workflow **records the deploy-log row by opening a PR against `dev`**, never by pushing.
- **One runner for one-off scripts**: `functions/scripts/run.js <name> [--dry-run|--live] [args]`. Dry-run is the default. `--live` re-runs the dry-run, prints its count, and requires that count typed back (or `--yes-count=<n>` matching it). It wraps the scripts; it does not change them.
- `docs/DEPLOYMENT.md`, the `/deploy` skill and `/script` command are updated to point at the workflow and runner, and the runbook sections the workflow now encodes are shrunk (Task 9).

## File map

| Path | Status | Responsibility |
|---|---|---|
| `functions/scripts/deploy/export_diff.js` | create | `index.js` exports vs live `functions:list --json`; fails on any deletion |
| `functions/scripts/deploy/allowlist_diff.js` | create | Every callable's `assertPayloadShape` key set at the last-deployed sha vs HEAD; fails on any removed key |
| `functions/scripts/deploy/deploy_log.js` | create | Reads the last deployed sha out of the Deploy log; appends a row |
| `functions/scripts/_runner.js` | create | Pure runner core: arg parsing, the count-confirm gate, injected spawn/prompt |
| `functions/scripts/run.js` | create | The registry of all 17 scripts + the real spawn/prompt + `main` |
| `functions/__tests__/deploy_export_diff.test.js` | create | |
| `functions/__tests__/deploy_allowlist_diff.test.js` | create | |
| `functions/__tests__/deploy_log.test.js` | create | |
| `functions/__tests__/scripts_runner.test.js` | create | |
| `functions/__tests__/scripts_run_registry.test.js` | create | Registry covers every script; every count pattern matches its script's real summary line |
| `.github/workflows/ci.yml` | modify | Add `workflow_call` with a `ref` input; both checkouts use it |
| `.github/workflows/deploy.yml` | create | The deploy workflow |
| `docs/DEPLOYMENT.md` | modify | §5 / per-release checklist / Deploy log intro point at the workflow |
| `.claude/skills/deploy/SKILL.md` | modify | Workflow first; local CLI becomes the fallback |
| `.claude/commands/script.md` | modify | Commands go through `run.js` |
| `CLAUDE.md` | modify | The Cloud Functions "Deploy:" paragraph names the workflow |

### How the 17 existing scripts map into the runner

| Script | Runner kind | Dry-run count read from |
|---|---|---|
| `audit-wave-contract.js` | `read` (no gate, `--live` refused) | — |
| `count-multi-day-appointments.js` | `read` | — |
| `seed-emulator.js` | `emulator` (refused unless `FIRESTORE_EMULATOR_HOST` is set) | — |
| `backfill-client-phone-from-name.js` | `retired` (always refused — its header says never run it again) | — |
| `backfill-client-address-street.js` | `write` | `clients: N scanned, X reduced` |
| `backfill-client-buildings.js` | `write` | `projectionsChanged: X` |
| `backfill-client-name-digits.js` | `write` | `clients: N scanned, X reformatted` |
| `backfill-client-name-with-phone.js` | `write` | `clients: N scanned, X renamed` |
| `backfill-client-phone-formatting.js` | `write` | `clients: N scanned, X patched` |
| `backfill-client-sort-fields.js` | `write` | `clients: N scanned, X sort rows patched` |
| `backfill-clients-archived.js` | `write` | `clients: X patched` |
| `backfill-search-tokens.js` | `write` | sum of both `X token rows patched` lines |
| `backfill-wave-blocked.js` | `write` | `clients: N scanned, X verdict rows patched` |
| `backfill.js` | `write` | `"updated"` + `"created"` (+ `"orphansFound"` with `--prune-orphans`) from its JSON stats |
| `drain-wave-queue.js` | `write` | `queued jobs: X` |
| `recount-client-jobs.js` | `write` | `clients: N scanned, X job counts patched` |
| `repair-client-address-mojibake.js` | `write` | `clients: N scanned, X repaired` |

Every `write` script already accepts `--dry-run` exactly (through `_flags.js`), so the runner adds `--dry-run` for the preview and omits it for the live run; everything else the operator types (`--verbose`, `--since=`, `--rate=`, `--prune-orphans`) passes through to **both** runs unchanged.

---

### Task 1: One-time owner setup (MANUAL — owner only, not an agent)

**This task is done by the project owner in a shell authenticated as a project Owner, and in the GitHub UI. An agent must not attempt it; it only checks it off when the owner confirms.**

- [ ] **Step 1: Create the deploy service account, pool and provider**

```bash
PROJECT_ID=schedulingapp-88727
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
REPO=gvogas/Scheduling-App
SA=github-deploy@${PROJECT_ID}.iam.gserviceaccount.com

gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project "$PROJECT_ID"

gcloud iam service-accounts create github-deploy \
  --project "$PROJECT_ID" --display-name "GitHub Actions backend deploy"

gcloud iam workload-identity-pools create github \
  --project "$PROJECT_ID" --location global --display-name "GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc scheduling-app \
  --project "$PROJECT_ID" --location global --workload-identity-pool github \
  --display-name "Scheduling-App repo" \
  --issuer-uri "https://token.actions.githubusercontent.com" \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment" \
  --attribute-condition "assertion.repository=='${REPO}' && assertion.environment=='production' && assertion.ref=='refs/heads/main' && assertion.event_name=='workflow_dispatch' && assertion.workflow_ref.startsWith('${REPO}/.github/workflows/deploy.yml@')"

gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --project "$PROJECT_ID" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"
```

The attribute condition means only a `workflow_dispatch` run of `deploy.yml` on `main`, in a job using the `production` environment of this repo, can mint a token, so the `verify` and `record` jobs cannot reach GCP even by mistake, and the in-workflow `gate` job is not the only branch check.

- [ ] **Step 2: Grant the deploy roles**

```bash
for role in \
  roles/firebase.admin \
  roles/cloudfunctions.admin \
  roles/run.admin \
  roles/iam.serviceAccountUser \
  roles/artifactregistry.admin \
  roles/cloudscheduler.admin \
  roles/eventarc.admin \
  roles/cloudbuild.builds.editor \
  roles/secretmanager.viewer \
  roles/datastore.indexAdmin \
  roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:${SA}" --role "$role" --condition=None
done
```

If the first run (Task 8) fails naming a missing permission, grant exactly that role and nothing broader. `secretmanager.viewer` is enough while the six secrets' accessor bindings already exist (they do — every prior deploy created them); a deploy that binds a NEW secret needs `roles/secretmanager.admin` for that one run.

- [ ] **Step 3: Print the two values the workflow needs**

```bash
echo "GCP_WIF_PROVIDER=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/scheduling-app"
echo "GCP_DEPLOY_SA=${SA}"
```

- [ ] **Step 4: GitHub settings (UI)**

1. Settings → Environments → New environment `production` → **Required reviewers**: the owner. Leave "Prevent self-review" OFF (one-person team). **Deployment branches and tags**: Selected branches, `main` only.
2. Settings → Secrets and variables → Actions → **Variables** tab → add `GCP_WIF_PROVIDER` and `GCP_DEPLOY_SA` with the Step 3 values. (Variables, not secrets — neither is sensitive, and the provider is useless outside the attribute condition.)
3. Settings → Actions → General → Workflow permissions → tick **Allow GitHub Actions to create and approve pull requests** (the `record` job needs it).

- [ ] **Step 5: Owner confirms in the session that Steps 1–4 are done.** No commit.

---

### Task 2: Export diff checker

**Files:**
- Create: `functions/scripts/deploy/export_diff.js`
- Test: `functions/__tests__/deploy_export_diff.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

const {
  declaredExports,
  liveFunctions,
  diffExports,
} = require("../scripts/deploy/export_diff");

describe("declaredExports", () => {
  test("reads every exports.<name> = line, sorted", () => {
    const source = [
      "const a = require(\"./a\");",
      "exports.zeta = a.zeta;",
      "exports.alpha =",
      "  a.alpha;",
      "// exports.commented = nope;",
    ].join("\n");
    expect(declaredExports(source)).toEqual(["alpha", "zeta"]);
  });
});

describe("liveFunctions", () => {
  test("reads ids out of functions:list --json", () => {
    const json = JSON.stringify({
      status: "success",
      result: [{id: "b", region: "us-central1"}, {id: "a"}],
    });
    expect(liveFunctions(json)).toEqual(["a", "b"]);
  });

  test("falls back to the last segment of a resource name", () => {
    const json = JSON.stringify({result: [
      {name: "projects/p/locations/us-central1/functions/deleteAccount"},
    ]});
    expect(liveFunctions(json)).toEqual(["deleteAccount"]);
  });

  test("treats a missing result as no functions", () => {
    expect(liveFunctions("{\"status\":\"success\"}")).toEqual([]);
  });
});

describe("diffExports", () => {
  test("names additions and deletions by NAME, not count", () => {
    // Same count, different set: the 2026-08-14 25 -> 25 swap.
    expect(diffExports(["a", "b", "new"], ["a", "b", "old"])).toEqual({
      added: ["new"],
      removed: ["old"],
    });
  });

  test("an identical set diffs to nothing", () => {
    expect(diffExports(["a"], ["a"])).toEqual({added: [], removed: []});
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/deploy_export_diff.test.js`
Expected: FAIL — `Cannot find module '../scripts/deploy/export_diff'`.

- [ ] **Step 3: Implement**

```js
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd functions && npx jest __tests__/deploy_export_diff.test.js && npx eslint scripts/deploy/export_diff.js`
Expected: PASS, no lint output.

- [ ] **Step 5: Commit**

```bash
git add functions/scripts/deploy/export_diff.js functions/__tests__/deploy_export_diff.test.js
git commit -m "Add the deploy export-diff checker"
```

---

### Task 3: Allowlist superset checker

**Files:**
- Create: `functions/scripts/deploy/allowlist_diff.js`
- Test: `functions/__tests__/deploy_allowlist_diff.test.js`

The runbook's §4(a): removing a key from an `assertPayloadShape` allowlist breaks every shipped build that still sends it. Callables here declare the set inline at the guard (`assertAdminCall(req, new Set([...]))`, `assertActiveCall(req, new Set([...]))`, `assertPayloadShape(req.data, new Set([...]))`), owned either by a named `function` or a `const X = onCall(`. The checker keys each set by `<file>#<owner>`.

- [ ] **Step 1: Write the failing test**

```js
"use strict";

const {
  extractAllowlists,
  removedKeys,
} = require("../scripts/deploy/allowlist_diff");

const BASE = `
async function createHandler(req) {
  await assertAdminCall(req, new Set([
    "email",
    "isAdmin", // #compat-1.47.0
  ]));
}
const placesAutocomplete = onCall({}, async (req) => {
  const uid = await assertAdminCall(
      req,
      new Set(["input", "sessionToken"]),
  );
});
const waveBootstrap = onCall({}, async (req) => {
  await assertAdminCall(req, new Set());
});
function deleteAccount(req) {
  assertPayloadShape(req.data, new Set());
}
`;

describe("extractAllowlists", () => {
  test("keys each inline set by its owning function or onCall const", () => {
    const sets = extractAllowlists(BASE);
    expect([...sets.get("createHandler")]).toEqual(["email", "isAdmin"]);
    expect([...sets.get("placesAutocomplete")])
        .toEqual(["input", "sessionToken"]);
    expect([...sets.get("waveBootstrap")]).toEqual([]);
    expect([...sets.get("deleteAccount")]).toEqual([]);
  });
});

describe("removedKeys", () => {
  test("a dropped key is reported", () => {
    const head = BASE.replace("\"isAdmin\", // #compat-1.47.0\n", "");
    expect(removedKeys(extractAllowlists(BASE), extractAllowlists(head)))
        .toEqual({removed: [{owner: "createHandler", key: "isAdmin"}],
          missingOwners: []});
  });

  test("an added key is fine", () => {
    const head = BASE.replace("\"email\",", "\"email\", \"phone\",");
    expect(removedKeys(extractAllowlists(BASE), extractAllowlists(head)))
        .toEqual({removed: [], missingOwners: []});
  });

  test("a vanished owner is reported separately, not as removals", () => {
    const head = BASE.replace("function deleteAccount", "function gone");
    expect(removedKeys(extractAllowlists(BASE), extractAllowlists(head)))
        .toEqual({removed: [], missingOwners: ["deleteAccount"]});
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/deploy_allowlist_diff.test.js`
Expected: FAIL — `Cannot find module`.

- [ ] **Step 3: Implement**

```js
"use strict";

// Fails a deploy that would narrow any callable's payload allowlist.

const {execFileSync} = require("child_process");
const {readFileSync} = require("fs");

const GUARD = new RegExp(
    "(?:assertAdminCall|assertActiveCall|assertPayloadShape)\\(\\s*" +
    "req(?:\\.data)?\\s*,\\s*new Set\\((?:\\[([\\s\\S]*?)\\])?\\)", "g");
const OWNER = /(?:function\s+(\w+)\s*\(|const\s+(\w+)\s*=\s*onCall\()/g;

/**
 * Inline allowlists in one source file, keyed by the owning handler.
 * @param {string} source A functions module.
 * @return {!Map<string, !Set<string>>} Owner name to its allowed keys.
 */
function extractAllowlists(source) {
  const owners = [...source.matchAll(OWNER)]
      .map((m) => ({index: m.index, name: m[1] || m[2]}));
  const result = new Map();
  for (const match of source.matchAll(GUARD)) {
    const owner = owners.filter((o) => o.index < match.index).pop();
    const name = owner ? owner.name : "(module)";
    const keys = result.get(name) || new Set();
    for (const key of (match[1] || "").matchAll(/"([^"]+)"/g)) {
      keys.add(key[1]);
    }
    result.set(name, keys);
  }
  return result;
}

/**
 * Keys present at the base and gone at HEAD.
 * @param {!Map<string, !Set<string>>} base Allowlists at the deployed sha.
 * @param {!Map<string, !Set<string>>} head Allowlists in the working tree.
 * @return {{removed: !Array<{owner: string, key: string}>,
 *     missingOwners: !Array<string>}} What narrowed, and owners not found.
 */
function removedKeys(base, head) {
  const removed = [];
  const missingOwners = [];
  for (const [owner, keys] of base) {
    const now = head.get(owner);
    if (!now) {
      missingOwners.push(owner);
      continue;
    }
    for (const key of keys) {
      if (!now.has(key)) removed.push({owner, key});
    }
  }
  return {removed, missingOwners};
}

/**
 * The functions source files to compare, relative to `functions/`.
 * @return {!Array<string>} Paths.
 */
function sourceFiles() {
  return execFileSync("git", ["ls-files", "*.js"], {encoding: "utf8"})
      .split("\n")
      .filter((f) => f && !/^(node_modules|__tests__|scripts|coverage)\//
          .test(f));
}

/**
 * CLI: run from `functions/`, `node scripts/deploy/allowlist_diff.js <sha>`.
 * @param {!Array<string>} argv Arguments after node + script.
 * @return {number} Exit code.
 */
function main(argv) {
  const [baseSha] = argv;
  let failed = false;
  for (const file of sourceFiles()) {
    let baseSource;
    try {
      baseSource = execFileSync("git", ["show", `${baseSha}:./${file}`],
          {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]});
    } catch (err) {
      continue;
    }
    const {removed, missingOwners} = removedKeys(
        extractAllowlists(baseSource),
        extractAllowlists(readFileSync(file, "utf8")));
    for (const {owner, key} of removed) {
      failed = true;
      console.error(
          `::error file=functions/${file}::${owner} no longer accepts ` +
          `"${key}". A shipped build that still sends it gets ` +
          "unexpected-field. Keep it accepted-and-ignored with a " +
          "#compat-<version> tag (.claude/rules/security.md).");
    }
    for (const owner of missingOwners) {
      console.log(
          `::warning file=functions/${file}::${owner} had an allowlist at ` +
          `${baseSha} and is not found now — renamed or deleted? Check it ` +
          "by hand.");
    }
  }
  return failed ? 1 : 0;
}

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}

module.exports = {extractAllowlists, removedKeys, main};
```

- [ ] **Step 4: Run it to verify it passes, then against the real tree**

Run: `cd functions && npx jest __tests__/deploy_allowlist_diff.test.js && npx eslint scripts/deploy/allowlist_diff.js && node scripts/deploy/allowlist_diff.js abbe5e3f; echo "exit=$?"`
Expected: PASS, no lint output, `exit=0` (no allowlist has narrowed since the last logged deploy `abbe5e3f`).

- [ ] **Step 5: Commit**

```bash
git add functions/scripts/deploy/allowlist_diff.js functions/__tests__/deploy_allowlist_diff.test.js
git commit -m "Add the deploy allowlist superset checker"
```

---

### Task 4: Deploy-log reader/writer

**Files:**
- Create: `functions/scripts/deploy/deploy_log.js`
- Test: `functions/__tests__/deploy_log.test.js`

- [ ] **Step 1: Write the failing test**

```js
"use strict";

const {
  lastDeployedSha,
  appendRow,
  formatRow,
} = require("../scripts/deploy/deploy_log");

const DOC = [
  "# Deploying",
  "",
  "## Deploy log",
  "",
  "Keep this current.",
  "",
  "| Date | Commit | Targets | Fns live | Notes |",
  "|---|---|---|---|---|",
  "| 2026-09-29 | `cc38be5d` | functions | 32 | fixes |",
  "| 2026-09-30 | (uncommitted at deploy time) | functions | 32 | x |",
  "",
  "### A subsection after the table",
  "",
  "| 2026-01-01 | `deadbeef` | not | the | log |",
  "",
  "## Next section",
].join("\n");

describe("lastDeployedSha", () => {
  test("returns the newest row's sha, skipping rows without one", () => {
    expect(lastDeployedSha(DOC)).toBe("cc38be5d");
  });

  test("returns null when there is no Deploy log", () => {
    expect(lastDeployedSha("# nothing here")).toBeNull();
  });
});

describe("appendRow", () => {
  test("inserts after the table's last row, before the subsection", () => {
    const row = "| 2026-10-07 | `abcdef12` | functions | 34 | new |";
    const lines = appendRow(DOC, row).split("\n");
    const at = lines.indexOf(row);
    expect(lines[at - 1]).toContain("2026-09-30");
    expect(lines[at + 1]).toBe("");
    expect(lastDeployedSha(appendRow(DOC, row))).toBe("abcdef12");
  });

  test("throws when the table is missing", () => {
    expect(() => appendRow("## Deploy log\n\nno table", "| x |"))
        .toThrow(/Deploy log table/);
  });
});

describe("formatRow", () => {
  test("shortens the sha and links the run", () => {
    expect(formatRow({
      date: "2026-10-07",
      sha: "abcdef1234567890",
      targets: "functions",
      count: "34",
      runUrl: "https://github.com/o/r/actions/runs/1",
    })).toBe(
        "| 2026-10-07 | `abcdef12` | functions | 34 | Deploy workflow " +
        "[run](https://github.com/o/r/actions/runs/1). Notes: what " +
        "changed, prompts seen, and what still stands. |");
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/deploy_log.test.js`
Expected: FAIL — `Cannot find module`.

- [ ] **Step 3: Implement**

```js
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
  let end = start;
  while (end + 1 < lines.length && lines[end + 1].startsWith("|")) end++;
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
  const markdown = readFileSync(file, "utf8");
  if (command === "last-sha") {
    console.log(lastDeployedSha(markdown) || "");
    return 0;
  }
  if (command === "append") {
    const o = options(rest);
    writeFileSync(file, appendRow(markdown, formatRow({
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
```

- [ ] **Step 4: Run it to verify it passes, then against the real runbook**

Run: `cd functions && npx jest __tests__/deploy_log.test.js && npx eslint scripts/deploy/deploy_log.js && node scripts/deploy/deploy_log.js last-sha ../docs/DEPLOYMENT.md`
Expected: PASS, no lint output, then the newest logged sha (`abbe5e3f` at the time of writing).

- [ ] **Step 5: Commit**

```bash
git add functions/scripts/deploy/deploy_log.js functions/__tests__/deploy_log.test.js
git commit -m "Add the deploy-log reader and row writer"
```

---

### Task 5: Make CI callable

**Files:**
- Modify: `.github/workflows/ci.yml` (the `on:` block and both `actions/checkout@v7` steps)

- [ ] **Step 1: Add `workflow_call`**

Replace the `on:` block with:

```yaml
on:
  push:
    # Verify the long-lived development branch as well as main.
    branches: [main, dev]
  pull_request:
  workflow_call:
    inputs:
      ref:
        description: Ref to verify (the deploy workflow passes its own).
        type: string
        required: false
        default: ""
```

- [ ] **Step 2: Check out that ref in BOTH jobs**

Change each of the two `- uses: actions/checkout@v7` lines (in `flutter` and `functions`) to:

```yaml
      - uses: actions/checkout@v7
        with:
          ref: ${{ inputs.ref }}
```

`inputs.ref` is empty on `push`/`pull_request`, and `actions/checkout` treats an empty `ref` as its default, so those runs are unchanged.

- [ ] **Step 3: Verify**

Run: `git diff --stat .github/workflows/ci.yml`
Expected: one file, the two hunks above. Push to `dev` in Task 8 proves CI still triggers on push.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Make CI callable from the deploy workflow"
```

---

### Task 6: The deploy workflow

**Files:**
- Create: `.github/workflows/deploy.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: Deploy backend

on:
  workflow_dispatch:
    inputs:
      ref:
        description: Commit, branch or tag to deploy
        required: true
        default: main
      targets:
        description: What to deploy (all = indexes first and READY, then functions + rules + storage)
        required: true
        type: choice
        default: functions
        options:
          - functions
          - firestore:rules
          - firestore:indexes
          - storage
          - all

concurrency:
  group: deploy-production
  cancel-in-progress: false

permissions:
  contents: read

env:
  PROJECT_ID: schedulingapp-88727
  FIREBASE_TOOLS: firebase-tools@15.25.1
  AI_AGENT: ""
  CLAUDECODE: ""
  CLAUDE_CODE: ""

jobs:
  verify:
    name: Lint + test (same as CI)
    uses: ./.github/workflows/ci.yml
    with:
      ref: ${{ inputs.ref }}

  deploy:
    name: Deploy to production
    needs: verify
    runs-on: ubuntu-latest
    environment: production
    permissions:
      contents: read
      id-token: write
    outputs:
      sha: ${{ steps.resolve.outputs.sha }}
      count: ${{ steps.after.outputs.count }}
    steps:
      - uses: actions/checkout@v7
        with:
          ref: ${{ inputs.ref }}
          fetch-depth: 0

      - id: resolve
        run: echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

      - uses: actions/setup-node@v7
        with:
          node-version: 24
          cache: npm
          cache-dependency-path: functions/package-lock.json

      - name: Install functions dependencies
        working-directory: functions
        run: npm ci

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_DEPLOY_SA }}

      - uses: google-github-actions/setup-gcloud@v2

      - name: Plan
        id: plan
        env:
          TARGETS: ${{ inputs.targets }}
        run: |
          case "$TARGETS" in
            all)               indexes="firestore:indexes"; rest="functions,firestore:rules,storage" ;;
            firestore:indexes) indexes="firestore:indexes"; rest="" ;;
            *)                 indexes="";                  rest="$TARGETS" ;;
          esac
          base="npx --yes $FIREBASE_TOOLS deploy --project $PROJECT_ID --non-interactive --only"
          {
            [ -n "$indexes" ] && echo "$base $indexes"
            [ -n "$rest" ] && echo "$base $rest"
          } > deploy-commands.txt
          echo "indexes=$indexes" >> "$GITHUB_OUTPUT"
          echo "rest=$rest" >> "$GITHUB_OUTPUT"
          case "$rest" in *functions*) echo "functions=true" >> "$GITHUB_OUTPUT" ;; esac
          cat deploy-commands.txt

      - name: Refuse --force
        run: |
          if grep -n -e '--force' deploy-commands.txt; then
            echo "::error::A deploy command contains --force. It deletes every prod TTL policy missing from firestore.indexes.json (all five were lost this way on 2026-07-21). Never."
            exit 1
          fi

      - name: Export diff (deletions abort non-interactively)
        if: steps.plan.outputs.functions == 'true'
        run: |
          npx --yes "$FIREBASE_TOOLS" functions:list --project "$PROJECT_ID" --json > live-before.json
          node functions/scripts/deploy/export_diff.js functions/index.js live-before.json

      - name: Allowlists are a superset of the last deploy
        if: steps.plan.outputs.functions == 'true'
        run: |
          base=$(node functions/scripts/deploy/deploy_log.js last-sha docs/DEPLOYMENT.md)
          if [ -z "$base" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
            echo "::warning::No usable last-deploy sha in the Deploy log ('$base'); allowlist check skipped. Do DEPLOYMENT.md §4(a) by hand."
            exit 0
          fi
          cd functions && node scripts/deploy/allowlist_diff.js "$base"

      - name: TTL drift report
        if: steps.plan.outputs.indexes != ''
        run: |
          gcloud firestore fields ttls list --project "$PROJECT_ID" --format=json \
            | jq -r '.[] | .name | capture("collectionGroups/(?<c>[^/]+)/fields/(?<f>[^/]+)") | "\(.c).\(.f)"' \
            | sort > ttl-live.txt
          jq -r '.fieldOverrides[] | select(.ttl == true) | "\(.collectionGroup).\(.fieldPath)"' firestore.indexes.json \
            | sort > ttl-file.txt
          missing=$(comm -23 ttl-live.txt ttl-file.txt)
          if [ -n "$missing" ]; then
            echo "::warning::Live TTL policies not in firestore.indexes.json (harmless without --force, which this workflow never passes): $missing"
            { echo "### TTL drift"; echo; echo '```'; echo "$missing"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
          fi

      - name: Deploy indexes
        if: steps.plan.outputs.indexes != ''
        run: npx --yes "$FIREBASE_TOOLS" deploy --project "$PROJECT_ID" --non-interactive --only firestore:indexes

      - name: Wait for every composite index to be READY
        if: steps.plan.outputs.indexes != ''
        run: |
          deadline=$((SECONDS + 2700))
          while true; do
            pending=$(gcloud firestore indexes composite list --project "$PROJECT_ID" --format=json \
              | jq '[.[] | select(.state != "READY")] | length')
            [ "$pending" -eq 0 ] && { echo "All composite indexes READY."; break; }
            if [ "$SECONDS" -ge "$deadline" ]; then
              echo "::error::$pending composite index(es) still not READY after 45 min. Nothing else was deployed; re-run once they are."
              exit 1
            fi
            echo "$pending composite index(es) not READY yet; waiting 30 s"
            sleep 30
          done

      - name: Deploy
        id: deploy
        if: steps.plan.outputs.rest != ''
        env:
          REST: ${{ steps.plan.outputs.rest }}
        run: |
          set -o pipefail
          npx --yes "$FIREBASE_TOOLS" deploy --project "$PROJECT_ID" --non-interactive --only "$REST" 2>&1 | tee deploy-output.log

      - name: Explain a known abort
        if: failure() && steps.deploy.outcome == 'failure'
        run: |
          if grep -q "failure policy" deploy-output.log; then
            echo "::error::A NEWLY CREATED retry: true function aborts a non-interactive deploy (DEPLOYMENT.md, 2026-08-14 row). Do not add --force to the whole run. Deploy the new trigger alone from an owner shell with 'firebase deploy --only functions:<name> --force' — with no firestore target in scope --force cannot reach an index or TTL policy — then re-run this workflow."
          fi
          if grep -qi "delet" deploy-output.log; then
            echo "::error::The CLI wanted to delete a function. The export diff should have caught this; read deploy-output.log and delete explicitly with firebase functions:delete."
          fi

      - name: Verify by name
        id: after
        if: steps.plan.outputs.functions == 'true'
        run: |
          npx --yes "$FIREBASE_TOOLS" functions:list --project "$PROJECT_ID" --json > live-after.json
          node functions/scripts/deploy/export_diff.js functions/index.js live-after.json --after-deploy
          echo "count=$(jq '.result | length' live-after.json)" >> "$GITHUB_OUTPUT"

      - name: Checklist the workflow cannot enforce
        if: always()
        run: |
          cat >> "$GITHUB_STEP_SUMMARY" <<'EOF'
          ## Before you ship the app build

          - [ ] This run is green. The backend goes out BEFORE the app build that needs it — never the reverse.
          - [ ] Every NEW payload field is optional (`optionalString`, `x === true`). The allowlist check only catches REMOVED keys.
          - [ ] No rules cap is tighter than what a shipped client or callable can write (DEPLOYMENT.md §4c).
          - [ ] Any backfill this release depends on has run (`node functions/scripts/run.js <name> --live`).
          - [ ] Function logs since the deploy show no `unexpected-field`, no startup errors.
          - [ ] Smoke-tested with the OLD app build if one is installed.
          - [ ] Notes column filled in on the deploy-log PR this run opens.
          EOF

  record:
    name: Open the deploy-log PR
    needs: deploy
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v7
        with:
          ref: dev

      - uses: actions/setup-node@v7
        with:
          node-version: 24

      - name: Append the row
        env:
          SHA: ${{ needs.deploy.outputs.sha }}
          COUNT: ${{ needs.deploy.outputs.count || 'unchanged' }}
          TARGETS: ${{ inputs.targets }}
          RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
        run: |
          node functions/scripts/deploy/deploy_log.js append docs/DEPLOYMENT.md \
            "--date=$(date -u +%Y-%m-%d)" "--sha=$SHA" "--targets=$TARGETS" \
            "--count=$COUNT" "--run-url=$RUN_URL"

      - uses: peter-evans/create-pull-request@v7
        with:
          base: dev
          branch: deploy-log/${{ github.run_id }}
          title: "Record the ${{ inputs.targets }} deploy of ${{ needs.deploy.outputs.sha }}"
          commit-message: "Record the ${{ inputs.targets }} deploy in the deploy log"
          body: |
            Appends the Deploy log row for workflow run ${{ github.run_id }}.
            Fill in the Notes cell (what changed, any prompt, what still stands) before merging.

            🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 2: Lint the workflow**

Run: `npx --yes @action-validator/cli .github/workflows/deploy.yml && npx --yes @action-validator/cli .github/workflows/ci.yml`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "Add the manual deploy workflow"
```

---

### Task 7: The script runner

**Files:**
- Create: `functions/scripts/_runner.js`
- Create: `functions/scripts/run.js`
- Test: `functions/__tests__/scripts_runner.test.js`
- Test: `functions/__tests__/scripts_run_registry.test.js`

- [ ] **Step 1: Write the failing runner-core test**

```js
"use strict";

const {parseRunnerArgs, runScript} = require("../scripts/_runner");

describe("parseRunnerArgs", () => {
  test("defaults to dry-run and passes other args through", () => {
    expect(parseRunnerArgs(["recount", "--verbose"])).toEqual({
      name: "recount", live: false, yesCount: null,
      passthrough: ["--verbose"],
    });
  });

  test("an explicit --dry-run is accepted and not passed through", () => {
    expect(parseRunnerArgs(["recount", "--dry-run"]).passthrough).toEqual([]);
  });

  test("reads --live and --yes-count", () => {
    expect(parseRunnerArgs(["recount", "--live", "--yes-count=12"]))
        .toMatchObject({live: true, yesCount: 12, passthrough: []});
  });

  test.each([
    [[], /usage/],
    [["--live"], /usage/],
    [["recount", "--live", "--dry-run"], /both/],
    [["recount", "--yes-count=3"], /only with --live/],
    [["recount", "--live", "--yes-count=-1"], /non-negative integer/],
    [["recount", "--live", "--yes-count=abc"], /non-negative integer/],
  ])("rejects %j", (argv, message) => {
    expect(() => parseRunnerArgs(argv)).toThrow(message);
  });
});

/**
 * A fake child: the dry run prints `stdout`, the live run prints nothing.
 * @param {string} stdout What the dry run prints.
 * @return {!Object} A jest mock of spawnScript.
 */
function fakeSpawn(stdout) {
  return jest.fn(async (file, args) => ({
    code: 0,
    stdout: args.includes("--dry-run") ? stdout : "",
  }));
}

const REGISTRY = {
  fake: {
    file: "fake.js",
    kind: "write",
    countFrom: (stdout) => {
      const m = stdout.match(/(\d+) patched/);
      return m ? Number(m[1]) : null;
    },
  },
  reader: {file: "reader.js", kind: "read"},
  gone: {file: "gone.js", kind: "retired", reason: "superseded"},
  seed: {file: "seed.js", kind: "emulator"},
};

/**
 * Runs the core with fakes.
 * @param {!Array<string>} argv Runner args.
 * @param {!Object=} overrides Replacement deps.
 * @return {!Promise<{code: number, spawn: !Object, prompt: !Object}>} Result.
 */
async function run(argv, overrides = {}) {
  const spawn = overrides.spawn || fakeSpawn("clients: 7 patched");
  const prompt = overrides.prompt || jest.fn(async () => "7");
  const code = await runScript({
    argv, registry: REGISTRY, spawnScript: spawn, prompt,
    log: () => {}, env: overrides.env || {},
  });
  return {code, spawn, prompt};
}

describe("runScript", () => {
  test("default is a dry run only", async () => {
    const {code, spawn, prompt} = await run(["fake", "--verbose"]);
    expect(code).toBe(0);
    expect(spawn).toHaveBeenCalledTimes(1);
    expect(spawn).toHaveBeenCalledWith(
        "fake.js", ["--dry-run", "--verbose"], {capture: true});
    expect(prompt).not.toHaveBeenCalled();
  });

  test("--live re-runs the dry run, confirms the count, then runs live",
      async () => {
        const {code, spawn, prompt} = await run(["fake", "--live", "-v"]);
        expect(code).toBe(0);
        expect(prompt).toHaveBeenCalledTimes(1);
        expect(spawn.mock.calls).toEqual([
          ["fake.js", ["--dry-run", "-v"], {capture: true}],
          ["fake.js", ["-v"], {capture: false}],
        ]);
      });

  test("a typed count that does not match aborts before the live run",
      async () => {
        const {code, spawn} = await run(["fake", "--live"], {
          prompt: jest.fn(async () => "6"),
        });
        expect(code).toBe(1);
        expect(spawn).toHaveBeenCalledTimes(1);
      });

  test("a stale --yes-count aborts without prompting", async () => {
    const {code, spawn, prompt} =
      await run(["fake", "--live", "--yes-count=5"]);
    expect(code).toBe(1);
    expect(prompt).not.toHaveBeenCalled();
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  test("a matching --yes-count runs live without prompting", async () => {
    const {code, spawn, prompt} =
      await run(["fake", "--live", "--yes-count=7"]);
    expect(code).toBe(0);
    expect(prompt).not.toHaveBeenCalled();
    expect(spawn).toHaveBeenCalledTimes(2);
  });

  test("a zero count never runs live", async () => {
    const {code, spawn} = await run(["fake", "--live"], {
      spawn: fakeSpawn("clients: 0 patched"),
    });
    expect(code).toBe(0);
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  test("an unreadable count refuses the live run", async () => {
    await expect(run(["fake", "--live"], {spawn: fakeSpawn("garbage")}))
        .rejects.toThrow(/could not read/);
  });

  test("a failing dry run stops there", async () => {
    const spawn = jest.fn(async () => ({code: 2, stdout: ""}));
    const {code} = await run(["fake", "--live"], {spawn});
    expect(code).toBe(2);
    expect(spawn).toHaveBeenCalledTimes(1);
  });

  test("a read script runs as-is and refuses --live", async () => {
    const {spawn} = await run(["reader", "--verbose"]);
    expect(spawn).toHaveBeenCalledWith(
        "reader.js", ["--verbose"], {capture: false});
    await expect(run(["reader", "--live"])).rejects.toThrow(/read-only/);
  });

  test("a retired script is always refused", async () => {
    await expect(run(["gone"])).rejects.toThrow(/superseded/);
  });

  test("an emulator script needs FIRESTORE_EMULATOR_HOST", async () => {
    await expect(run(["seed"])).rejects.toThrow(/FIRESTORE_EMULATOR_HOST/);
    const {code} = await run(["seed"], {
      env: {FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080"},
    });
    expect(code).toBe(0);
  });

  test("an unknown name lists the known ones", async () => {
    await expect(run(["nope"])).rejects.toThrow(/fake, reader, gone, seed/);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/scripts_runner.test.js`
Expected: FAIL — `Cannot find module '../scripts/_runner'`.

- [ ] **Step 3: Implement the core**

`functions/scripts/_runner.js`:

```js
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd functions && npx jest __tests__/scripts_runner.test.js && npx eslint scripts/_runner.js`
Expected: PASS, no lint output.

- [ ] **Step 5: Write the failing registry test**

```js
"use strict";

const {readdirSync} = require("fs");
const path = require("path");
const {REGISTRY} = require("../scripts/run");

const SCRIPTS_DIR = path.join(__dirname, "..", "scripts");

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

  // Each sample is the script's real dry-run summary line, copied from it.
  test.each([
    ["backfill-client-address-street",
      "[dry-run] clients: 900 scanned, 12 reduced, 888 left alone", [], 12],
    ["backfill-client-buildings",
      "{ scanned: 900, projectionsChanged: 4, dryRun: true }", [], 4],
    ["backfill-client-name-digits",
      "[dry-run] clients: 900 scanned, 3 reformatted, 897 left alone", [], 3],
    ["backfill-client-name-with-phone",
      "[dry-run] clients: 900 scanned, 5 renamed, 2 skipped (business)", [],
      5],
    ["backfill-client-phone-formatting",
      "[dry-run] clients: 900 scanned, 8 patched — 6 had a number", [], 8],
    ["backfill-client-sort-fields",
      "[dry-run] clients: 900 scanned, 9 sort rows patched", [], 9],
    ["backfill-clients-archived",
      "[dry-run] clients: 11 patched, 889 already had the field", [], 11],
    ["backfill-search-tokens",
      "[dry-run] clients: 900 scanned, 2 token rows patched\n" +
      "[dry-run] appointments: 5000 scanned, 3 token rows patched", [], 5],
    ["backfill-wave-blocked",
      "\n[dry-run] clients: 900 scanned, 6 verdict rows patched", [], 6],
    ["backfill",
      "Backfill complete:\n{\n  \"updated\": 2,\n  \"created\": 1,\n" +
      "  \"orphansFound\": 4\n}", [], 3],
    ["backfill",
      "Backfill complete:\n{\n  \"updated\": 2,\n  \"created\": 1,\n" +
      "  \"orphansFound\": 4\n}", ["--prune-orphans"], 7],
    ["drain-wave-queue", "queued jobs: 14\n", [], 14],
    ["recount-client-jobs",
      "[dry-run] clients: 900 scanned, 10 job counts patched", [], 10],
    ["repair-client-address-mojibake",
      "[dry-run] clients: 900 scanned, 1 repaired", [], 1],
  ])("%s reads its count", (name, stdout, passthrough, expected) => {
    expect(REGISTRY[name].countFrom(stdout, passthrough)).toBe(expected);
  });
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd functions && npx jest __tests__/scripts_run_registry.test.js`
Expected: FAIL — `Cannot find module '../scripts/run'`.

- [ ] **Step 7: Implement `run.js`**

Before writing it, re-confirm each pattern against its script's current summary `console.log` (`grep -n "console.log" -A4 functions/scripts/<file>`). The patterns below match the lines as of 2026-10-06.

```js
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
```

- [ ] **Step 8: Run both tests, lint, and a real dry run of a read-only path**

Run: `cd functions && npx jest __tests__/scripts_runner.test.js __tests__/scripts_run_registry.test.js && npx eslint scripts/_runner.js scripts/run.js && node scripts/run.js; echo "exit=$?"; node scripts/run.js backfill-client-phone-from-name; echo "exit=$?"`
Expected: PASS; no lint output; the usage line and `exit=1`; the "retired" message and `exit=1`.

- [ ] **Step 9: Commit**

```bash
git add functions/scripts/_runner.js functions/scripts/run.js functions/__tests__/scripts_runner.test.js functions/__tests__/scripts_run_registry.test.js
git commit -m "Add one runner for the one-off scripts with a fresh-count gate"
```

---

### Task 8: First real run (owner approves in GitHub)

Needs Task 1 done.

- [ ] **Step 1: Full local pre-flight**

Run: `cd functions && npm run lint && npx jest`
Expected: lint clean; all suites pass, coverage thresholds met (the new modules are tested, so they add coverage rather than dilute it).

- [ ] **Step 2: Push the branch**

Run: `git push origin dev`
Expected: the `CI` workflow triggers on push exactly as before (proves Task 5 left push/PR runs unchanged).

- [ ] **Step 3: Owner dispatches the smallest idempotent deploy**

GitHub → Actions → Deploy backend → Run workflow → `ref: dev`, `targets: firestore:rules`. Approve the `production` environment gate when prompted.
Expected: `verify` green; `deploy` runs Plan → Refuse `--force` → Deploy (rules re-release, no content change) → checklist in the summary; `record` opens a PR against `dev` adding one Deploy log row.

- [ ] **Step 4: Owner dispatches a functions deploy**

Same, `targets: functions`.
Expected: export diff prints `"added":[],"removed":[]`; allowlist check exits 0; deploy succeeds; "Verify by name" passes; the record PR's row shows the function count (32 at time of writing).

- [ ] **Step 5: Close the two record PRs** after filling in their Notes cells (merge them). No other commit.

---

### Task 9: Point the docs at the workflow and runner

**Files:**
- Modify: `docs/DEPLOYMENT.md`
- Modify: `.claude/skills/deploy/SKILL.md`
- Modify: `.claude/commands/script.md`
- Modify: `CLAUDE.md` (the Cloud Functions section's `Deploy:` paragraph)

- [ ] **Step 1: `docs/DEPLOYMENT.md`**

1. **§5 Deploy** — replace the env-var block, the `cd functions && npm run lint` + `firebase deploy` block and the `--force`/target bullets with:

   ```markdown
   ## 5. Deploy

   **Use the `Deploy backend` workflow** (Actions → Deploy backend → Run
   workflow; pick `ref` and `targets`, approve the `production` gate). It runs
   CI's lint + tests, refuses `--force`, blocks a deploy that would DELETE a
   function or narrow a callable allowlist, deploys `firestore:indexes` first
   and waits for `READY` when indexes are in scope, verifies the live function
   set by name, and opens the Deploy log PR. `.github/workflows/deploy.yml` is
   the source of truth for those steps.

   **Local CLI is the fallback** (the workflow is down, or a step below needs
   an owner shell): clear `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` first, never
   pass `--force` on a run that includes a `firestore` target, and record the
   row by hand.

   Two things still need an owner shell, by design:
   - **Deleting a function** — the workflow refuses; run
     `firebase functions:delete <names> --region us-central1` after confirming
     each name, then re-run the workflow.
   - **Creating a new `retry: true` function** — a non-interactive deploy
     aborts on its failure policy; deploy that one function alone with
     `--only functions:<name> --force` (no firestore target in scope, so
     `--force` cannot reach an index or TTL policy), then re-run the workflow.
   ```

   Keep the AI-agent-env-var explanation paragraph (it still applies to the fallback) but move it under that fallback sentence.
2. **§1 Pre-flight / §2 / §3 / §6** — add one line to each: "The workflow does this (`<step name>`)" for §1 (verify job), §2 + §6 (export diff / Verify by name), §3 (allowlist step reads the last-deploy sha). Keep the manual commands below as the fallback.
3. **§4(a)** — prefix with: "Automated for REMOVED keys by the workflow's allowlist step; (b) and (c) are still by hand."
4. **Per-release checklist** — replace lines `[ ] deployed backend  (no --force)`, `[ ] verified function count + logs`, `[ ] appended a row to the Deploy log below` with `[ ] Deploy backend workflow green (it refuses --force, verifies by name, opens the log PR)` and `[ ] log PR Notes filled in and merged`.
5. **Deploy log intro** — add: "Rows are appended by the deploy workflow as a PR against `dev`; fill in Notes before merging."
6. Any `node functions/scripts/<x>.js --dry-run` command in the runbook → `node functions/scripts/run.js <x>`; the matching live command → `node functions/scripts/run.js <x> --live`. Find them with `grep -n "node functions/scripts" docs/DEPLOYMENT.md`. Leave deploy-log ROWS untouched — they are history.

- [ ] **Step 2: `.claude/skills/deploy/SKILL.md`**

1. Under the title, add §"0a. Default: the workflow": dispatch `Deploy backend`, report the run URL, and answer the four-step ordering question with the targets chosen (`all` covers steps 1 and 3 in order; backfills via `run.js`; app build last).
2. Rename §2 "Deploy" to "Fallback: deploy from a local shell" and say when to use it (workflow unavailable; deleting a function; creating a `retry: true` function — the two refusals above).
3. §4 Verify: "The workflow's `Verify by name` step does the name diff; still read the function logs yourself."
4. Bump nothing else; the prompt-answering guidance in §3 stays for the fallback.

- [ ] **Step 3: `.claude/commands/script.md`**

In §2 and §4, replace every `node functions/scripts/<name>.js --dry-run` with `node functions/scripts/run.js <name>` and every live command with `node functions/scripts/run.js <name> --live`, and add one line to §4: "`--live` re-runs the dry run and asks for its count typed back; a count from an earlier run is refused, by design."

- [ ] **Step 4: `CLAUDE.md`**

Replace the `Deploy: firebase deploy --only functions,firestore:rules,firestore:indexes,storage` sentence with: "Deploy: the `Deploy backend` GitHub Actions workflow (`workflow_dispatch`, `production` approval). Local `firebase deploy --only ...` is the fallback — clear `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` first (see `docs/DEPLOYMENT.md` §5)." Keep the `storage:rules` and `--force` sentences that follow it unchanged. Add after the `Always run cd functions && npm run lint` sentence: "One-off prod scripts run through `node functions/scripts/run.js <name> [--live]`."

- [ ] **Step 5: Check nothing else names the old commands**

Run: `grep -rn "node functions/scripts/[a-z-]*\.js" .claude CLAUDE.md functions/CLAUDE.md docs/DEPLOYMENT.md docs/ARCHITECTURE.md | grep -v "^docs/DEPLOYMENT.md:.*| 20"`
Expected: only lines inside a script's own header comments or historical records. Update any live instruction it finds the same way as Step 3.

- [ ] **Step 6: Commit**

```bash
git add docs/DEPLOYMENT.md .claude/skills/deploy/SKILL.md .claude/commands/script.md CLAUDE.md
git commit -m "Point the deploy and script docs at the workflow and runner"
```

---

## Runbook rules the workflow cannot encode

Printed in every run's job summary (Task 6, last step of `deploy`):

1. Backend before the app build — the workflow cannot see App Store Connect.
2. New payload fields must be optional — only REMOVED keys are machine-checked.
3. Rules caps vs shipped write paths (§4c) — needs reading Dart and JS limits.
4. Backfills the release depends on — order relative to the app build is a release decision.
5. Log reading for `unexpected-field` / startup errors after the deploy.
6. Smoke test with the old build.
7. Function deletions and newly-created `retry: true` functions — refused by the workflow and done from an owner shell (Task 9 Step 1).
