---
name: deploy
description: >-
  Deploy this app's Firebase backend — Cloud Functions, Firestore rules,
  Storage rules — with the required pre-flight lint/tests and post-deploy
  verification. Use whenever the user says deploy, redeploy, "push the
  functions/rules live", asks "what's the command to deploy", wants to check
  that all functions are deployed / everything is up to date, or after edits
  to functions/, firestore.rules, or storage.rules that need to go live.
---

# Firebase Deploy Runbook

Project `schedulingapp-88727`, region `us-central1`. Functions live in
`functions/` and are all re-exported from `functions/index.js` — that export
list (**30 exports**) is the source of truth for what should exist in prod.

## 0. Establish the ordering before touching anything

A deploy here is one step of a four-step release, and the steps are ordered
because each one breaks the app if it lands late:

1. **`firestore:indexes`**, alone, and wait for every new composite to reach
   `READY`. A query against a `CREATING` index fails exactly like a missing one.
2. **Prod backfills**, if the new code reads a field the existing documents do
   not carry (`backfill-search-tokens.js`, `backfill-client-sort-fields.js`).
   A backfill is a **prerequisite for the release, not a follow-up** — skip it
   and search returns nothing for every pre-existing document, silently.
3. **`functions` + rules** — the backend must accept the new payload shape
   before a build that sends it exists, because `assertPayloadShape` rejects
   an unknown key outright.
4. **The app build**, last.

State which of the four this run is, and what still stands after it. This repo
has carried undeployed backend work across three releases at once; saying
"deployed" when only step 3 ran is how that happens.

## 1. Pre-flight (never skip)

```bash
cd functions && npm run lint   # Google ESLint, 80-char limit
cd functions && npx jest       # all suites must pass
```

Fix failures before deploying — a broken deploy leaves prod half-updated.

## 2. Deploy

Clear the AI-agent env vars first, or the CLI stamps `agent-name/claude_code`
into the Cloud Audit Log (see `docs/DEPLOYMENT.md` §5 — the entry is immutable
once written). Clear them once in the shell that will run the deploy; the
rollback and `functions:delete` paths need it too.

**The owner's shell is PowerShell**, where `export` is not a command. Give the
PowerShell form first and only mention the bash one if they are in the Bash
tool:

```powershell
Remove-Item Env:AI_AGENT, Env:CLAUDECODE, Env:CLAUDE_CODE -ErrorAction SilentlyContinue
firebase deploy --only functions,firestore:rules,storage
```

```bash
export AI_AGENT= CLAUDECODE= CLAUDE_CODE=
firebase deploy --only functions,firestore:rules,storage
```

Both clear the variables for **that shell only** — a new terminal needs it
again. Confirm with `$env:AI_AGENT` (PowerShell) before deploying.

- `storage` is the target name, **not** `storage:rules` (invalid target).
- One function only: `--only functions:<name>`.
- Rules only: `--only firestore:rules`.
- **If `firestore.indexes.json` changed, deploy `firestore:indexes` FIRST and
  on its own**, then the command above. A new composite has to finish building
  before the code that queries it goes live, and a separate run makes the index
  drift line (below) easy to spot instead of burying it in the functions
  output.
- Deploying functions (re)activates App Check enforcement
  (`enforceAppCheck: true`) on the callables — that is expected and correct.

## 3. Known prompts and errors — how to answer

- **"functions found in your project but do not exist in your local source
  code: X"** — X was renamed or removed. Before agreeing to delete, confirm
  it's intentionally gone: check `functions/index.js` exports and
  `git log -- functions/`. (Past example: `waveListBusinesses` was
  intentionally removed — deleting was correct.)
- **"The following functions will newly be retried in case of failure:
  propagateClientEdits, syncUsersByUid, waveUpsertCustomer"** — expected;
  these triggers are idempotent with `retry: true`. Proceed. A retry is
  billed like any execution but only fires on failure, so steady-state cost
  is unchanged.
- **"there are N indexes defined in your project that are not present in your
  firestore indexes file"** — you deleted an index from
  `firestore.indexes.json` and expected the deploy to drop it. **It did not,
  and it never will: a deploy can add an index but never delete one.** The only
  flag that deletes is `--force`, which is **banned here** — it also deletes
  any prod TTL policy missing from the file, which is how all five live
  policies were lost on 2026-07-21. So the index stays as permanent drift until
  someone removes it out-of-band.
  **Do that with a targeted delete, not the console and never `--force`:** get
  the index id from Firebase MCP `firestore_list_indexes` (parent
  `projects/schedulingapp-88727/databases/(default)/collectionGroups/<coll>`),
  then `firestore_delete_index` on that id. It removes exactly one index and
  cannot touch a TTL policy. Re-read the list afterwards and confirm **both**
  halves: the index is gone, *and* whichever index now serves those queries in
  its place is still `READY`.
  Check one thing BEFORE deleting: if a wider composite covers the same query
  as a *prefix*, it is `SPARSE_ALL` and therefore omits documents missing any
  of its extra fields, where the narrower index did not. Confirm nothing live
  depends on that difference, or the query silently returns fewer rows.
  (Worked example: `appointments (employeeIds CONTAINS, endTime ASC)`, deleted
  2026-08-29.)
- **"An Internal error has occurred… firebase-tools"** — transient backend
  issue. Wait a few minutes and retry once; if it persists, check the
  function's Cloud logs before changing anything locally.
- **Secret prompts** — `GOOGLE_MAP_API_KEY`, `WAVE_FULL_ACCESS_TOKEN`,
  `WAVE_BUSINESS_NAME` live in Secret Manager only. A prompt about an unbound
  secret means the secret name in code changed — verify before creating a
  new one.

## 4. Verify

- List deployed functions (Firebase MCP `functions_list_functions`, or
  `firebase functions:list`) and diff against the exports in
  `functions/index.js` — all 30 deployed, no orphans. **An unchanged count is
  not a verification**: the set changed by six at an unchanged count of 25
  once, and the drift went unnoticed for three days. Diff the names.
- If new composites went out in step 0.1, re-read `firestore_list_indexes` and
  confirm `READY`, not `CREATING`.
- For a function you just changed, spot-check its recent logs
  (MCP `functions_get_logs`) for startup errors.
- Record the deploy in `docs/DEPLOYMENT.md`'s log — the commit actually running
  in prod. That log is the only answer to "is the backend behind the app?", and
  every stale-deploy incident here started with a run that was not recorded.

Report what was deployed, the verification result, anything skipped or answered
at a prompt, and — explicitly — **which of the four ordering steps still
stand**. The user should be able to audit every choice made.
