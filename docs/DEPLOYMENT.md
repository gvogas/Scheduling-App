# Deploying a release (backend + app)

Project `schedulingapp-88727`, region `us-central1`.

This is the **release** runbook: what order to do things in, and how to check a
backend change won't break the app builds already on people's phones. For the
mechanics of the deploy command itself — prompts, expected warnings, secret
errors — use the `/deploy` skill, which this doc deliberately does not repeat.

---

## The one rule

> **Deploy the backend BEFORE you cut or ship the app build. Never the reverse.**

Every callable runs `assertPayloadShape(req.data, allowedKeys)`, which throws
`invalid-argument / unexpected-field` on the **first key it doesn't recognise**.
So:

| Direction | What happens |
|---|---|
| **New app build → old functions** | Every affected callable **fails outright.** P4c's build calls `createEmployeeAccount` / `completeEmployeeSetup` / `deleteEmployeeAccount`, which do not exist until it deploys → *no employee can be created or set up at all.* |
| **Old app build → new functions** | Fine **if** each new allowlist is a superset and each new field is optional. That is the contract to preserve — see the check below. |

The asymmetry is the whole point: the backend must always be able to serve the
build behind it *and* the build ahead of it. Ship backend first and you always
have that.

---

## 1. Pre-flight

```bash
flutter analyze                       # 0 issues is the baseline
flutter test                          # full suite
cd functions && npm run lint && npx jest
```

Then validate the rules without deploying (Firebase MCP
`firebase_validate_security_rules`, `source_file: firestore.rules`).

**Expect a clean `OK: No errors detected.`** This used to warn 3× on
`isAvailabilityOnlyChange` (one "Unused function", two "Invalid variable
name"); those were artifacts of it being uncalled and **are gone as of
2026-08-15**, since P5 wired it up. A warning here is now worth reading, not
ignoring.

## 2. Find out what is ACTUALLY live

Do not trust this repo's docs for this — they have been wrong. On 2026-08-02
`docs/CLOUD_FUNCTIONS.md` claimed 21 deployed and `recountClientJobs` missing;
production actually had 22 and `recountClientJobs` was live.

Firebase MCP `functions_list_functions`, or:

```bash
firebase functions:list
```

Diff that against the export list in `functions/index.js` — that list is the
source of truth for what *should* exist.

## 3. Diff the backend since the last deploy

Find the last deployed commit in the **Deploy log** at the bottom of this file,
then:

```bash
git --no-pager diff --stat <last-deploy-commit> -- functions/ firestore.rules firestore.indexes.json
```

## 4. Compatibility check — the step people skip

For **every callable whose payload handling changed**, answer two questions.

**(a) Is the new allowlist a superset of the deployed one?**

```bash
# deployed
git show <last-deploy-commit>:functions/employee_accounts.js | grep -n "assertPayloadShape" -A 4
# local
grep -n "assertPayloadShape" -A 4 functions/employee_accounts.js
```

If a key was **removed** from an allowlist, the currently-installed build breaks
the moment you deploy. Keep the key (ignore it server-side) until no build in
the wild still sends it.

**(b) Is every newly-added field optional?**

New fields must read through `optionalString(...)` or `x === true`, never
`requireString(...)`. A new *required* field breaks every older build.

**(c) Rules: is any cap tighter than what a shipped write path can produce?**

This is the most common way a rules deploy breaks the app, and it fails with an
opaque `permission-denied` that names no field. For each new/changed cap in
`isValidUserData` / `isValidClientData` / `isValidAppointmentData`, find the
widest value the **client** and the **callables** can actually write — check
`lib/core/validators/text_limits.dart` and the server's `requireString` limits.
A cap below either one makes matching docs **permanently un-updatable**,
including by `deactivateEmployee`.

Two real examples from this repo:

- `phone` is capped at **40** in rules, not `TextLimits.phone`, because
  `createEmployeeAccount` accepts 40.
- `employeeIds` was briefly capped at **30** (reasoning from
  `whereArrayContainsAny`) — wrong: that is a *query* chunk size, not an
  assignment limit, and nothing bounds the picker client-side. It is **500**,
  tied to `_userStreamLimit`.

Also check the converse: a **client** cap must not exceed the callable's, or the
field accepts input the server rejects as `invalid-argument`, which surfaces to
the user as an unexplained "Something went wrong".

## 5. Deploy

**Clear the three AI-agent env vars first, in whatever shell you deploy from.**
`firebase-tools` builds its User-Agent in `lib/apiv2.js` from `detectAIAgent()`
(`lib/env.js`), which reads `AI_AGENT`, then `CLAUDECODE`/`CLAUDE_CODE`. A
terminal opened inside an agent harness has them set, so every call goes up as
`FirebaseCLI/<v> agent-name/claude_code` and lands that way in the Cloud Audit
Log. Cleared, `detectAIAgent()` returns `"unknown"` and the tag is omitted:
`FirebaseCLI/<v>` alone. **Export once per session** rather than prefixing each
command — the rollback (§7) and `functions:delete` (§8) invocations need it
too, and a per-command prefix is three places to forget it.

```bash
export AI_AGENT= CLAUDECODE= CLAUDE_CODE=      # bash/zsh; once per shell
```
```powershell
$env:AI_AGENT=''; $env:CLAUDECODE=''; $env:CLAUDE_CODE=''   # PowerShell
```

This changes the telemetry string only — **not** who is authenticated. The audit
entry still carries your `principalEmail`, and an already-written entry cannot
be edited or deleted (Admin Activity logs are immutable, retained 400 days).
For a one-off without exporting, bash accepts an inline prefix
(`AI_AGENT= CLAUDECODE= CLAUDE_CODE= firebase deploy ...`); **PowerShell does
not** — it has no inline env-var prefix, so use the `$env:` form above.

```bash
cd functions && npm run lint
firebase deploy --only functions,firestore:rules
```

- Add `,storage` when `storage.rules` changed. The target is **`storage`** —
  `storage:rules` is not a valid target.
- Add `,firestore:indexes` **only when `firestore.indexes.json` changed.** A new
  query whose index is missing fails `FAILED_PRECONDITION`, which the
  best-effort callers swallow into a silent no-op — so if you changed a query,
  you must deploy indexes.
  **An index deploy returns before the index is `READY`.** The deploy only
  *starts* the build, so a function or app build that needs a new index races
  it: check the Firestore console's Indexes tab before shipping the app, and
  expect a scheduled sweep to fail `FAILED_PRECONDITION` (and self-heal on its
  next run) in the gap. **Index EXEMPTIONS deploy the same way and are the
  slower direction to undo** — re-adding an override you removed rebuilds the
  index over the whole collection, so treat "which fields are exempt" as a
  decision, not a toggle. See the `fieldOverrides` note in `functions/CLAUDE.md`
  for what is exempt and why.
- **Never pass `--force`.** It treats any prod field override missing from
  `firestore.indexes.json` as drift and DELETES it — this removed all 5 live TTL
  policies once (2026-07-21).
- Single function: `--only functions:<name>`.

## 6. Verify

1. `functions_list_functions` — count matches `functions/index.js` exports, no
   orphans.
2. Spot-check logs for anything you changed (MCP `functions_get_logs`) — look
   for startup errors and for `unexpected-field`, which means an older build is
   hitting a narrowed allowlist.
3. **Smoke-test with the OLD build** if one is installed. This is the check that
   proves step 4 was right.
4. Only now cut / upload the new app build.

## 7. Rollback

Functions are versioned by deploy, not by tag, so rollback = redeploy the
previous source:

```bash
git stash                                   # or branch off
git checkout <last-deploy-commit> -- functions/ firestore.rules
firebase deploy --only functions,firestore:rules
git checkout HEAD -- functions/ firestore.rules
```

Rules roll back instantly and cleanly. Functions take a minute per function.
**Anything already written under the new rules stays written** — a rollback does
not un-write data, so a widened cap that let bad data in is not undone by
reverting the cap.

---

## Repo-specific traps

- **TTL policies live in `firestore.indexes.json`** as `fieldOverrides` with
  `"ttl": true`. They are not console-only state. See the `--force` warning above.
- **A deploy can ADD an index but never DELETE one — and the fix is not
  `--force`.** Removing an index from `firestore.indexes.json` does not remove
  it from prod; the deploy just reports the drift
  (*"there are N indexes defined in your project that are not present in your
  firestore indexes file"*) and moves on. `--force` is what deletes them, and
  it is banned here because it takes every prod TTL policy missing from the
  file with it — that is how all five were lost on 2026-07-21. So a deleted
  index sits as permanent drift unless someone acts out-of-band, which is
  exactly how the `(employeeIds CONTAINS, endTime …)` pair sat in these notes
  across several deploys.
  **Delete it targeted instead:** read the index id from Firebase MCP
  `firestore_list_indexes` (parent
  `projects/schedulingapp-88727/databases/(default)/collectionGroups/<coll>`)
  and pass it to `firestore_delete_index`. That removes exactly one index and
  cannot touch a TTL policy, so it is safe in a way `--force` is not. Then
  re-read the list to confirm both halves: the index is gone, **and** whatever
  index now serves those queries in its place is still `READY`. Done this way
  on 2026-08-29 for audit I9's
  `appointments (employeeIds CONTAINS, endTime ASC)`.
  One caveat to check BEFORE deleting: a wider composite that serves the same
  query as a *prefix* is `SPARSE_ALL`, so it omits any document missing one of
  its extra fields, where the narrower index did not. Confirm no live document
  relies on that difference, or the query silently stops returning rows.
- **TTL expiration offset must be `0`.** Every `expiresAt` in this app stores the
  *absolute* deletion instant; a non-zero offset silently multiplies retention.
  The offset is immutable once set — fixing one means delete → wait for it to
  disappear → recreate.
- **Deploying functions (re)activates App Check** (`enforceAppCheck: true`) on
  the callables. Expected and correct.
- **Secrets must already exist** in Secret Manager or binding fails at deploy:
  `GOOGLE_MAP_API_KEY`, `APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
  `WAVE_FULL_ACCESS_TOKEN`, `WAVE_BUSINESS_NAME`. Only the two functions that
  *bind* `APNS_SECRETS` may read them — otherwise every invocation logs a "No
  value found for secret parameter" warning.
- **Emulator only:** clearing app data regenerates the App Check debug token;
  re-register it in the console or every write fails `permission-denied` while
  cached reads still succeed (making it look collection-specific).
- **A deploy that REMOVES an export prompts for deletion — read the list before
  confirming.** Every deploy through 2026-08-04 was additive or flat, so each
  log row below says "no deletion prompt"; the `#compat-1.37.1` retirement
  (27 → 25, dropping `createEmployeeInvite` and `redeemSignupCode`) is the first
  that is not. Confirm the CLI names **exactly** the functions you intended and
  nothing else — an orphan the docs forgot about is deleted just as silently as
  an intended one. Deleting a callable is **not** reversible for a client build
  that still calls it: the call fails `not-found` immediately, everywhere, with
  no rollout window. Redeploying restores it, so the recovery is fast, but the
  outage starts the instant the delete lands. This is still never a reason to
  pass `--force`.

---

## DONE 2026-09-06: the indexed-search deploy — ORDERING IS THE WHOLE THING

> **This deploy has RUN**, in the four ordered steps below, across the three
> 2026-09-06 rows in the deploy log. Indexes first and alone (all four reached
> `READY`), then both prod backfills, then `functions` + `firestore:rules`
> (25 → 29). **Step 5, the app build, is the only one outstanding.** The steps
> are kept as the record of what the ordering was and why.

This release adds four callables (25 → 29) and moves client search, appointment
history search and the pre-save conflict check off capped client-side scans onto
indexed queries. It is a CREATE-only export change, so **neither known abort
fires** — no deletion prompt, no failure-policy prompt. What it does have is a
hard ordering requirement, and getting it wrong ships a search that finds
nothing rather than one that errors.

### The order

1. **`firestore:indexes` FIRST, alone**, and wait for both new composites to
   report `READY`: `clients (searchTokens CONTAINS, name ASC)` and
   `appointments (historySearchScopes CONTAINS, status ASC, startTime DESC)`.
   A query against a `CREATING` index fails `FAILED_PRECONDITION`.
2. **`firestore:rules`** — they bound the two new list fields at 240 entries and
   admit `locationSharingEnabled` on `/users`. **Rules before functions and
   before the app**: an app writing `searchTokens` against rules that don't
   allow it gets `permission-denied` on every client save.
3. **`functions`** — the four new callables.
4. **`node functions/scripts/backfill-search-tokens.js --dry-run`, then for
   real.** Every client and every terminal-status appointment written before
   this release carries no tokens, and a document with no tokens is invisible to
   the search that replaced the scan. **This is a prerequisite, not a
   follow-up** — the app build must not ship before it completes.
5. **Only then the app build.**

### Why rollback is awkward here

The app build is what calls the callables, so rolling BACK the functions after
the app ships breaks search outright (the old scan path is unreachable in a
shipped build — `firebaseFunctionsProvider` is non-nullable, so production never
takes the fallback). Roll back the app, not the backend. Deploying the backend
early is safe: 1.56.0 and earlier never call the new callables, and the token
fields they don't write are simply absent.

### Two things to verify after, not assume

- `functions_list_functions` returns **29**, matching `functions/index.js`.
- Run one real search from a signed-in admin build and one from a technician
  build. The technician case is the one worth doing by hand: their scope is
  baked into the token prefix, so a wrong scope shows as an empty result set
  rather than an error.

## DONE 2026-08-21: the simplified-auth deploy

> **This deploy has RUN** — see the `1c89892a` row in the deploy log below.
> The §1 pre-flight was re-queried at deploy time and returned zero `invited`
> users. The steps below are kept as the record of what was required and why,
> not as outstanding work. What IS still outstanding: shipping the 1.48.0+77
> app build, and republishing `docs/legal/support.html` by hand.


> Removes the `email_verified` guard from `completeEmployeeSetup`, replaces the
> shared starting password `Welcome123!` with a per-account random one
> (`generateStartingPassword()`), and stops `createEmployeeAccount` reading an
> `isAdmin` field. Design: `docs/archive/2026-08-21-simplified-auth-design.md`.
>
> **Shipped in the app as 1.48.0+77 (2026-08-21).** 1.47.0 is therefore the
> last build that sends `isAdmin`, which is what `#compat-1.47.0` in
> `employee_accounts.js` was pinned to.
>
> **RETIRED 2026-08-29.** The key is gone from the allowlist and is now
> refused as `unexpected-field`; the test that pinned its acceptance was
> flipped to pin the rejection. The gate this note said would not clear soon
> — correctly, at the time — has cleared: on the day 1.48 shipped the fleet
> was on **1.46.1 (74)** and **1.45.0 (72)**, not even 1.47.0, so pre-1.48
> admin builds were the NORM rather than a tail. The owner confirmed the
> whole fleet on **1.53** before the key came out.
>
> Two things to carry forward rather than the numbers. First, verify BOTH
> halves before retiring any `#compat-` key: that the current client no longer
> sends it, and that no older build which does is still in the wild — the
> second is the one that is easy to assume. Second, note what the delay cost:
> nothing. An accepted-and-ignored key is inert, so the safe move is always to
> wait, and the price of removing one early is that Create and Reset password
> both fail `invalid-argument / unexpected-field` on every stale device the
> moment the backend deploys, with no rollout window.

### 1. Pre-flight: remediate every `invited` account — REQUIRED

Before the backend deploy, query prod:

```
users where status == 'invited'
```

Every row this returns is an account minted under the old flow, so **its
Firebase Auth password is still the shared `Welcome123!`** — a value that is in
the git history, was rendered on every pending roster row, and is known to
every admin. The only thing standing between that and a takeover today is
`completeEmployeeSetup`'s `email_verified` guard, which demands control of the
mailbox rather than mere knowledge of the address. **This deploy removes that
guard.** The random password protects accounts minted *afterwards* and does
nothing for these — it is not a migration.

So each such row must be **re-provisioned or deleted before the guard goes**:

- **Reset password** (the pending roster row's button → `createEmployeeAccount`)
  issues a fresh random password *and* rewrites the doc's `role` to
  `"employee"`. Hand the new credentials over at that moment, not ahead of time.
- **Remove account** (`deleteEmployeeAccount`) if the person is not actually
  joining.

**Do the `role: 'admin'` rows first.** An `invited` doc is granted nothing by
`firestore.rules`, but the moment a race winner completes setup the account is
`active` with whatever role the doc carries — and `/clients` is
`allow read: if isAdmin()`, i.e. the whole client PII collection. A pre-empted
`employee` row is bad; a pre-empted `admin` row is a data breach.

**Status 2026-08-21: this step is DONE — the query returns zero rows.** The
owner deleted the one pending account. Verified two ways, because the
`runQuery` path was intermittently failing on clock skew and one empty result
is not evidence: a `status == 'invited'` query returned `{"documents":[]}`, and
an independent full `ListDocuments` of `users` returned **5 docs, every one
`status: 'active'`**. Their 5 `uid`s are a 1:1 match with the **5** accounts in
Firebase Auth, so nothing was orphaned — `deleteEmployeeAccount` deletes the
doc first and the Auth user second, and a failure between the two would have
left an Auth account with no doc. There is none. Every remaining account is
`active`, and activation cannot happen without `completeAccountSetup` having
replaced the password first, so **no account still holds `Welcome123!`**.
Re-run the query at deploy time anyway if more than a few days have passed —
an admin can mint a new pending account at any moment, and the guard this
deploy removes is what would otherwise protect it.

**If the query returns nothing, say so in the deploy log row** — the same way
the 2026-08-08 row records "Prod was queried first: **zero `invited` users**,
so nobody could be stranded mid-onboarding". A row that does not state the
count is indistinguishable from one where nobody looked.

### 2. Ordering

The remediation must land **before, or in the same window as, the backend
deploy** — never after. It is the deploy that drops the mailbox check, so any
gap between them is the exposure this step exists to close.

It is still *possible* to remediate from an old admin build after the deploy,
and that is not an accident: `createEmployeeAccount`'s `assertPayloadShape`
allowlist deliberately keeps `"isAdmin"` as an **accepted-and-ignored** key
(see §4a — the superset contract). The pre-change client sends that field
unconditionally on both create and Reset password, so had it been dropped, the
one tool the remediation runs on would have failed `invalid-argument /
unexpected-field` on every admin device that had not updated yet. Treat that
key as load-bearing until no build in the wild still sends it.

### 3. Rollback is NOT safe once the app build ships

Backend-only rollback is safe **only while the old app build is still the one
installed.** After the new build ships, a backend rollback permanently blocks
setup:

- The old backend throws `failed-precondition / email-not-verified`.
- `AuthService._mapSetupError` no longer maps that message, so it falls through
  to `AuthErrorMapper` → `AuthFailureUnknown` → "Something went wrong."
- There is no verification UI left to satisfy it — `verify_email_panel.dart`,
  `sendVerificationEmail`, `refreshEmailVerified` and
  `AuthFailureEmailNotVerified` were all deleted with this change.

So the employee is stuck behind an unactionable message with nothing to act on,
and every retry files a Crashlytics non-fatal, because `AuthFailureUnknown`
is `isExpected: false`. **A backend rollback after the app ships must be paired
with an app rollback.**

### 4. Republish `docs/legal/support.html`

Part of this deploy, not a follow-up. The **live** page on
`gvogas/es-pro-legal` still tells employees they cannot finish setup until they
open a verification link — a link this deploy stops sending. Editing
`docs/legal/` alone changes nothing anyone can read; the file must be copied to
that repo, byte-identical, when the backend goes out.

---

## DONE: the photo subcollection CONTRACT step

> **Phase 1 is DONE and shipped.** Its backend deployed 2026-08-14 at
> `9bda14cb`, the copy backfill ran against prod 2026-08-15
> (`copied 13 photos across 10 appointments (41 scanned)`, no unrenderable
> entries), and the app build that reads the subcollection shipped in 1.46.
> This section is the CONTRACT step that follows it: the `pictures` array is
> removed from the code, from the documents, and from everything that existed
> only to protect it.

The gate this waited on is **cleared**: no device still runs a build that reads
the array (the fleet is on 1.48). What changes:

- **Dart** — `AppointmentImagesStore` writes the subcollection only;
  `AppointmentRecord` drops `pictures` and `hasPictures` becomes
  `pictureCount > 0`; `addAppointments` writes an explicit `pictureCount: 0`;
  `ImageStorageService` stops minting a download URL (`downloadUrlFor` is
  deleted with it) and the offline queue's re-resolve step goes with it; the
  detail sheet reads its photos from the subcollection alone and the delete
  path stops enumerating Storage objects.
- **Functions** — `cascadeDeleteAppointmentImages` now deletes the Storage
  BYTES as well as the photo documents (bytes first, then documents, rethrowing
  either); `recountPictures` warns past `PICTURE_COUNT_WARN_CAP` (100);
  `appointment_image_tokens.js` and its `syncUsersByUid` call are **deleted**,
  and that trigger's `timeoutSeconds: 300` reverts to the default.
- **Rules** — `allow create` on `/appointments` accepts `pictureCount` when it
  is exactly 0. The `pictures` size cap STAYS, for documents the cleanup script
  has not reached; it is a cap, never a ban, or an edit of such a document
  would be refused.
- **Indexes** — `(employeeIds CONTAINS, endTime DESC)` is removed from
  `firestore.indexes.json`; it existed only for the token rotation. Prod will
  report it as drift. **Delete it in the console if it is worth the noise —
  never with `--force`**, which is how all five live TTL policies were lost in
  2026-07-21.
  **RESOLVED 2026-08-29: there was nothing left to delete.** This index is
  absent from the live list and has been for some time — the drift it warned
  about was carried forward in these notes rather than re-checked. Two
  corrections for whoever reads this next. First, the index deleted on
  2026-08-29 was a *different* one, audit I9's two-field
  `(employeeIds CONTAINS, endTime **ASC**)`; don't conflate them. Second,
  "delete it in the console" understates the constraint: a redeploy **cannot**
  delete an index at all, so the choice is not console-versus-deploy but
  console-versus-`--force`. The clean third option, and the one actually used,
  is a **targeted admin-API delete** (Firebase MCP `firestore_delete_index` on
  the index id from `firestore_list_indexes`), which removes exactly one index
  and cannot touch a TTL policy. Prefer it; `--force` stays banned.

### The ordering, which is the whole safety property

1. **Re-run the COPY backfill** (`--dry-run` first). It ran on 2026-08-15, but
   every build since has gone on writing the array, so anything added after
   that pass may exist only there. There is no array fallback left in the app:
   an appointment this misses shows **no photos at all**.
   ```bash
   node functions/scripts/backfill-appointment-images.js --dry-run
   node functions/scripts/backfill-appointment-images.js
   ```
   **DONE 2026-08-22 against `schedulingapp-88727` (LIVE)** — dry run and live
   run agreed exactly: **14 photos copied across 11 appointments, 55 scanned**.
   **Read that as a TOTAL, not a delta.** This script is idempotent and
   re-copies the whole set on every run, so 14 is every photo in every array,
   not 14 new ones on top of the 13/10 the 2026-08-15 pass reported — the real
   drift since then was **1 photo on 1 appointment**. (An earlier version of
   this note said "entirely on top of", which would have meant 27 documents;
   the S1 count below found exactly 14 in the subcollection, which is what
   settles it.) The re-run was still required: with no array fallback left in
   the app, that one photo would have shown as a job with no photos at all.
   The array was deliberately NOT modified — that is step 4.
2. **Deploy backend + rules.** No export count change. The rules change is a
   RELAXATION (`pictureCount == 0` on create) and must be live before the app
   build that writes it — an appointment create would otherwise fail
   `permission-denied`. Nothing here breaks 1.48: it neither sends
   `pictureCount` nor stops writing the array, and the array is still accepted.
3. **Ship the app build.** From here nothing writes `pictures`.
4. **Run the clear script**, `--dry-run` first, once the fleet has moved off
   the builds that still write the array — otherwise it clears a document a
   1.48 phone then re-populates.
   ```bash
   node functions/scripts/clear-appointment-picture-arrays.js --dry-run
   node functions/scripts/clear-appointment-picture-arrays.js
   ```
   It **refuses** any appointment whose subcollection does not already cover
   every array entry, and reports them — that is the signal to re-run step 1,
   not to force anything. An entry with no identity at all (no `storagePath`,
   no url) can never be covered and needs a person: clearing it destroys the
   only record the photo existed.
   **DONE 2026-08-27 against `schedulingapp-88727` (LIVE)** — dry run and live
   run agreed exactly: **cleared 14 array entries across 11 appointments (11
   still carried an array, 67 scanned)**. No refusals and no identity-less
   entries, which is what said the subcollection already covered every entry.
   **This run is what closed S1**: each array entry carried a permanent,
   non-expiring, rules-free `getDownloadURL()` link, readable off the
   appointment document by any assigned employee and surviving deactivation,
   with nothing left to rotate it since `rotateAssignedImageTokens` was
   deleted. Retiring the FIELD did not close that — only deleting these did.
   The fleet gate was read off step 1's re-run the same day: it reported the
   same **14 photos across 11 appointments** as the 2026-08-22 pass (67
   scanned, up from 55 purely because 12 more appointments exist), so no build
   still writing the array had added an entry in the five days since the
   CONTRACT build (1.49.0+78) shipped.

Steps 1–3 are safe in one sitting. **Step 4 is the irreversible one** and is
the only step that should wait.

**Rules validation stays a REQUIRED pre-flight** — the Firestore emulator needs
Java, which is not installed on this machine, so validate through the Firebase
MCP `firebase_validate_security_rules` before deploying. A rules release that
fails leaves the deploy half-applied.

Note the cost the `match /images/{imageId}` block adds, since it is the argument
against reaching for a subcollection casually: `parentAppointment()` is a
document `get()` on top of the `usersByUid` one every rule already pays, so an
employee listing a job's photos evaluates **two** rules reads. It is one per
query, cached per request, and it buys the far larger saving on the range
queries — but it is real.

---

## DONE 2026-08-14: a THREE-deletion deploy (25 → 22 → 25)

> **Deployed at `9bda14cb`** — see the log row. Kept as the worked record of how
> a deletion deploy is checked. **Step 2 below (the 3 orphaned Cloud Scheduler
> jobs) was NOT done** and is still outstanding: `gcloud` is not installed on
> the Windows box. The abort this section predicts did not fire — a *different*
> one did, on the new `retry: true` functions; both are now in the log row.

**Verified against `45302651` (what prod runs) on 2026-08-13, not from this
doc's own history — an earlier draft of this section said "25 → 24,
`waveSyncWorker` and nothing else" and was wrong on both counts.** Reproduce
the check before deploying:

```bash
git show 45302651:functions/index.js | grep '^exports\.' \
  | sed 's/exports\.\([a-zA-Z]*\).*/\1/' | sort > /tmp/prod.txt
grep '^exports\.' functions/index.js \
  | sed 's/exports\.\([a-zA-Z]*\).*/\1/' | sort > /tmp/local.txt
comm -23 /tmp/prod.txt /tmp/local.txt   # deletions
comm -13 /tmp/prod.txt /tmp/local.txt   # additions
```

**Deletions (3) — the prompt must name exactly these:**

| Function | Why it can go |
|---|---|
| `waveSyncWorker` | The Wave push is event-driven now: `waveUpsertCustomer` enqueues *and* drains. |
| `waveScheduledImport` | Folded into `sendDailyJobDigest`, which calls `runWaveDaily()` (`wave/callables.js`). Not lost — still the drain safety net for backed-off and stale-`inflight` jobs. |
| `sendOverdueJobPrompts` | Merged into `sendUpcomingJobReminders`; its per-recipient ledger, not the cadence, is what guaranteed at-most-once. |

**Additions (3):** `waveRetryFailedJobs`, plus the photo migration's
`cascadeDeleteAppointmentImages` and `recountAppointmentPictures`.

Net 25 → 25, so **the export COUNT tells you nothing here** — read the two
lists, not the total.

### 1. The deletion abort

Expect the **non-interactive abort** the 2026-08-08 row documents: the CLI
releases rules/indexes, uploads the source, then stops with "Aborting because
deletion cannot proceed in non-interactive mode", leaving prod on
new-rules + old-functions. Close it:

```bash
firebase functions:delete waveSyncWorker waveScheduledImport \
  sendOverdueJobPrompts --region us-central1
firebase deploy --only functions,firestore:rules,firestore:indexes  # never --force
```

`functions:delete --force` is **not** `deploy --force` — it only skips the y/n
prompt for the named functions and touches no index or TTL policy.

### 2. Delete THREE orphaned Cloud Scheduler jobs — RESOLVED 2026-08-23, there were none

**Checked at last: the Cloud Scheduler console holds exactly the 3 survivors,
so Firebase did remove the three entries when the functions were deleted.**
Nothing was deleted and nothing needs to be. The steps below are kept because
the failure mode they guard against is real and the next scheduled-function
deletion should still check — but check the **Cloud SCHEDULER** page, not Cloud
Run. That distinction is why this sat open for eight days: a deleted scheduled
function's Cloud Run service is gone either way, so the Cloud Run list looks
correct whether or not the scheduler entry survived, and it was the Cloud Run
list that kept being consulted.

**Checking it found something else, which is the real value of the exercise —
see the note directly below this section on `purgeExpiredHistory` being
PAUSED.**



Removing a scheduled function does not reliably remove its scheduler entry, and
**only 3 jobs are free** — leaving these behind bills for three jobs forever and
silently undoes the consolidation that created them.

Scheduled functions go from **6 to 3** in this deploy (`purgeExpiredHistory`,
`sendUpcomingJobReminders`, `sendDailyJobDigest` survive):

```bash
gcloud scheduler jobs list --location us-central1
# delete any that survive:
gcloud scheduler jobs delete firebase-schedule-waveSyncWorker-us-central1 \
  --location us-central1
gcloud scheduler jobs delete firebase-schedule-waveScheduledImport-us-central1 \
  --location us-central1
gcloud scheduler jobs delete firebase-schedule-sendOverdueJobPrompts-us-central1 \
  --location us-central1
```

Landing on exactly 3 is the point of the change. Verify the count afterwards.

### `purgeExpiredHistory` was PAUSED and nobody knew (found 2026-08-23)

Found while checking the scheduler item above, and the reason that check was
worth doing even though it turned up no orphans.

`firebase-schedule-purgeExpiredHistory-us-central1` was **Paused**, with "has
not run yet", created 2026-07-19. **Nothing in `docs/`, `.claude/` or the
commit history records it being paused or says why.** It has since been
**resumed** (owner, 2026-08-23).

**It had not silently missed a purge.** Its schedule is quarterly —
`0 3 1 1,4,7,10 *`, 03:00 America/Toronto on the 1st of Jan/Apr/Jul/Oct — and
it was created on 19 July, after that quarter's run. The first time the pause
would have mattered is **1 October 2026**, so the cost so far is zero and the
window to notice was closing rather than closed.

**A plausible reason it was paused, worth stating because it no longer
applies:** this is the only unattended, irreversible deletion in the repo, and
it had **zero tests until 2026-08-04**. Pausing an untested quarterly delete
job would have been the right call. `maintenance_policy.js` is now at 100%
lines and branches, with the three rules that destroy data if they regress each
pinned — the status gate (only `done`/`cancelled` are ever purged), the
ordering (images before documents), and loop termination.

**What to expect on 1 October 2026, the first run ever:** `HISTORY_RETENTION_YEARS`
is 2, so it purges terminal appointments whose `startTime` is older than two
years. This project's data does not reach back that far — the images backfill
scanned **55 appointments in the entire collection** on 2026-08-22 — so the
first run should purge approximately nothing. That is the good case, but it
also means **the first run that does real work will be the one with the largest
backlog it will ever have**; the 1800 s timeout and the paging loop are what
that rests on. Read the `purgeExpiredHistory: done` log line (it reports
`purged`, `imageFailures` and the `cutoff`) rather than assuming.

**Generalise the check, not the incident:** a scheduled function can be paused
in the console with no trace in the repo, and a paused job looks identical to a
healthy one in `functions:list` and in Cloud Run. After any deploy that touches
a scheduled function, look at the STATE column in Cloud Scheduler.

### 3. `firestore:indexes` and `firestore:rules` are BOTH required

`firestore.indexes.json` carries the new `(status, endTime DESC)` and
`(clientId, startTime DESC)` composites, the 23 single-field exemptions, and
the `images` subcollection exemptions. The overdue sweep (now inside
`sendUpcomingJobReminders`) fails `FAILED_PRECONDITION` until
`(status, endTime DESC)` reads **Ready**, and the app build must not ship until
the client-history composite does.

`firestore.rules` carries the photo subcollection's `match /images/{imageId}`
block and the `pictureCount` guards. **Validate the rules before deploying** —
they could not be compiled locally (the Firestore emulator needs Java, absent on
the dev machine), and the new block declares a nested function and calls `get()`
on the parent. A failed rules release leaves the deploy half-applied.

The CLI will report the `signupCodes` TTL override as unmatched drift and
correctly refuse to delete it without `--force`; that is expected and must stay
refused.

### 4. Then the photo migration's own ordering

Phase 1's own ordering, all of it now done: backend+rules first, then the
backfill, then the app build. The cascade trigger had to be live before any
photo reached the subcollection, and it was. The array's removal is the
CONTRACT step — see "Pending: the photo subcollection CONTRACT step" above.

---

## Per-release checklist

Copy this into the release PR / notes:

```
[ ] flutter analyze 0 · flutter test green · functions lint + jest green
[ ] rules validate (only the 3 isAvailabilityOnlyChange warnings)
[ ] recorded what is ACTUALLY live (functions:list), not what the docs claim
[ ] diffed functions/ + rules since the last deploy commit
[ ] every changed allowlist is a SUPERSET; every new field is optional
[ ] no rules cap is tighter than a shipped client OR callable write path
[ ] indexes: unchanged → omit target · changed → include it
[ ] if any export was REMOVED: deletion prompt lists exactly those, nothing else
[ ] deployed backend  (no --force)
[ ] verified function count + logs
[ ] smoke-tested with the OLD build
[ ] THEN cut the app build
[ ] appended a row to the Deploy log below
```

---

## Deploy log

Keep this current — step 3 depends on it, and it is the only reliable record of
what production is running.

| Date | Commit | Targets | Fns live | Notes |
|---|---|---|---|---|
| 2026-07-18 | — | functions, rules | 21 | `placesReverseGeocode`, travel-aware reminder rebuild |
| 2026-08-01 | `16332b3` | functions, rules | 22 | P3 clients; added `recountClientJobs` |
| 2026-08-03 | `7464e3b` | functions, rules | 25 | P4 + P4b + **P4c**: added `createEmployeeAccount`, `completeEmployeeSetup`, `deleteEmployeeAccount`; `private/emergency` rule; `isValidAppointmentData`. **Deleted nothing** — `revokeInvite`/`previewInvite` were never deployed (prod had 22, not the 24 an earlier draft of this row assumed), and `createEmployeeInvite`/`redeemSignupCode` were **kept as the `#compat-1.37.1` shim** for the 1.37.1+64 build on the App Store. No deletion prompt; 22 → 25. `firestore:indexes` omitted (file already in sync with prod). Verified post-deploy: 25 functions live, all three shim rules present, zero `unexpected-field` in logs. See the shim note above. |
| 2026-08-04 | `9a43b38` | functions | 27 | Employee email → Auth sync: adds `changeEmployeeEmail` (26 → 27), which moves the sign-in email in Firebase Auth AND on the `users` doc together and is what re-enables the read-only email field in `edit_person_sheet`. It also pushes the employee a `kind:"emailChanged"` notice naming the new address (best-effort, after the commit). **Deploy BEFORE the app build ships** — the client calls it from inside `updateEmployee` whenever the email changed on a doc carrying a `uid`, so an un-deployed function turns every such save into a `not-found` and the admin cannot save the person at all. No rules change (`email` was already admin-writable on `/users`, and this write is Admin SDK anyway) and no index change, so `firestore:rules`/`firestore:indexes` are optional here. 1.37.1 is unaffected: it never calls this, and its Firestore-only email edit keeps working exactly as before (desynced, as it always was). Verified post-deploy: 27 functions live and an exact match against `index.js`'s 27 exports (no orphans), `changeEmployeeEmail` ACTIVE with its startup TCP probe passing on the first attempt. No deletion or secret prompts. Deployed without `--force`. A second run the same day added `firestore:rules,storage` for completeness — both were already byte-identical to prod (unchanged since the `ef3a9cf` rules deploy), so the CLI skipped both uploads and merely re-released them, and every function reported "Skipped (No changes detected)". Rules compiled with only the 3 known `isAvailabilityOnlyChange` warnings. `firestore:indexes` still deliberately omitted (file in sync with prod). Both runs went out from an uncommitted tree; that tree was committed as `9a43b38` immediately after, which is the hash above. |
| 2026-08-03 | `ef3a9cf` | functions, rules, **indexes** | 26 | Client archive + delete: adds `deleteClient` (25 → 26), gated on a live `count()` of the client's appointments; `isValidClientData` accepts `archived` (optional, so 1.37.1 writes still pass). **`allow delete` on `/clients` is KEPT** as a second `#compat-1.37.1` shim entry (owner call 2026-08-03) — 1.37.1+64 ships an ungated Delete button doing a direct `doc.delete()`, and withdrawing the grant would fail it with an opaque `permission-denied`. Nothing in the new build uses it. **`firestore:indexes` IS required** — new `(archived, name, __name__)` composite for the list's server-side `where('archived','==',false)`. Backfill ran BEFORE the deploy, as required (Firestore excludes docs missing a filtered field, so an un-backfilled client vanishes from the list the moment the app build ships): **674 patched, 0 already had the field**; the confirming dry-run then reported `0 patched, 674 already had the field`. Verified post-deploy: 26 functions live, `deleteClient` ACTIVE with a clean startup probe, zero `unexpected-field` in logs, rules compiled with only the 3 known `isAvailabilityOnlyChange` warnings. **The `(archived, name, __name__)` index was still `CREATING` when the deploy finished — the app build must NOT ship until it reads `READY`,** or the list query fails `FAILED_PRECONDITION`. Deployed without `--force`. (The first `firebase deploy` invocation exited 9 at the tail; an immediate re-run reported every function "Skipped (No changes detected)" and exited 0, so the first run had in fact converged.) |

| 2026-08-04 | (audit pass, uncommitted at deploy time) | functions, rules, storage | 27 | **Codebase-audit fixes. No export change** — 27 → 27, so no deletion prompt. Backend halves of the multi-day gaps: the push diff now gates on the run's END (`hasWorkLeft`) so a job cancelled mid-run still reaches its crew; the overdue floor widens to 24h + 14d; the digest queries and buckets on OVERLAP with tomorrow and orders by clock time. Hardening: `toIdList` rejects slash/over-long ids (one poisoned `employeeIds` element could reject the whole `Promise.all` digest batch and silence it nightly), `runDailyDigest` is wrapped like the reminder sweep, `waveSetImportSchedule` gains a 20/hr durable limit, and the travel context query warns at its 50-doc cap. `maintenance_policy.js` added as an internal module (NOT an export) so `purgeExpiredHistory` — the only unattended irreversible deletion — is testable. **Rules: additive caps only** — `pictures` ≤ 100 and `isValidDocIdField(seriesOpId)` on `isValidAppointmentData`; both pass anything either build writes. **Two fixes were REVERTED before deploying**, each after review showed it traded a known gap for a worse one: an `email_verified` gate on `redeemSignupCode` (1.37.1 redeems on an unverified token and would have deleted the account it just created — every invite on the App Store build), and widening `MAX_BOOKING_MS` to 14d (`decideOrigin` tests raw instants, so a long run becomes a wrong origin at any hour). Verified post-deploy: 27 live matching `index.js`, zero ERROR log entries. Deployed without `--force`. |

| 2026-08-04 | `fd6a1c47` | functions, **rules** | 27 | **Second codebase-audit pass. No export change** — 27 → 27, verified identical to `functions/index.js` before deploying, so no deletion prompt. Functions: `propagateClientEdits` now floors its query at `now − MAX_APPOINTMENT_SPAN_MS` and filters on `endTime` (a client edit was skipping any job already under way); `countFutureAssignments` same fix client-side; `runTravelAwareReminderSweep` flattened to `Promise.all`; `deleteAccount`'s orchestration extracted to the new `account_policy.js` (behaviour unchanged, response still `{deleted:true}`). **Rules: `emergencyFieldNotSet` added to `/users` `allow update`** — the emergency pair may now be REMOVED but never WRITTEN, closing the peer-readable-PII hole. Deliberately NOT the flat denylist the audit first proposed: that form rejects the `FieldValue.delete()` scrub and would brick any doc still carrying the pair. **No backfill needed or run** — owner confirmed no emergency contact has ever been entered, and the guard is safe either way; `scripts/backfill-emergency.js` deleted. **Old-build check:** `emergencyContact` does not exist anywhere in `lib/` at `v1.37.0+62`, so the 1.37.1+64 App Store build never writes those fields and cannot be broken by this rule. No `assertPayloadShape` allowlist or `requireString` cap changed. `firestore.indexes.json` and `storage.rules` unchanged → both targets omitted; every changed query kept its existing index shape. Deployed without `--force`. Rules deployed twice (a stale comment on `allow create` was corrected in the second pass). Verified post-deploy: 27 functions live, rules released, clean `STARTUP TCP probe` on all changed functions, zero `unexpected-field`. |

| 2026-08-04 | `bdea87e8` | functions, rules, storage | 27 | **Two-way Wave sync (1.43.0+68). No export change** — 27 → 27, diffed against `functions/index.js` before deploying, so no deletion prompt. `waveImportCustomers` now drains the outbox to Wave (`drainForSync`, bounded 20 jobs / 20 s) BEFORE importing, and returns five additive fields (`pushedCreated`/`pushedUpdated`/`pushedPending`/`pushedFailed`/`pushIncomplete`). **Additive only — 1.37.1 parses the import half by name and ignores the rest**, and its Import button simply also pushes now, which the 5-minute `waveSyncWorker` does anyway. No `assertPayloadShape` allowlist changed (still `new Set()`), no `requireString` cap changed, no rules or index change → `firestore:rules,storage` were re-released byte-identical for completeness. **Two data-loss fixes ride along, both pre-existing:** `importCustomers` now takes a `skipClientIds` protect-list from `listOutstandingClientIds` (an import was overwriting a client whose edit was still queued AND re-stamping `wave.lastSyncedHash`, so the pending push then no-opped and the edit vanished with the row reading "synced"); and the import is hash-gated, skipping any client whose stored hash already matches, which cuts a steady-state run from ~650 writes + ~650 `waveUpsertCustomer` invocations to ~0 and stops the app reporting "650 clients updated" after a sync that changed nothing. **`waveScheduledImport` gets the same protect-list** and needed it more — it runs unattended. Deployed without `--force`. Verified post-deploy: 27 live, exact match against the 27 exports (no orphans, no extras), rules + storage released, and zero ERROR entries on any changed function — the only two errors in the window were `redeemSignupCode` rejecting a non-POST rollout probe (correct behaviour, untouched by this change). The "request was not authenticated" warnings on the scheduled/trigger functions are the usual rollout-probe noise, matching the identical cluster at every prior deploy. **App build 1.43.0+68 can ship now** — this had to land first, since against the old backend the "Sync with Wave" button would have been a pure clobbering import. |
| 2026-08-08 | (release 1.44.0+70, uncommitted at deploy time) | functions, rules, **indexes** | **25** | **The `#compat-1.37.1` retirement — the repo's FIRST deletion deploy** (27 → 25), plus the 2026-08-08 codebase audit and the 1.43.1 Wave heal. **Deleted: `createEmployeeInvite`, `redeemSignupCode`** — the deletion list named exactly those two and nothing else. Gate was owner confirmation that every device is on 1.40+. `redeemSignupCode` was the last unauthenticated callable in the codebase. **The CLI ABORTS on deletion in non-interactive mode** — it released rules and indexes, uploaded the function source, then stopped with "Aborting because deletion cannot proceed in non-interactive mode", leaving prod on new-rules + old-functions. That half-state is safe (the removed grants are unused by any shipped build) but must be closed. Fix is the CLI's own suggestion, `firebase functions:delete <name> --region us-central1`, then re-run the deploy; **`functions:delete --force` is NOT `deploy --force`** — it only skips the y/n prompt for the named functions and touches no index or TTL policy. Record this: any future deploy that removes an export will hit the same abort. **Rules: removals only** — `allow delete` withdrawn from `/users` and `/clients`, the `/signupCodes` block and the 4th `/users` read clause deleted. No cap changed, nothing added, so no shipped write path can be broken. **`firestore:indexes` included** (the `signupCodes` TTL `fieldOverride` was dropped from the file). The CLI reported "1 field override defined in your project that is not present in your indexes file" and **correctly refused to delete it without `--force`** — so the live `signupCodes` TTL policy REMAINS. Left deliberately: the collection was verified empty in prod before the deploy and rules now deny all access, so it reaps nothing and costs nothing. Never `--force` this away (it deleted all 5 live TTL policies in 2026-07-21). **Compatibility check:** every `assertPayloadShape` allowlist and every `requireString`/`optionalString` cap byte-identical to `bdea87e8` — no narrowing, no new required field. **`completeEmployeeSetup` gained an `email_verified` identity guard** (above the rate limiter). Prod was queried first: **zero `invited` users**, so nobody could be stranded mid-onboarding. It is still a real forward constraint — **do not create an employee account until app build 1.44.0+70 ships**, because the shipped 1.43.x setup screen has no way to send or confirm a verification email. `storage.rules` unchanged since `bdea87e8` → target omitted. Deployed without `--force`. **Verified post-deploy:** 25 live, exact match against `index.js`'s 25 exports (no orphans, no extras); a confirming `--only functions` re-run reported all 25 "Skipped (No changes detected)", proving prod's source matches local; clean `STARTUP TCP probe succeeded after 1 attempt` on all 25; zero `unexpected-field` and zero `email-not-verified`. The only ERROR entries are 12 `Invalid request, unable to process.` at 21:14:38-53 — two per callable, the Cloud Run rollout probe hitting `onCall` with a non-callable request, the same benign cluster as every prior deploy. **Zero errors after the deploy window.** |
| 2026-08-11 | `258cc91a` | functions, rules, storage | 25 | **Release 1.45.0+72 — closes the 2026-08-08 → 2026-08-11 gap.** No export change (25 → 25, diffed against `functions/index.js` first), so **no deletion prompt and no abort** — the 2026-08-08 row's warning did not apply. What moved is the code behind the existing 25: `changeEmployeeEmail`'s self branch, its non-admin re-auth freshness gate and its 20/hr → 5/hr budget; `travelAlertsEnabled` read BEFORE the Routes call so an opted-out tech costs no estimate and gets the fixed 30-min lead; the multi-day Live Activity skip and the crew-colour parse in `travel_utils.js`; the new internal `day_slice_utils.js` day-scoping behind the widget payload and push text; the single `TERMINAL_STATUSES` owner in `time_utils.js`; and `notifyAdminsOfSelfEmailChange` on the shared active-admins fan-out. **Rules: two additions** — P5's `isAvailabilityOnlyChange` self-service clause on `/users` `allow update`, and `isValidAppointmentSpan` on appointment create/admin-update. The span bound carries a deliberate **+2h DST allowance**: the app counts calendar days against local wall-clock instants while CEL's `duration.value` is absolute, so a flat 14d would have refused the widest booking the form can save for about two weeks each autumn, as an opaque `permission-denied`. `firestore.indexes.json` unchanged since `ef3a9cf` → **`firestore:indexes` deliberately omitted**, which also keeps the surviving `signupCodes` TTL policy untouched. `storage.rules` unchanged → the CLI skipped its upload and merely re-released it. Deployed without `--force`. Pre-flight: `npm run lint` clean, **902/902 jest** passing. **Verified post-deploy:** all 25 reported "Successful update operation", `functions_list_functions` returns exactly the 25 exports (no orphans, no extras), rules + storage released. Log check found **zero real errors** — the only ERROR/WARNING entries in the window are the recurring `Request has invalid method. GET` / `Invalid request, unable to process.` pairs, the Cloud Run rollout probe hitting `onCall` endpoints, identical to the benign cluster at every prior deploy; a severity≥ERROR query excluding that one class returned an empty set. |
| 2026-08-11 | `45302651` | functions, rules, storage | 25 | **Closes the second 2026-08-11 audit — the only backend change since `258cc91a` is `maintenance.js`.** No export change (25 → 25, diffed against `functions/index.js` first), so no deletion prompt. The I6 refactor moves `purgeExpiredHistory`'s image-validation decisions into the pure `maintenance_policy.js` sibling, which is what makes them testable at all — `maintenance.js` resolves a Storage bucket at load and throws on `require()` outside the emulator. Behaviour is unchanged: the status gate (only `done`/`cancelled` are ever purged), the images-before-doc ordering, and the no-progress loop termination are the three rules that destroy data if they regress, and all three are now pinned by the new `image_validation_policy.test.js` (212 lines). **No rules change** — both `firestore.rules` and `storage.rules` were already byte-identical to prod, so the CLI reported "already up to date, skipping upload" and merely re-released them. `firestore:indexes` deliberately omitted again (file unchanged since `ef3a9cf`), which keeps the surviving `signupCodes` TTL policy untouched. Deployed without `--force`. Pre-flight: `npm run lint` clean, **921/921 jest across 41 suites** passing (up from 902 — the new suite). **Verified post-deploy:** all 25 reported "Successful update operation" and `functions_list_functions` returns exactly the 25 exports (no orphans, no extras). Log check found **zero real errors**: `purgeExpiredHistory` itself logged nothing new — a module-load throw would have failed the deploy outright, not merely logged — and every ERROR entry in the deploy window is the same `Invalid request, unable to process.` CORS/https-layer shape as the benign clusters at the 2026-08-04 and 2026-08-08 deploys, i.e. the Cloud Run rollout probe hitting `onCall` endpoints unauthenticated. |
| 2026-08-14 | `9bda14cb` | functions, rules, **indexes** | 25 | **The three-deletion swap + the photo subcollection migration's phase 1.** Deleted `waveSyncWorker`, `waveScheduledImport`, `sendOverdueJobPrompts`; added `waveRetryFailedJobs`, `cascadeDeleteAppointmentImages`, `recountAppointmentPictures` — net 25 → 25, so the count proves nothing and the two lists were diffed against **live prod** (which matched `45302651`'s exports exactly) before touching anything. **A NEW failure mode, not in this runbook until now: `firebase deploy` ABORTS with `Error: Pass the --force option to deploy functions with a failure policy`.** The two new photo triggers are the first `retry: true` functions to be *newly created* here, and the CLI wants confirmation of the failure policy non-interactively; the 2026-08-08 deletion abort is a *different* abort and this one fires earlier — nothing at all was released on that first attempt. Resolved by **splitting the deploy** rather than reaching for a whole-target `--force`: `firebase deploy --only firestore:rules,firestore:indexes` (no `--force`, so the surviving `signupCodes` TTL override was reported as drift and **correctly refused** — it remains live), then `firebase functions:delete waveSyncWorker waveScheduledImport sendOverdueJobPrompts --region us-central1 --force` to keep the removal explicit and auditable rather than silently absorbed, then `firebase deploy --only functions --force`. **With no firestore target in scope, `--force` cannot reach an index or TTL policy** — the same scoping that makes `functions:delete --force` safe. Record this: any future deploy that ADDS a `retry: true` function hits the same abort. **Compatibility check:** every `assertPayloadShape` allowlist and every `requireString`/`optionalString` cap byte-identical to `45302651` — no narrowing, no new required field; the one added allowlist belongs to the new `waveRetryFailedJobs`. All three deleted functions are scheduled/server-only with **zero references in `lib/` or `ios/`**, so no shipped build can hit a `not-found`. **Rules: additive** — the photo subcollection's `match /images/{imageId}` block and the `pictureCount` guards; validated clean via the Firebase MCP `firebase_validate_security_rules` *before* deploying (the emulator needs Java, absent on this box — the MCP tool works without it and closes the gap this doc previously flagged as unverifiable locally). **`firestore:indexes` required** — the file gained 166 lines. Pre-flight: `npm run lint` clean, **1100/1100 jest across 46 suites**. **Verified post-deploy:** 3 creates + 22 updates all "Successful", `functions_list_functions` returns exactly the 25 exports (no orphans, no extras). Log check found **zero real errors** — every ERROR entry in the whole retained window (40, back to 2026-08-04) is the same `Invalid request, unable to process.` CORS-layer shape, the Cloud Run rollout probe hitting `onCall`; today's 8 all sit inside the deploy window. **Two indexes were still `CREATING` at completion — `(status, endTime DESC)` and `(clientId, startTime DESC)`, exactly the two this doc names as gating.** The overdue sweep inside `sendUpcomingJobReminders` fails `FAILED_PRECONDITION` and self-heals on its next run until the first is `READY`; **the app build must not ship until the second is.** **NOT DONE in this deploy, both still outstanding:** the 3 orphaned Cloud Scheduler jobs (`gcloud` is not installed on this Windows box — scheduled functions must land on exactly 3, and only 3 are free), and the appointment-images backfill. The client-name and phone-formatting backfills had already been run against prod earlier the same day (504 renamed, 142 reformatted) and must NOT be re-run. |
| 2026-08-15 | `201b93b9` | functions, rules, **indexes** | 25 | **Closes the 2026-08-15 codebase audit (41 findings).** No export change (25 → 25), diffed against **live prod** before touching anything, so **neither known abort fired** — no deletion prompt and no failure-policy abort. `waveUpsertCustomer` moved module (`wave/callables.js` → the new `wave/triggers.js`) but keeps its export name, so it is an UPDATE, not a create; the `retry: true` abort only fires on newly-created ones. **Compatibility check:** every `assertPayloadShape` allowlist byte-identical to `9bda14cb`, no new required field, no narrowed cap. The new `requireDocId` helper in `security.js` replaces three restated call sites (`clients.js`, `employee_accounts.js` ×2) at the SAME 128 cap, adding only a `/` reject — no legitimate document id can contain one. **Rules: two WIDENINGS that fix live rejections, one tightening no shipped build can reach, one new cap.** `clientName` on appointments **200 → 401** (it is the DENORMALIZED display name, composed by `ClientRecord.displayName` from two 200-char halves; sized to `personName` it was rejecting whole appointment saves with an opaque `permission-denied`) and client `address` **500 → 533** (`AddressParser.canonicalFrom` joins the 500-char street with the 32-char apt). The tightening adds `resource.data.status != 'cancelled'` to the employee mark-done branch, closing a hole where an assignee could put `done` over `cancelled` and resurrect a cancelled visit as a completed one — verified safe against the shipped build: **1.45.0+72's `DetailsActionBar` already gates on `hasStarted && !isDone && !isCancelled`**, so it never sends that write. **THE ONE ACCEPTED RISK: a new 500-char cap on `clients.addressLine2`.** The DEPLOYED `9bda14cb` import wrote that field **uncapped** (`IMPORT_FIELD_CAPS` had no entry for it; this commit adds one), so any prod client doc over 500 chars is now permanently un-updatable from the app. **Prod could not be inspected to confirm none exists** — every Firebase MCP Firestore read fails `The requested 'read_time' cannot be in the future`, because this Windows box's clock runs ahead of Google's (`firebase deploy` sends no `read_time` and is unaffected). Owner accepted the risk on the reasoning that Wave models `addressLine2` as a short peer street line and that rules roll back instantly and cleanly. **If an opaque `permission-denied` ever appears on an ordinary client save, check this field FIRST.** Also added: a declarative `match /appointmentRecountClaims/{appointmentId}` block (`allow read, write: if false`) — there is no `match /{document=**}` catch-all in this file, so the collection was already default-denied and this changes no behaviour. **`firestore:indexes` required** — it adds the `appointmentRecountClaims.expiresAt` TTL policy and a `presence.updatedAt` override. The surviving `signupCodes` TTL override was again reported as drift and **correctly refused** without `--force`; it remains live. `storage.rules` unchanged since `bdea87e8` → target omitted. Deployed without `--force`. **Pre-flight:** `npm run lint` clean, **1160/1160 jest across 47 suites**; `firestore.rules` validated clean via the Firebase MCP — note the **3 `isAvailabilityOnlyChange` warnings this doc lists as "expected, ignore" are now GONE**, exactly as predicted once P5 wired the function up. **Verified post-deploy:** all 25 reported "Successful update operation" (0 creates, 0 deletions), `functions_list_functions` returns exactly the 25 exports (no orphans, no extras), rules released. Log scan: **zero `unexpected-field`, zero `permission-denied`**, no `Cannot find module`/`SyntaxError`/startup failures. The only ERROR entries in the deploy window are 2 `Invalid request, unable to process.` on `waveRetryFailedJobs` — the same benign Cloud Run rollout probe hitting `onCall` as at every prior deploy (38 of the 40 retained ERROR entries are that one shape). **TWO REAL FAILURES SURFACED THAT PREDATE THIS DEPLOY BY ~8h AND ARE UNRELATED TO IT:** `WAVE-WORKER dead-lettering job` for clients `GAQJI0Ctadf8ppVHbSOE` (02:29:30Z) and `6GKdxhkzWH8HWYjwrolZ` (04:07:42Z), both `WaveApiError` / `errorKind: graphql` / `retryable: false`, so both customer upserts are sitting dead-lettered and will NOT self-heal — run `waveRetryFailedJobs` or investigate the GraphQL rejection. **Still outstanding, unchanged by this deploy:** the 3 orphaned Cloud Scheduler jobs (`gcloud` is not installed on this box) and the appointment-images backfill. |
| 2026-08-15 | `c167fcbf` | functions, rules, storage | 25 | **The root-cause fix for the two dead-lettered Wave upserts the previous row flagged as open — `functions/wave/` only.** No export change (25 → 25, diffed against `functions/index.js` and against live prod before touching anything), so **neither known abort fired**: no deletion prompt and no failure-policy abort. `retry_policy.js` is a NEW file but an internal module, not an export, so it creates no function. **What was actually wrong: `toCountryCode`/`toProvinceCode` could emit values outside Wave's GraphQL ENUM vocabulary, and that is a permanent kill, not a dropped field.** An unrecognised enum value fails variable coercion, so Wave answers with a *top-level* GraphQL error rather than a per-field `inputErrors` entry — the worker classifies that non-retryable and dead-letters the job, and a `dead` job never retries on its own. Two ways in, both reachable from one typo in one address: `toCountryCode` accepted any `/^[A-Z]{2}$/`, so a province typed into the country box ("ON", "QC") was sent as a country code; and a plain 2-letter province was prefixed `CA-` **unconditionally**, so a US client in "NY" went as the non-existent `CA-NY`. Both are now membership tests against real ISO-3166-1 / ISO-3166-2 sets, the country is resolved FIRST so it decides which country's subdivisions a bare "QC"/"NY" is read against, and a value that isn't a real subdivision is **omitted** — one missing address line beats a client that can never sync again. Also in: `graphql` errors that look transient (internal/timeout/unavailable, which Wave returns on HTTP 200) are now retryable; a rate-limited job gets a 20-attempt budget instead of the ordinary 5, because a rate-limit says nothing about whether the payload can ever succeed and a bulk backfill enqueues hundreds at once; the dead-letter log gains `errorDetail` (PII-free) because `sanitized` flattens every transport failure to "WaveApiError(graphql)" and without it a dead job is undiagnosable. **`waveRetryFailedJobs`' RESPONSE gains a `failed` key** — same null-is-unknown contract as `pushed` — since the drain behind a requeue usually dead-letters the same job again inside the same call, leaving the queue's dead count unchanged while the app, seeing only `requeued`, announced success. **No request-side change anywhere:** every `assertPayloadShape` allowlist and every `requireString` cap is byte-identical to `201b93b9`, so no shipped build can be broken by this; the added response key is ignored by any build that doesn't read it, and backend-first ordering is preserved for the build that will. **No rules and no index change** — `firestore.rules` and `storage.rules` were already byte-identical to prod (`"already up to date, skipping upload"`, merely re-released) and `firestore.indexes.json` is untouched, so `firestore:indexes` was deliberately omitted and the surviving `signupCodes` TTL override was never at risk. Deployed without `--force`; no secret prompt (`WAVE_FULL_ACCESS_TOKEN` v1 still the only binding). **Pre-flight:** `npm run lint` clean, **1209/1209 jest across 48 suites** (up from 1160 — the new `wave_retry_policy.test.js` plus mapper and callable cases). **Verified post-deploy:** all 25 reported "Successful update operation" (0 creates, 0 deletions), `firebase functions:list` returns exactly 25 matching the exports, rules + storage released; the two changed surfaces rolled to `waveupsertcustomer-00044-ciq` and `waveretryfailedjobs-00003-kuj`, both `ACTIVE` with startup TCP probes passing on the first attempt, no `Cannot find module`/`SyntaxError`/startup failure. **ACTION LEFT: the two dead-lettered jobs are still dead and will NOT self-heal** — clients `6GKdxhkzWH8HWYjwrolZ` and `GAQJI0Ctadf8ppVHbSOE`, last re-dead-lettered 16:05Z today, before this deploy. They now stand a real chance of succeeding because the payload changed, which was not true at the previous row: press **Settings › Retry failed** (or invoke `waveRetryFailedJobs`) and read the new `failed` count rather than `requeued` to know whether it worked. If they dead-letter a third time, the new `errorDetail` in the `WAVE-WORKER dead-lettering job` log line names the actual GraphQL refusal. **Still outstanding, unchanged by this deploy:** the 3 orphaned Cloud Scheduler jobs, the appointment-images backfill, and the accepted `clients.addressLine2` cap risk from the previous row. |
| 2026-08-15 | `ccb703e0` (merged as `86bbc462`) | functions, rules, storage | 25 | **The SECOND Wave fix of the day, and the one that actually unblocks the two dead-lettered upserts — `functions/wave/customers.js` only.** No export change (25 → 25, `functions/index.js` untouched), so neither known abort fired. **Found because the previous row's deploy made it visible:** `errorDetail` on the dead-letter log line turned "WaveApiError(graphql)" into `codes=[NOT_FOUND] fields=[customerPatch]`, i.e. a `waveCustomerId` pointing at a customer that had been **deleted in Wave**. Note what that means for the previous row's diagnosis — the enum-coercion bug was real and worth fixing, but it was NOT what these two jobs were dying of. **Why this class of dead-letter was unrecoverable in a way ordinary ones are not: the offending value is STORED on the doc.** Wave reports a missing patch target as a top-level GraphQL error (so it arrives as the correctly-non-retryable `WaveApiError('graphql')`) or, equivalently, as a `NOT_FOUND` inputError; either way every later push and every "Retry failed" press re-sent the same missing id and failed identically, so the Settings row read "2 clients failed to sync" with no way to clear it. `upsertCustomer` now routes both shapes (`isStaleCustomerLink` / `hasNotFoundInputError`) into the create path **with the identity search FORCED on** — the same route a crashed create takes, and what stops a spurious `NOT_FOUND` minting a duplicate customer instead of relinking. `writeSyncSuccess` needed the matching exception: it sets `waveCustomerId` only on a doc that is still *unlinked* (that is what keeps it idempotent), so the healed link would never have persisted — `replacesLink` is that carve-out, conditioned on the stale id still being the one on the doc, so a link established concurrently is newer, unproven-dead, and wins. Predicates are deliberately narrow (a structured `NOT_FOUND` code, never a text match on Wave's message): this is the one path that REWRITES a client's Wave identity. **No rules, index, payload or secret change** — both rules files were byte-identical to prod and merely re-released, `firestore:indexes` omitted, every `assertPayloadShape` allowlist and `requireString` cap identical to `c167fcbf`. Deployed without `--force`. **Pre-flight:** `npm run lint` clean, **1215/1215 jest across 48 suites** (up 6 — the stale-link cases). **Verified post-deploy:** all 25 "Successful update operation" (0 creates, 0 deletions), `firebase functions:list` returns 25 matching the exports, rules + storage released, `waveUpsertCustomer` rolled to a new revision at 01:05:20Z with its startup TCP probe passing first attempt. **The log scan mattered more than usual here** — this change adds a **module-scope `require("./client")` to `customers.js`**, and a require cycle would surface exactly as a startup failure; the scan for `Cannot find module` / `SyntaxError` / circular-require / any ERROR in the window came back **empty**. (The cycle is genuinely absent: `client.js` requires only `./auth`, lazily.) **Deployed from a tree that was uncommitted on `redesgin` at the time** (`git status` showed the 4 files staged, HEAD at `73119efc`), as the `9a43b38` row once was. The same 4-file change had in fact been committed in parallel as `ccb703e0` "touch up" (21:00:56 EDT, minutes before the deploy finished), so the code hash above is that one; `86bbc462` is the merge that brought it together with this file's previous row, and its `functions/` tree is byte-identical to `ccb703e0`'s — verified with `git diff ccb703e0 HEAD -- functions/`. Nothing was deployed that is not in the history; the two hashes are one change. **ACTION LEFT, now with a real recovery path:** press **Settings › Retry failed** once for clients `6GKdxhkzWH8HWYjwrolZ` and `GAQJI0Ctadf8ppVHbSOE` — they relink or recreate instead of failing, where before this deploy the press was guaranteed to fail. Read the `failed` count, not `requeued`. **RESOLVED 01:08Z** — the press landed and both clients are relinked. The log tells it in three presses: 16:05Z requeued 2 → both dead-lettered (pre-`c167fcbf`, no `errorDetail`); 00:55Z requeued 2 → both dead-lettered *with* `errorDetail: codes=[NOT_FOUND] fields=[customerPatch]`, naming the real cause; **01:08Z requeued 2 → no dead-letter lines at all**, followed at 01:08:41/43 by `waveupsertcustomer` + `propagateclientedits`, i.e. `replacesLink` persisting the healed `waveCustomerId` and the re-fired trigger returning at rule 1 on the unchanged hash. **Verifying a Wave retry without Firestore access: the signal is the ABSENCE of a `WAVE-WORKER dead-lettering job` line after `WAVE-RETRY requeued`** — `npx firebase functions:log --only waveRetryFailedJobs` is enough. **Still outstanding:** the 3 orphaned Cloud Scheduler jobs and the accepted `clients.addressLine2` cap risk; the appointment-images backfill ran later the same day (see the migration section above). |
| 2026-08-16 | (follow-up audit pass, uncommitted at deploy time; tree = `5d5283bd` + the audit diff) | **indexes** (separately, first), then functions, rules, storage | 25 | **Closes the 2026-08-16 follow-up codebase audit (28 findings).** No export change (25 → 25, diffed against **live prod** via `functions_list_functions` before touching anything, not against this repo's docs), so **no deletion prompt and no abort**; all 25 reported `Successful update operation`. `firestore.rules`/`storage.rules` were UNCHANGED and re-published only to confirm prod matches the repo — the CLI duly said "latest version of firestore.rules already up to date, skipping upload". **Indexes were deployed FIRST, in their own command,** because `rotateAssignedImageTokens` (the new S1 control) needs a new `(employeeIds CONTAINS, endTime DESC)` composite and a missing index fails `FAILED_PRECONDITION` straight into that module's swallow — i.e. a security control that silently stops running. Verified `READY` before reporting done. Backend changes: S1 Storage download-token rotation on deactivate (`appointment_image_tokens.js`, called from `syncUsersByUid`, whose `timeoutSeconds` rises to 300); B1 the nightly digest's cap was INVERTED — ascending `startTime` from a floor 15 days in the past kept the OLDEST open jobs and discarded tomorrow's, so past ~1000 stale open jobs every crew would get no digest at all; S3 the Places proxy no longer logs a 200-char upstream body (it echoed the address being typed); I4/I6 reachability is now checked before the work in the digest and in `_deliverRecipientOnce`; I11 `sendToActiveAdmins` bounded + cache-seeded; I8/I16 concurrency; I15/I1 `bridge_policy.js` extracted and tested; I2 `scripts/_batch.js`. **Known benign drift, deliberately NOT cleaned:** the CLI reports "1 field override defined in your project that is not present in your firestore indexes file" — it is the orphaned `signupCodes/expiresAt` TTL policy left over from the 2026-08-08 `#compat-1.37.1` retirement, on a collection nothing writes. **Never pass `--force` to clear it** (that deletes ALL drifting overrides, which is how the 5 live TTL policies were lost in 2026-07-21); delete it in the console if it is ever worth the noise. Post-deploy verification: 25 live and matching `functions/index.js`, zero WARNING/ERROR log entries newer than the deploy, `sendUpcomingJobReminders` on revision `-00038-fod` ACTIVE with a clean startup probe. |
| 2026-08-19 | (uncommitted at deploy time; tree = `e72bc167` + the Wave query-module extraction) | functions, rules, storage | 25 | **Closes the OUTSTANDING gap below — prod had been running pre-1.46.2+75 function bodies since 2026-08-16.** The only backend change in this tree is a pure refactor: `readBusinessId` and the two customer-listing GraphQL documents moved out of `wave/customers.js` into a new leaf `wave/customer_queries.js`, which lets `customers_import.js` require them at module scope instead of through the `pushHalf()` lazy require that existed only to break the cycle. No behaviour change, no payload change, no export change (25 → 25). `firestore.rules`, `storage.rules` and `firestore.indexes.json` unchanged — the CLI skipped both rules uploads as already up to date, so `indexes` was omitted. Pre-flight: `npm run lint` clean, 56 jest suites / 1344 tests pass. No deletion or new-retry prompt. Verified post-deploy: 25 functions live matching `functions/index.js`, zero module-load errors, `waveUpsertCustomer` `ACTIVE` on revision `waveupsertcustomer-00047-jab` with `RETRY_POLICY_RETRY` intact. The four `waveUpsertCustomer` "request was not authenticated" warnings at 03:36:36Z are Cloud Run rollout health probes inside the update window (03:36:31 instance start → 03:36:37 UpdateFunction response), not dropped Eventarc events. |
| 2026-08-21 | `1c89892a` | functions, rules, storage | 25 | **The simplified-auth deploy (1.48.0+77) — `functions/employee_accounts.js` only.** No export change (25 → 25, `functions/index.js` untouched and diffed against the live list), so **neither known abort fired**: no deletion prompt and no failure-policy prompt. **What changed server-side:** `completeEmployeeSetup` no longer checks `email_verified` (the `failed-precondition / email-not-verified` refusal is gone), and `createEmployeeAccount` now mints a **random per-account starting password** via `generateStartingPassword()` — `crypto.randomInt`, 12 chars from an alphabet with no `0/O/1/l/I`, Fisher-Yates shuffled, drawn ONCE per call and handed to both the mint and re-provision paths so the echoed value always equals what Auth was set to — and hard-codes `role: "employee"`. **The shared `Welcome123!` constant is gone from the codebase.** **PRE-FLIGHT, the required one (§1): prod was queried at deploy time and returned ZERO `invited` users**, verified two ways because one empty result is not evidence — a `status == 'invited'` query returned `{"documents":[]}`, and an independent `ListDocuments` of `users` returned **5 docs, every one `status: 'active'`** (4 `admin`, 1 `employee`). Nothing was stranded on the shared password, so removing the mailbox guard exposed nobody. **`isAdmin` was deliberately KEPT in `createEmployeeAccount`'s `assertPayloadShape` allowlist as an accepted-and-ignored key** (`#compat-1.47.0`): it is never read and cannot mint an admin, but dropping it would have failed create AND Reset password on every admin build ≤ 1.47.0 with `invalid-argument / unexpected-field` — including the Reset password button the remediation itself runs on. That keeps the allowlist a SUPERSET of the deployed one (§4a). **No rules, index or secret change** — `firestore.rules` and `storage.rules` were byte-identical to prod ("already up to date, skipping upload", merely re-released), `firestore.indexes.json` untouched so `firestore:indexes` was deliberately omitted, and no secret prompt appeared. Deployed **without `--force`**, with `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` cleared in the same shell (§5). **Pre-flight:** `npm run lint` clean, **1348/1348 jest across 56 suites**; app side `flutter analyze` clean and 2611 flutter tests. **Verified post-deploy:** all 25 reported "Successful update operation" (0 creates, 0 deletions), `functions_list_functions` returns exactly 25 and diffs EXACTLY against the `index.js` exports (no orphans, none missing), rules + storage released. Log scan over the deploy window came back **empty** for `Cannot find module` / `SyntaxError` / `Container failed to start` / `ReferenceError` / `TypeError`, and empty for any ERROR once the benign post-deploy probe is excluded — that probe issues a GET against POST-only callables and logs `Request has invalid method. GET` → `Invalid request, unable to process.`, which appears at every deploy (it is in the 2026-08-20 window too) and is not a startup failure. **ORDERING NOTE:** this was backend-first, as §2 requires. **UPDATE 2026-08-21, later the same day: the 1.48.0+77 app build HAS SHIPPED, so §3 now applies and BACKEND ROLLBACK IS NO LONGER SAFE.** An earlier version of this row said prod was a new backend under an old app build and that reverting was still fine — that window is closed. Rolling the backend back now restores the `email_verified` guard underneath a build that has no verification UI, stranding anyone mid-setup: their password has already rotated and activation would be refused permanently. Fix forward instead. The client retains a mapping for the retired `email-not-verified` refusal (`AuthFailureSetupNotAvailableYet`) precisely so a rollback in that window degrades to an actionable message instead of "Something went wrong" plus a non-fatal per retry. **ACTION LEFT:** ship the 1.48.0+77 app build, and **republish `docs/legal/support.html` to `gvogas/es-pro-legal` by hand** — the committed copy drops the "open the verification link" instruction, but employees read the live copy, which still describes a message that no longer arrives. |
| 2026-08-21 | `229b6e24` | functions, rules, storage | 25 | **Restores account creation, which had been DOWN since the `1c89892a` deploy earlier the same day — `functions/employee_accounts.js` only.** No export change (25 → 25, diffed against the LIVE list via `functions_list_functions` before deploying, not against this doc), so **neither known abort fired**: no deletion prompt and no failure-policy prompt. **The outage:** the Identity Platform password policy configured console-side requires a **non-alphanumeric character**, and `generateStartingPassword()` drew from `PASSWORD_UPPER + PASSWORD_LOWER + PASSWORD_DIGITS` — alphanumeric only. Every `createEmployeeAccount` call died at `provisionAuthAccount` (`employee_accounts.js:141`) with `auth/internal-error` / `PASSWORD_DOES_NOT_MEET_REQUIREMENTS: Missing password requirements: [Password must contain a non-alphanumeric character]`. Confirmed live: **four identical failures at 02:15:39Z, 02:17:24Z, 02:22:48Z and 02:24:42Z**, App Check `VALID` and auth `VALID` on each, so the admin guard and payload were never the problem. **Why it only broke at `1c89892a`:** the shared constant it replaced was `Welcome123!`, whose trailing `!` had been satisfying that policy by accident — nobody had read it as load-bearing, and the previous row records the new alphabet as "no `0/O/1/l/I`" without noticing the class it had dropped. **The fix:** a `PASSWORD_SYMBOLS = "!@$?*"` class, kept deliberately OUT of `PASSWORD_ALPHABET` so a mint carries EXACTLY one symbol (the admin dictates it aloud); the set avoids bracket pairs, dash/underscore confusion and URL/shell-significant glyphs. Guaranteed picks go 3 → 4 and the Fisher-Yates comment follows. **Note the code comment already CLAIMED this property** — "the class mix is kept so a stricter Auth policy later cannot start rejecting values we mint" — while containing no symbol class; the claim is now true rather than merely intended. **Compatibility (§4a): nothing to check that could fail.** Every `assertPayloadShape` allowlist, `requireString`/`optionalString` cap and response shape is **byte-identical** to `1c89892a` (verified by grepping the diff for all four), `isAdmin` remains accepted-and-ignored (`#compat-1.47.0`), and **no shipped build validates the starting password charset** — sign-in runs `AuthValidators.password` (non-empty, ≥8 chars), so a symbol passes on 1.45, 1.46.1 and 1.48 alike. **No rules, index or secret change** — both rules files were byte-identical to prod ("already up to date, skipping upload", merely re-released), `firestore.indexes.json` untouched so `firestore:indexes` was **deliberately omitted** rather than re-trigger the known orphaned `signupCodes` TTL drift prompt. Deployed **without `--force`**, with `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` cleared in the same shell (§5). **Pre-flight:** `npm run lint` clean, **1349/1349 jest across 56 suites** (up 1 — the new symbol-class case, written failing FIRST and confirmed red with `Received length: 0` before the fix); app side `flutter analyze` **No issues found!** and **2611/2611 flutter tests**; `firestore.rules` validated `OK: No errors detected`. **Verified post-deploy:** all 25 reported "Successful update operation" (0 creates, 0 deletions), `functions_list_functions` returns exactly 25 diffing EXACTLY against the `index.js` exports (no orphans, none missing), rules + storage released. Log scan from 02:40Z: **zero ERROR entries of any kind**, and empty for `Cannot find module` / `SyntaxError` / `Container failed to start` / `ReferenceError` / `TypeError` / `PASSWORD_DOES_NOT_MEET` — the benign GET-probe cluster did not even appear this time. **No app build needed: zero Dart files changed**, so §2 ordering is not in play. **ACTION LEFT — THIS DEPLOY FIXES ONLY HALF THE PROBLEM.** The same console policy also rejects the password the EMPLOYEE chooses during setup: 1.48 dropped `PasswordRequirement.symbol` from the enum, so the shipped build shows an all-green checklist on a symbol-free password and Firebase Auth then refuses `updatePassword`. **Nothing server-side can fix that half** — the checklist is client-side and 1.48 is already on the App Store. The owner must uncheck **"Contains a non-alphanumeric character"** in Firebase Console → Authentication → Settings → Password policy. Until then, account creation works but employee setup can still dead-end. Deployed from an uncommitted tree (HEAD was `cf952423`), as the `9a43b38`, `ccb703e0` and 2026-08-16/19 rows once were; that tree was committed as `229b6e24` immediately after, which is the hash above, so nothing ran in prod that is not in the history. |
| 2026-08-22 | `dc5eb42f` (functions tree = `cc008388`) | functions, rules, storage | 25 | **The photo-subcollection CONTRACT deploy — step 2 of the migration runbook above.** No export change (25 → 25, diffed against the LIVE list before deploying, not against this doc), so **neither known abort fired**: no deletion prompt and no failure-policy abort. **What changed server-side:** `cascadeDeleteAppointmentImages` now deletes the Storage BYTES as well as the photo documents; `recountPictures` warns past `PICTURE_COUNT_WARN_CAP` (100); **`appointment_image_tokens.js` and its `syncUsersByUid` call are DELETED**, and that trigger's `timeoutSeconds: 300` reverts to the default. `security.js` is a one-line `crypto` → `node:crypto`, no behaviour change. **Rules: a RELAXATION** — `allow create` on `/appointments` now accepts `pictureCount` when it is exactly 0, which the app writes beside `_toFirestoreMap` at both create sites (`addAppointments`, the series copy). Verified before deploying that `AppointmentRecord.toMap()` emits it ZERO times, so no UPDATE can carry one, and that the update branch is diff-based (`affectedKeys().hasAny(['pictureCount'])`) rather than a flat key ban — an ordinary edit of an existing appointment is unaffected. The `pictures` size cap STAYS, for documents the clear script has not reached. **Compatibility check (§4a): every `assertPayloadShape` allowlist, `requireString`/`optionalString` cap and validator byte-identical to `229b6e24`** — the only hit in the validator diff was the new `PICTURE_COUNT_WARN_CAP` log threshold, which is not request-side. No shipped build can be broken. **`firestore:indexes` DELIBERATELY OMITTED.** The only index change is a REMOVAL — `(employeeIds CONTAINS, endTime DESC)`, which existed solely for the deleted token rotation — and a removal is never applied without `--force`, so including the target would have bought nothing but a drift report (and would have put the orphaned `signupCodes/expiresAt` TTL policy back in scope for no reason). Same reasoning as the `c167fcbf` row. **The stale index is still live in prod; delete it in the console if the noise is worth it, never with `--force`.** `storage.rules` unchanged — target included only to confirm parity, and the CLI duly said "already up to date, skipping upload". **Pre-flight:** `flutter analyze` clean · **flutter 2667/2667** · `npm run lint` clean · **jest 1372/1372 across 58 suites** · `firestore.rules` AND `storage.rules` both validated clean via the Firebase MCP (the emulator needs Java, absent on this box) · BOM scan clean · repo exports diffed 25/25 against live prod. **Verified post-deploy:** all 25 reported `Successful update operation` (0 creates, 0 deletions), rules + storage released, `functions_list_functions` returns exactly the 25 exports with no orphans and no extras, and it confirms **exactly 3 `scheduled` triggers** (`purgeExpiredHistory`, `sendDailyJobDigest`, `sendUpcomingJobReminders`) — the target state for the still-open Cloud Scheduler cleanup. Log scan over the deploy window: **zero real errors** — every WARNING/ERROR entry is the same `Request has invalid method. GET` → `Invalid request, unable to process.` shape on `createEmployeeAccount` and `waveRetryFailedJobs` — **which is NOT the rollout probe this log's earlier rows call it; see the section below the table, corrected 2026-08-22**; no `Cannot find module`, no `SyntaxError`, no startup failure, no `permission-denied`, no `unexpected-field`. **STILL OUTSTANDING after this deploy:** step 3 (ship the app build) then step 4 (the irreversible clear script, only once the fleet has moved off builds that still write the array); the 3 orphaned Cloud Scheduler jobs; the `MAPS_API_KEY` rotation; and the 🔴 S1 prod count — **which this deploy makes newly urgent, because it removed the only control that could revoke a legacy `url` photo link, so from now on deactivating someone rotates nothing.** |

| 2026-08-22 | `a6eff476` | **`firestore:rules` ONLY** | 25 (untouched) | **Closes 🔴 S1 — retires the legacy photo `url`.** Rules-only deploy, hours after the CONTRACT deploy above; `functions` and `storage` were deliberately out of scope because neither changed (the only `functions/` edit in this commit is to `scripts/`, which is not a deployed surface), and `firestore:indexes` stayed out for the same reason as the previous row. **What changed:** the `appointments/{id}/images` allowlist drops `url`, so it is now `['storagePath', 'fileName', 'uploadedAt']` and the 1000-char bound on the field goes with it. **This is a TIGHTENING, which is the risky direction — the fleet was checked first, exactly the way §4a checks a payload allowlist.** The shipped build (`1c89892a`) writes the field only under `image.storagePath.isEmpty && image.url.isNotEmpty`, and its uploader always sets `storagePath`, so no shipped build can produce a write this rejects. Verified by reading the shipped source at that tag, not by inference. **Why it is safe to drop at all:** the deciding prod count finally ran — `functions/scripts/count-legacy-image-urls.js` (new, read-only) reported **14 image documents scanned, 0 with a `url` and no `storagePath`**, so the set the field existed for is empty. That number also proves no ARRAY entry is url-only, since the backfill copies every entry, so step 4's clear script has nothing to refuse on this account. The count SCANS and filters in memory rather than querying, because `images.url` is index-EXEMPT in `firestore.indexes.json` and a `where()` on it fails outright. **Shipped alongside in the app tree** (takes effect with the app build, not this deploy): `AppointmentImageLoader`'s `refFromURL` fallback and its `url:` cache key space are deleted, `AppointmentImagesStore` no longer writes the field, and `backfill-appointment-images.js` SKIPS a url-only array entry rather than copying a document that could never render — the Admin SDK bypasses rules, so nothing would have reported that one. **Pre-flight:** `firestore.rules` AND `storage.rules` validated clean via the Firebase MCP · `flutter analyze` clean · flutter **2665** · jest **1373 across 58 suites** · eslint clean. **Verified post-deploy:** `rules file firestore.rules compiled successfully` then `released rules firestore.rules to cloud.firestore`; no index or TTL policy was in scope, so the orphaned `signupCodes` override was never at risk and no `--force` was needed or passed. |
| 2026-08-23 | `647660a5` | functions, `firestore:rules`, storage | 25 | **The 1.49.0+78 release deploy — a DRIFT-CLOSING deploy, not a behaviour change.** Prod had been running the functions tree from `cc008388` while the repo moved on through the release's simplify and review passes; this republishes them so the two match. No export change (25 to 25, `functions/index.js` byte-identical to the deployed tree), so neither known abort fired: no deletion prompt, no failure-policy abort, 0 creates and 0 deletions. **What changed server-side, all of it refactor:** `maintenance.js`'s best-effort `deleteAppointmentImages` now delegates to `appointment_images.js`'s `deleteAppointmentImageBytes` (newly exported) so the `appointments/{id}/images/` prefix has ONE owner — it was spelled twice, with `maintenance.js` hard-coding the literal `"images"` while the trigger composed it from `IMAGES_SUBCOLLECTION`, and a rename would have left `purgeExpiredHistory` deleting an empty prefix and reporting success on the one path that has no other way to find those bytes. `client_job_count.js` adopts the shared `adminFirestore()` (it was the fifth site still hand-rolling the lazy require the module claims to own). `purgeAppointmentImages` drops an unreachable `|| deleteAppointmentImageBytes` default — every caller, production and jest, injects it. `appointment_scan.js`'s `scanAppointmentWindow` now THROWS on a missing `label`/`consequence`/`logger` or `loOp`/`hiOp`/`descending` instead of defaulting: the ordering decides which jobs the cap keeps, and a missing logger silently loses the truncation warn the module exists to provide. **All three call sites pass every option, verified before deploying, so the new throws are unreachable in prod.** `bridge.js` is COMMENT-ONLY. **Rules: COMMENT-ONLY** — the `images` allowlist, every cap and every clause are byte-identical to the live `a6eff476` ruleset; the comment was corrected because it overstated what the S1 count proved (see below). `storage.rules` unchanged, target included only for parity, and the CLI duly said "already up to date, skipping upload". **Compatibility check (§4a): no `assertPayloadShape` allowlist, `requireString` cap or validator is touched anywhere in the diff** — grepped, zero hits — so the allowlist remains a superset of the deployed one and no shipped build can be broken. `firestore:indexes` deliberately omitted: this commit changes no index, and including the target would only have re-raised the orphaned `signupCodes/expiresAt` drift report. No `--force`. Agent env vars (`AI_AGENT`, `CLAUDECODE`, `CLAUDE_CODE`) cleared per §5 — the audit-log entries carry `deployment-tool: cli-firebase` with no agent label. **Pre-flight:** `flutter analyze` clean · flutter **2665** · `npm run lint` clean · jest **1373 across 58 suites** · BOM scan clean · both rules files compiled clean by the CLI. **Verified post-deploy:** all 25 reported `Successful update operation`, rules and storage released, `functions_list_functions` diffs EXACTLY against the 25 `index.js` exports (no orphans, no extras), and the log scan over the deploy window shows **zero WARNING-or-above entries** — every entry is an expected `DEPLOYMENT_ROLLOUT` instance start, a `Default STARTUP TCP probe succeeded`, or the `UpdateFunction` audit record. No `Cannot find module` from the new `maintenance.js` to `appointment_images.js` require, which was the one load-order risk worth watching. **Cloud Scheduler STATE checked and CLEAN:** this deploy touched all three scheduled functions, and the owner confirmed all three read ENABLED afterwards. That check is not optional and not inferable from anything above — a PAUSED job is indistinguishable from a healthy one in `functions:list` and in Cloud Run, only the Cloud Scheduler page shows STATE, which is exactly how `purgeExpiredHistory` sat paused unnoticed until 2026-08-23. **Do it after any deploy that touches a scheduled function.** **STILL OUTSTANDING:** step 3 (ship the 1.49.0+78 app build), then step 4 (the irreversible clear script, only once the fleet has moved off builds that still write the array — Crashlytics still showed 1.46.1/1.45.0). Those two are the whole remaining list. |
| 2026-08-25 | `f0c341a7` | functions, `firestore:rules`, storage | 25 | **The 2026-08-25 audit deploy (40 non-pre-ship findings).** No export change (25 → 25), and the local export list was diffed against the **LIVE** list before deploying, not against this doc — so **neither known abort fired**: no deletion prompt, no failure-policy abort. **What changed server-side, all of it small:** `client_name_utils.js`'s `liftPhoneFromName` now trims the number's OWN wrapper at the seam it cut (new `OPEN_SEAM`/`CLOSE_SEAM`), so a name written the way the app renders it — `"Depanneur (514) 555-1234"` — no longer leaves an orphan bracket behind; these are deliberately NOT folded into the shared `EDGE_SEPARATORS`, where a trailing bracket is usually the name's own, and the pair mirrors `ClientNamePolicy._openSeam`/`._closeSeam`. Everything else is non-behavioural: `APP_CHECK` was hoisted out of `clients.js` and `employee_accounts.js` into `security.js` as the one owner (a callable that also sets a region, timeout or secret still writes `enforceAppCheck: true` inline — spreading a one-key constant into a larger options block reads as less explicit on a security-critical line), and four dead exports were dropped (`day_slice_utils.isOvernightRecord`, `live_activity_registry.TOKEN_TTL_MS` + `activityTokenExpiry`, `wave/mappers.IMPORT_FIELD_CAPS` — the last still used INSIDE its own module, only the export went). Verified by grep that no module references any of the four. **Compatibility check (§4a): every `assertPayloadShape` allowlist and every `requireString`/`optionalString` cap byte-identical to `647660a5`** — no key removed, no cap narrowed, no new required field, so the allowlist stays a SUPERSET of the deployed one and no shipped build can be broken. `#compat-1.47.0` (`createEmployeeAccount`'s accepted-and-ignored `isAdmin`) is untouched and must stay. **No rules change** — `firestore.rules` and `storage.rules` were byte-identical to prod, so the CLI reported "already up to date, skipping upload" for both and merely re-released them; targets were included to confirm parity. **`firestore:indexes` DELIBERATELY OMITTED** — `firestore.indexes.json` is unchanged, and including it would only put the orphaned `signupCodes/expiresAt` TTL policy back in scope for a drift report. The stale `(employeeIds CONTAINS, endTime DESC)` index from the retired token rotation is **still live in prod**; delete it in the console if the noise is worth it, never with `--force`. Deployed **without `--force`**, with `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` cleared in the same shell (§5). **Pre-flight:** `npm run lint` clean, **jest 1426/1426 across 63 suites**. **Verified post-deploy:** all 25 reported `Successful update operation` (0 creates, 0 deletions), rules + storage released, `functions_list_functions` returns exactly the 25 `index.js` exports — no orphans, none missing — and still exactly **3 `scheduled` triggers** (`purgeExpiredHistory`, `sendDailyJobDigest`, `sendUpcomingJobReminders`), the target state for the Cloud Scheduler cleanup. Log scan came back **empty** for `Cannot find module` / `SyntaxError` / `Container failed to start` / `ReferenceError` / `TypeError` / `permission-denied` / `unexpected-field`. The only ERROR entries in the window are 5 `Invalid request, unable to process.` on `deleteClient`, `waveImportCustomers` and `completeEmployeeSetup`, each paired with its own `Request has invalid method. GET` WARNING — the unauthenticated external GET sweep documented in the section below this table, **not** the rollout probe the older rows call it; nothing reached a handler, so no rate-limit slot was consumed. **STILL OUTSTANDING, unchanged by this deploy:** exactly one item — the photo migration's step 4, the irreversible clear script, which waits on the fleet moving off builds that still write the `pictures` array. **The “3 orphaned Cloud Scheduler jobs” carried by every row since 2026-08-14 are NOT outstanding and never were:** the 2026-08-23 check established that the orphans did not exist, and the 3 scheduled triggers verified live above are the correct target state, not leftovers. Don't re-open that item from an older row. |
| 2026-08-29 | `77c6a66f` | **`firestore:indexes` (separately, first)**, then functions, `firestore:rules`, storage | 25 | **The per-day appointments deploy (`dayIndex`/`dayCount` runs), plus the 2026-08-28 second-pass audit's rules and index halves.** No export change (25 → 25 — `functions/index.js` is byte-identical to the last deploy and was diffed against the **LIVE** list before deploying, not against this doc), so **neither known abort fired**: no deletion prompt and no failure-policy abort. Indexes went first and separately because the run work adds a composite the app queries. **Compatibility (§4) was not a concern this time and the reason is worth recording:** the owner confirmed the whole fleet is on **1.52**, so there is no build behind this backend to serve. The one clause that would otherwise have needed the check is the S1 rules pin `request.resource.data.updatedAt == request.time` on the employee mark-done branch — a build whose status write omitted `updatedAt` would be refused outright. It was verified safe independently anyway: both client paths send `FieldValue.serverTimestamp()` unconditionally, and `git show v1.38.0+63` confirms they have since at least 1.38.0+63. **What changed server-side:** `recount_claim.js` became the real single owner of the claim protocol (B1 — `appointment_images.js` had carried a byte-identical second copy of the module extracted to prevent exactly that drift; `debouncedRecountPictures` is now a ~6-line adapter), a new `client_address_utils.js`, `day_slice_utils.js` mirroring the stored run label, plus small edits across `client_job_count.js`, `client_propagation.js`, `notification_policy.js`, `time_utils.js`, `widget_payload_utils.js`, `wave/mappers.js` and `wave/errors.js`. **Rules:** the `updatedAt` pin above; bounds on `dayIndex`/`dayCount` (1–14, absent-or-valid, tracking `maxAppointmentSpanDays`); and a server-owned `clientRecountClaims/{clientId}` deny-all match. **Indexes:** added `appointments (clientId ASC, dayIndex ASC)` — **verified READY** post-deploy — and a `clientRecountClaims.expiresAt` TTL policy. Pre-flight: `npm run lint` clean, jest **1535/1535 across 67 suites**, rules validated `OK: No errors detected.` Post-deploy: 25 functions live, matching the export list exactly, no orphans; logs show only the documented benign `Invalid request, unable to process.` / "not authenticated" sweep traffic (see the section above — it is external GET traffic, not a rollout probe), no startup errors. **The one index deletion, DONE the same day.** Removing `appointments (employeeIds CONTAINS, endTime ASC)` from the file (audit I9) did NOT delete it from prod — deletion requires `--force`, which is banned here (it would take the TTL policies with it), so the deploy warned *"there are 1 indexes defined in your project that are not present in your firestore indexes file."* It was deleted out-of-band via the Firestore admin API (`firestore_delete_index` on `CICAgNi4-ZIK`) at the owner's instruction, and the live list was re-read after: the two-field index is gone, the three-field `(employeeIds CONTAINS, endTime ASC, startTime ASC)` that replaces it as a prefix is still READY, and **prod now matches `firestore.indexes.json` exactly**. This is the sanctioned way to drop an index here — a targeted admin-API delete, never `--force`. Carry I9's caveat forward: that three-field prefix is `SPARSE_ALL`, so it omits any document with **no `startTime`**, which the deleted two-field index did not; only a legacy/console-written row is affected, but if such rows appear, restore the two-field index. (The `(employeeIds CONTAINS, endTime DESC)` index that earlier notes also queued for a console delete was **already gone** — absent from the live list before any of this, so that trip was one delete, not two.) |
| 2026-08-29 | (uncommitted at deploy time; tree = `77c6a66f` + the `#compat-1.47.0` retirement) | **`functions` ONLY** | 25 | **Retires `#compat-1.47.0` — the second deploy of the day, hours after the one above.** Deliberately scoped to `functions`: `firestore.rules`, `storage.rules` and `firestore.indexes.json` were deployed from this same tree that morning and were byte-unchanged since, so re-sending them would have been noise, not safety. No export change (25 → 25, `functions/index.js` untouched), so neither known abort fired. **The whole server-side delta is one line:** `"isAdmin"` removed from `createEmployeeAccount`'s `assertPayloadShape` allowlist in `functions/employee_accounts.js`. It is now refused as `unexpected-field` instead of being accepted-and-ignored. **Why it was safe, both halves checked rather than one:** the owner confirmed the fleet wholly on **1.53**, so no build at or below 1.47.0 remains to send it; *and* the current client was read directly (`firebase_employees_repository.dart:123`) to confirm it sends no such key, keeping the allowlist a superset of every deployed build (§4a). Checking only the version would have been the easy mistake — the superset contract is about what builds SEND, not what they are numbered. Note this tightening could not ride along with the app build that stopped sending the field back in 1.48: retiring a carve-out is a backend change and always needs its own deploy, which is why it sat for eight days after the gate cleared. **Nothing else moved** — guard order, rate limits and the hard-coded `role: "employee"` in `performCreateAccount` are untouched; that defence never depended on the allowlist. The test that pinned the field's ACCEPTANCE (`employee_accounts_callables.test.js`) was flipped to pin its REJECTION, and additionally asserts no Firestore doc and no `auth.createUser` — so it is now a tripwire if a client is ever changed to send it again. Pre-flight: `npm run lint` clean, jest **1535/1535 across 67 suites**. Post-deploy: 25 functions live, matching the export list exactly; `createEmployeeAccount` logged no startup errors and no invocations. Docs updated in lockstep — `docs/CLOUD_FUNCTIONS.md`, `docs/ARCHITECTURE.md` (2 sites), `.claude/rules/employees.md` and `.claude/rules/security.md` all described the carve-out as still live and now record it as retired; the security rule keeps it as a COMPLETE worked example (opened 2026-08-21, retired 2026-08-29) since that is more useful than an open one. |
| 2026-08-30 | `fe9edc51` | functions, `firestore:rules`, storage | 25 | **The Wave customer contract, Phase 1 — REPORT-ONLY.** No export change (25 → 25), and the local export list was diffed against the **LIVE** list before deploying, not against this doc — an exact match, so **neither known abort fired**. **What changed server-side, three files:** a new `wave/customer_contract.js` (`buildCustomerPayload` returns either a Wave payload plus its hash, or structured `problems`), one line in `wave/triggers.js` merging `problemsPatch(after)` into the batch that was already marking the doc pending, and `wave/retry_policy.js`'s `describeWaveError` now reporting a `WaveValidationError`'s `inputErrors` (code + path only, never Wave's message, which is customer data) — it returned `""` for that class, so `errorDetail`, the field `worker.js` calls "the only place the REASON survives", was ALWAYS empty for the one error whose reason arrives structured. **REPORT-ONLY is the whole point of this deploy: nothing is blocked.** The job is still enqueued, the push still runs, `wave.syncState` is untouched; the only observable change is a new `wave.problems` field. It rides the existing mark-pending batch so it costs no extra write, and it is not a mapped field, so the hash is unchanged and `shouldEnqueueClientWrite` stops the re-fire — that is what keeps it from looping. **No rules change was needed and that was verified, not assumed:** `wave` is already function-owned on `/clients` (create rejects it outright; update rejects only a write whose `affectedKeys()` touches it), and `ClientRecord.toMap()` does not emit `wave`, so app edits pass untouched. **Compatibility (§4a): no `assertPayloadShape` allowlist, cap or response shape moved** — verified by grepping the whole `functions/` diff since the deployed tree for all five guard helpers, which returned nothing. `functions/employee_accounts.js` shows in that diff but is a NO-OP here: it is the `#compat-1.47.0` retirement already deployed in the row above, from an uncommitted tree later committed as `6d64d9ae`. **PRE-FLIGHT AGAINST PROD, the part that made this safe:** `functions/scripts/audit-wave-contract.js` (new, read-only) replayed the contract over every client BEFORE the deploy — **714 scanned, 0 blocking, 0 advisory**, and 714 matches a server-side `count()` exactly, so the `__name__` paging skipped nothing. The first run had found 1, and it was the CONTRACT that was wrong: client `2wcEiCNztsWYUYNXYBEm` stores a contact's name in `phone`, and Wave has it **synced** with that string — so the rule would have blocked a client Wave accepts. That produced the blocking/advisory split now in the module, and the phone rule came back as advisory `NOT_DIALABLE`. **Pre-flight:** `npm run lint` clean, jest **1565/1565 across 68 suites**; app side `flutter analyze` **No issues found!**. **`firestore:indexes` DELIBERATELY OMITTED** — `firestore.indexes.json` untouched, and including it would only put the known orphaned `signupCodes/expiresAt` TTL drift prompt back in scope. Deployed **without `--force`**, with `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` cleared in the same shell (§5). Both rules files reported "already up to date, skipping upload" and were merely re-released, confirming byte-parity. **Verified post-deploy:** all 25 reported "Successful update operation" (0 creates, 0 deletions), `functions_list_functions` returns exactly the 25 `index.js` exports with no orphans and still exactly **3 `scheduled` triggers**; `waveUpsertCustomer` is ACTIVE at revision `waveupsertcustomer-00057-wel` with its STARTUP TCP probe succeeding — real runtime proof the new `require("./customer_contract")` resolves, not merely that the deploy reported success. Log scan from 19:00Z came back **empty** for `Cannot find module` / `SyntaxError` / `Container failed to start` / `ReferenceError` / `TypeError` / `customer_contract`. **ORDERING:** backend-first per §2. **NOT SHIPPED BY THIS DEPLOY:** the Dart half of the 2026-08-30 `composeStored` fix — until that app build ships, an old client can still blank a business named only by its phone on save, but the contract now RECORDS it instead of letting it dead-letter silently. **NEXT:** Phase 2 is enforcement, and the 0/714 pre-flight says it can be turned on without blocking a single existing client. |
| 2026-09-01 | `2515761e` | `firestore:indexes` FIRST, then functions, `firestore:rules`, storage | 25 | **An OUTAGE FIX, found in the Cloud Functions logs — not in the code.** `sendUpcomingJobReminders` was logging `travel: context query failed` (`code=9`, FAILED_PRECONDITION) on **60 of 60 warnings in a 2.5-hour window**, i.e. every run of a 5-minute sweep, since **2026-08-29**. Cause: the 2026-08-28 audit's I9 deleted `appointments (employeeIds CONTAINS, endTime ASC)` believing it a redundant prefix of `(employeeIds CONTAINS, endTime ASC, startTime ASC)`. **It is not a prefix — Firestore appends `__name__` to the END of the ordered fields**, so the surviving index reads `(employeeIds, endTime, startTime, __name__)` and nothing puts `__name__` directly after `endTime`, which is what `travel_utils.js:774-778`'s `decideOrigin` context query needs. **Impact: every travel-aware "time to leave" reminder degraded to the fixed 30-minute kind for two days**, invisibly — that path is best-effort, so it logs and falls through, and the correct fallback is exactly why nobody noticed. Index RESTORED and verified **READY** post-deploy; reasoning recorded in `.claude/rules/firestore-indexes.md` so it is not deleted a third time. **Indexes deployed FIRST and alone per §2.** Also in this deploy: the dead `users (email, role, status)` composite (signup-code flow, retired by P4c) removed — all five `users` queries were enumerated first and every one is single-field equality, a stronger check than the prefix argument that caused the outage above — deleted out-of-band via MCP `firestore_delete_index`, **never `--force`**; and a `clients/wave.problems` single-field exemption (array-of-objects, same case as `clients/contacts`). **`createdAt`/`updatedAt` were exempted mid-pass and REVERTED** — `.claude/rules/firestore-indexes.md` says they stay indexed on purpose, being what you sort by in the console. **Functions changed:** `notification_utils.js` now wraps its per-recipient loop in try/catch (the fan-out had no isolation while the trigger runs WITHOUT `retry: true`, so one transient failure dropped recipients 2..N permanently); `places.js` `fetchPlacesJson` arms an `AbortController` at 8 s (Node `fetch` has no default timeout, and the client gives up at 10 s while the function kept running, spending a billed call and a rate-limit slot for an abandoned lookup — from Crashlytics: 34 events / 3 users on 1.54.0); `wave/customer_contract.js` scrubbed of a customer name (PII). **Pre-flight:** `npm run lint` clean, jest **1571/1571 across 69 suites**, `flutter analyze` **No issues found!**, `flutter test` **3045/3045**. Deployed **without `--force`**, `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` cleared (§5). **Verified post-deploy:** all 25 "Successful update operation" (0 creates, 0 deletions); `functions_list_functions` returns exactly the 25 `index.js` exports, no orphans; restored index state `READY`; dead `users` index absent from the list. **NOT YET CONFIRMED:** the travel fix's log proof. Warnings are absent since the deploy, but the window is OVERNIGHT and the original failures were 15:04-17:29Z (business hours), so the sweep may simply have no candidates — **re-read the logs during business hours before calling it closed.** **NOT SHIPPED:** the Dart half (B1 run-anchor, I1 client-window perf, P1b geocode cooldown, B4/I8 throw containment) needs an app build. |
| 2026-09-01 | `a808fe03` | functions, `firestore:rules`, storage | 25 | **The 1.55.0+84 release deploy - the SECOND deploy of the day, hours after the index-outage fix above.** `firestore:indexes` deliberately OUT of scope: `firestore.indexes.json` is byte-identical to `2515761e`, so there was nothing to add and a deploy can never delete (the restored `(employeeIds CONTAINS, endTime ASC)` index from that earlier deploy is untouched). `firestore.rules` and `storage.rules` were likewise unchanged - the CLI reported *latest version already up to date, skipping upload* for both and re-released them, which is a no-op, not a drift signal. No export change (25 -> 25, `functions/index.js` byte-identical to `2515761e`, and the local export list diffed against the **LIVE** `functions_list_functions` result before deploying, not against this doc) - so **neither known abort fired**: no deletion prompt, no failure-policy prompt. **Functions changed:** `wave/mappers.js` now EXPORTS `IMPORT_FIELD_CAPS`, and `wave/customer_contract.js`'s `PAYLOAD_CAPS` READS it through a new `importCap()` rather than restating the ten numbers - the push and import directions had two hand-written copies of one set of caps, which is how a widened Wave cap gets applied in one direction and not the other, and nothing tested one list against the other. `importCap()` **throws at `require()` time** on a field with no entry, which is deliberate and is itself deploy-gated: `firebase-tools` loads `index.js` to discover triggers, so a field renamed in `mappers.js` aborts the deploy before upload instead of silently reporting EVERY client as `TOO_LONG` with `cap: undefined` (report-only today; **blocking in Phase 2**, where that would be every client refused). `mobile` borrows `phone`'s cap on purpose - the import folds Wave's mobile into one `phone` field, the push sends both. Also `wave/triggers.js`: `runWaveDaily` now wraps its `wave/connection` read in try/catch, so the rider can no longer reject out of a host that had already done its real work - its JSDoc claimed *never throws* and that one await outside the try was the exception. `functions/scripts/*` gained a shared `_project.js` bootstrap and six new test files, none of which deploy. **Pre-flight:** `npm run lint` clean, jest **1636/1636 across 75 suites**, `flutter analyze` **No issues found!**, `flutter test` **3058/3058**, BOM scan clean, no ARB drift. Deployed **without `--force`**, `AI_AGENT`/`CLAUDECODE`/`CLAUDE_CODE` cleared (§5). **Verified post-deploy:** all 25 *Successful update operation* (0 creates, 0 deletions); `functions_list_functions` returns exactly the 25 `index.js` exports, no orphans; logs since the deploy carry no `PAYLOAD_CAPS`, no `Cannot find module` and no `WAVE-BOOT` warning. The `Invalid request, unable to process.` burst at 12:00Z is the documented unauthenticated external GET traffic, not a rollout probe - see the section below. **NOT SHIPPED:** the Dart half of 1.55.0 (six-week month grid, the Address filter work, the client-window and geocode-cooldown perf) needs an app build. |
| 2026-09-03 | `1b2f1847` | **`firestore:indexes` (separately, first)**, then functions, `firestore:rules`, storage | 25 | **The 2026-09-01/09-03 audit batch: the assignee field-record grants.** No export change (25 -> 25); the live list was diffed against `functions/index.js` after deploying and matched exactly, so no orphans and nothing missing. No deletion prompt, no retry-change prompt, no secret prompt. **Payload allowlists were diffed against `a808fe03` before deploying and are byte-identical** (the callables moved from `assertAdmin` + `assertPayloadShape` to the composed `assertAdminCall`, which changes the opening but not one key), so this deploy is NOT breaking for any shipped build - DEPLOYMENT.md section 4a did not apply. `firestore.rules` shrank by 326 lines and gained 91, but a comment-stripped diff shows **every deletion was a comment** (the 2026-09-03 owner call in `code-quality.md`) and the code half is pure addition: three new `allow update` disjuncts for an assigned employee (field notes; mark `in_progress`; crew status), each `hasOnly`-scoped, `request.time`-pinned, `myDocId()`-bound and excluding terminal statuses; new bounded-field validation for `fieldNotes`/`crewStatus`/`crewStatusBy`/`startedAt`/`completedAt`/`crewStatusAt`; and the `images` subcollection `create` widened to assignees behind a `storagePath` prefix match. Two TIGHTENINGS rode along: `isAvailabilityOnlyChange` now also requires `updatedAt == request.time`, and a new `emailMovesThroughAuth()` blocks a direct `email` edit once `uid` is set (forcing it through `changeEmployeeEmail`). `storage.rules` widened appointment-image **write** to an assignee of that appointment while **delete stays admin-only** - deliberate asymmetry: adding to a field record is additive, removing from it is not. One new composite, `appointments (employeeIds CONTAINS, status ASC, startTime DESC)`, deployed first and on its own; it was still `CREATING` at the end of this session and **every other index is `READY` with no drift**. Its only consumer is the Dart-side technician History query, which ships with the app build - **confirm it is `READY` before shipping that build**. Post-deploy logs: the only entries are Cloud Run's own startup probe (`Request has invalid method. GET` on the callables), and **zero ERROR entries once the containers settled**. Pre-flight: eslint clean, 80 jest suites / 1747 tests green. Still outstanding: the app build (Dart half). |
| 2026-09-03 | (uncommitted at deploy time; tree = `1b2f1847` + the crew-status removal) | **`functions` + `firestore:rules` ONLY** | 25 | **Removes the "On my way" / "Running late" crew signal outright (owner call), hours after the deploy above that shipped it.** Deliberately scoped: `storage.rules` and `firestore.indexes.json` are byte-identical to the row above, so neither was in the deploy - and the new `(employeeIds CONTAINS, status ASC, startTime DESC)` composite STAYS, since it serves the technician History scope, not the crew signal. No export change (25 -> 25): `crewStatus` was internal to `notification_utils.js`, never an exported function, so the live list still matches `functions/index.js` exactly. No deletion, retry or secret prompt. **Removed across the whole stack**, not just revoked in rules: the fourth assignee `allow update` disjunct and the `crewStatus`/`crewStatusAt`/`crewStatusBy` bounded fields; `updateCrewStatus` and the three record fields in Dart; the chips in `DetailsFieldRecordView` and the whole `DetailsCrewSignalLine`; `notifyAdminsOfCrewStatus`, `crewStatusSignal`, `crewStatusSenderName`, `CREW_STATUS_VALUES` and `buildCrewStatusMessage` in `functions/`; seven l10n keys from BOTH ARBs (`untranslated.json` back to `{}`); and two whole test files. The field-notes, Start-job and assignee-photo grants from the row above are UNTOUCHED - only the crew signal went. **Live rules re-read after deploying and verified**: no `crewStatus` anywhere, and exactly three assignee disjuncts remain (mark-done, field notes, Start job) - a count now pinned by `appointment_employee_update_rules_test.dart`, which failed on the stale `hasLength(4)` and was the one test that caught the change. Two dead things fell out and were removed: `isTerminalStatus` in `notification_policy.js` (eslint `no-unused-vars`) and two imports in `details_view_leaf_widgets.dart` (`flutter analyze`). **No data migration needed and none run**: `isValidAppointmentData` has no `keys().hasOnly`, so a leftover `crewStatus` field on a document is inert and an admin edit of such a doc still passes. Prod emptiness was NOT verified directly - the Firestore MCP query tool fails on this machine with `read_time cannot be in the future` (local clock skew) - but no shipped client could have written the field: the app build never shipped and the grant was assignee-only through that unshipped UI. Post-deploy: **zero ERROR log entries**. Pre-flight and post-change: eslint clean, 79 jest suites / 1725 tests, `flutter analyze` at `No issues found!`, 3231 flutter tests. Still outstanding: the app build (Dart half). |
| 2026-09-06 | `4fd4a976` | **`firestore:indexes` ONLY** | 25 (unchanged) | **Step 1 of the 1.56/1.57/1.58 backend deploy — indexes alone, ahead of rules and functions.** Prod was 15 live indexes against 19 declared; this deploy submitted the four missing composites and the live list is now 19, matching `firestore.indexes.json` exactly with **no drift in either direction** — the CLI printed no "indexes defined in your project that are not present" warning, so there was nothing to delete out-of-band and `--force` never came near it. The four: `clients (searchTokens CONTAINS, name ASC)`, `clients (archived ASC, jobCount DESC)`, `clients (archived ASC, createdAt DESC)`, `appointments (historySearchScopes CONTAINS, status ASC, startTime DESC)`. The first and fourth serve `searchClients`/`searchHistory`; the middle two serve the search-first clients screen's Most jobs / Recently added sorts. All four read `CREATING` immediately after the deploy — **confirm `READY` before deploying the functions that query them**, or every such query fails `FAILED_PRECONDITION` exactly as if the index were missing. **Nothing else went out**: no functions, no rules, no storage. `firestore.rules` compiled clean as part of the run (the CLI always checks it) but was NOT deployed, so the `searchTokens`/`historySearchScopes` 240-caps and `locationSharingEnabled` are still absent from live rules. All 8 TTL policies in `fieldOverrides` were verified present in the file before deploying. Pre-flight was scoped to what an indexes-only deploy can break — `firestore.indexes.json` parses, 19 indexes / 41 field overrides / 8 TTL policies — and the functions lint and jest suites were deliberately SKIPPED, since no JS ships in this target; they are a gate for step 3, not this one. Still outstanding, in order: the two prod backfills (`backfill-search-tokens.js`, `backfill-client-sort-fields.js`), then `functions` + `firestore:rules` (25 -> 29, adding `searchClients`, `searchHistory`, `findAppointmentConflicts`, `restoreAppointmentStatus`), then the app build. |
| 2026-09-06 | `4fd4a976` | **prod backfills only** (no deploy target) | 25 (unchanged) | **Step 2 of the 1.56/1.57/1.58 deploy: the two release-prerequisite backfills, both RUN LIVE by the owner.** `backfill-search-tokens.js` - dry run **720 clients / 720 patched, 84 appointments / 84 patched** (100% is correct, not a red flag: `searchTokens` and `historySearchScopes` are new fields no shipped build writes, so nothing carried either). `backfill-client-sort-fields.js` - dry run **720 scanned / 658 patched**, the 62 untouched being the clients that already had `jobCount` from a `recountClientJobs` firing; 720 tracks the 714 the address backfill saw on 2026-08-28. **Verified independently rather than on the run's own word**, since the live output was not captured: three `clients` docs read back through the Firestore MCP carry well-formed `searchTokens`, `jobCount: 0` and `createdAt`, and two `appointments` docs carry `historySearchScopes` scoped `all:` plus one `emp:<docId>:` run per assignee - all five stamped `updateTime` 2026-09-07T00:32-00:33Z. The sampled tokens also confirm the two load-bearing ordering rules hold in PROD data, not just in the unit tests: each word emits its WHOLE token before any prefix (`t:5142340818` precedes `t:5`), and the text and phone runs INTERLEAVE (`t:gisele`, `p:4509734201`, `t:g`, `p:450`, ...) rather than appending phones after texts - the bug that once made appointment search-by-phone index nothing at all. Largest sampled array was ~118 entries, well under the 240 rules cap. **All four composites from the row above reached `READY`** - live index count 19, matching `firestore.indexes.json` exactly. Note the backfills needed no index (both page on `orderBy("__name__")`), so they ran while the composites were still building. Two `clients` write triggers fired ~1440 times between them and both correctly no-opped: `waveUpsertCustomer` gates on `mappedFieldsHash`, which projects only Wave-mapped fields, and `propagateClientEdits` gates on `relevantClientChange` (name/phone/composed address) - so **no Wave write-back burst**, the failure mode `wave/triggers.js` names a bulk backfill as the shape of. One accepted caveat: a client whose appointments all predate `recountClientJobs` (2026-08-01) and who has had no appointment write since is now stamped `jobCount: 0` while having history. Cosmetic - it drives the Most jobs sort and the roster badge only, `deleteClient` gates on a live `count()` and the client detail reads real appointments - and strictly better than being ABSENT from the sort, which is what the missing field caused. Self-corrects on the next appointment write. **Tokens go stale for any client edited by a currently-shipped build**, which writes no `searchTokens`; both scripts are idempotent, so a re-run just before the app build ships closes that window. Still outstanding: step 3, `functions` + `firestore:rules` (25 -> 29), then the app build. |
| 2026-09-06 | `4fd4a976` | **`functions` + `firestore:rules`** | **29** (was 25) | **Step 3, and the end of the three-release backend debt spanning 1.56/1.57/1.58.** Four CREATES - `searchClients`, `searchHistory`, `findAppointmentConflicts` (`indexed_search.js`) and `restoreAppointmentStatus` (`appointment_actions.js`) - plus 25 updates. **Verified by NAME, not by count** (`functions_list_functions` diffed against the 29 `exports.` in `functions/index.js`): zero missing, zero orphans. **Section 4a was checked and did not apply**: every already-deployed callable's `assertPayloadShape` allowlist is byte-identical to the `7dc56658` tree, confirmed by extracting the key sets from both revisions. The only apparent change was cosmetic - `placesAutocomplete` keeps `["input", "sessionToken"]`, reformatted across three lines by the `assertAdminCall` signature reorder - and `employee_accounts.js`/`account.js` are unchanged outright. The four new callables ADD capability without removing a key, so **this deploy breaks no build in the fleet**. No deletion prompt, no retry-change prompt, no secret prompt; run `--non-interactive` so any prompt would have failed the deploy rather than hung. Env vars cleared and confirmed empty first. **Live rules re-read after deploying and verified** to carry all four new pieces: `locationSharingEnabled is bool` in `isValidUserData` AND in the `isAvailabilityOnlyChange` `hasOnly` list (both halves - the self-service availability write needs the second or an employee's own toggle is refused), `searchTokens` capped at 240 in `isValidClientData`, `historySearchScopes` capped at 240 in `isValidAppointmentData`, and the `startedAt`/`completedAt` client write ban on BOTH create (`hasAny`) and update (`affectedKeys().hasAny`), the type checks in `isValidAppointmentData` having been reduced to type checks only. Pre-flight: eslint clean, **86 jest suites / 1838 tests green**. `flutter analyze` and the Dart suite were NOT run - no Dart ships in this target; they are step 4's gate. Post-deploy logs: the only ERROR entries are the known Cloud Run startup-probe noise (`Invalid request, unable to process.` out of the CORS middleware in `https.js`, one pair per updated callable at 00:41), the same signature the 2026-09-03 row records, and **none of the four new functions produced one**. One WARNING worth naming: a single 401 on `findAppointmentConflicts` at 00:41:48, seconds after its create - an unauthenticated probe arriving before the `allUsers` invoker binding propagated. Nothing has logged against these services since, so it did not recur; `gcloud` is not installed on this box, so **the IAM binding was not confirmed directly and one real call from a signed-in admin build is what settles it**. Storage rules were deliberately NOT in this deploy - `storage.rules` is byte-identical to the 2026-09-03 tree. **Steps 1-3 of the four-step release are now complete** (indexes READY, backfills run, backend live). Only the app build remains. **Rollback is backend-safe only until that build ships**: the old client-side scan path is unreachable in a shipped build (`firebaseFunctionsProvider` is non-nullable), so after shipping, roll back the app, never the backend. |
| 2026-09-06 | `4fd4a976` | **no deploy — prod verification only** | 29 (unchanged) | **The appointment-images migration is COMPLETE; step 4 has nothing left to do.** Recorded here because this log is the authority the plan docs point at, and they had it wrong. `clear-appointment-picture-arrays.js --dry-run` against prod returned `0 array entries across 0 appointments (0 still carried an array, 84 scanned)` - no refusals, no `pictureCount` re-stamp. **Verified independently rather than on the script's word**, since a zero from a sweep and a zero from a sweep that saw nothing look identical: all 84 appointment docs read through the Firestore MCP under a `pictures`/`pictureCount` field mask. **Not one holds a non-empty `pictures` array.** Every doc is one of exactly two shapes - ~45 carry an empty `pictures: []` with no `pictureCount`, the rest carry `pictureCount` (0/1/2) and no array field at all - and both shapes reconcile with the script's logic: the empty-array docs skip the clear path on `pictures.length === 0` and then fail `needsRecount` (absent counter, empty subcollection), and the counter docs already agree with their subcollections. **Step 3 was not outstanding either**: the array retirement shipped in **1.49.0+78 on 2026-08-22** (`db6686f4`, released `647660a5`). `docs/plans/README.md` read the gate as "ship the NEXT app build"; it was the fleet ageing off builds that touch the array, settled by the SAME evidence that retired `#compat-1.47.0` - the owner confirmed the whole fleet on **1.53** by 2026-08-29, four releases past 1.49. **The empty-array residue is PERMANENT and is not a defect.** The clear script early-returns before its delete on a zero-length array, so no number of runs removes those fields; they are inert (empty, within the rules' `size() <= 100`, never emitted by `toMap()`). Don't re-run the script expecting them to go, and don't file them as outstanding. `.claude/rules/images.md` previously implied the clause only covered "documents the clear script has not reached" - it actually guards these empty lists now, and has been corrected. **Why it is empty: the clear script ALREADY RAN, on 2026-08-27** - dry run and live run agreed exactly, `cleared 14 array entries across 11 appointments, 67 scanned`, no refusals, no identity-less entries. Today's run is simply the second one. That also explains the two shapes: the script issues `FieldValue.delete()`, so the docs it cleared carry no `pictures` key at all, while the ~45 empty arrays are docs that never held a photo and which it never touches. Every number reconciles; nothing here is unexplained. The fleet gate for the 2026-08-27 run was read off re-running the idempotent COPY backfill the same day and getting the SAME 14 photos / 11 appointments (67 scanned, up from 55 only because 12 more appointments existed) - identical counts five days on means no build still writing the array had added an entry. **Keep that technique**: it settles a fleet gate without any visibility into fleet versions. |
| 2026-09-07 | `462a1907` | **`functions` + `firestore:rules`** | 29 (unchanged) | **The crew-notes rules grant, and the 2026-09-07 audit batch.** Step 3 of the four; `firestore:indexes` and `storage.rules` are byte-identical to `4fd4a976`, so both targets were deliberately out of scope and all 19 live indexes were confirmed `READY` beforehand rather than assumed. **No export change (29 -> 29)** — verified by NAME, not by count: the live `functions_list_functions` result was diffed against the 29 `exports.` in `functions/index.js` and the sorted lists are identical, zero missing and zero orphans. 29 *Successful update operation*, 0 creates, 0 deletions. Run `--non-interactive`, so any prompt would have failed the deploy rather than hung; none fired. Env vars cleared and echoed empty first — the audit log's principal is the owner's account with **no `agent-name/claude_code` stamp**, which is the check that the clearing actually took. **The whole point of the deploy is `firestore.rules`:** a new `appointments/{id}/fieldNotes` subcollection carrying the crew notes shipped in `7a43a7bb`..`051a6b6d` and had never been live, so that feature was inert in prod regardless of the app build — an append-only grant (`create` for an admin or an assignee, `hasOnly` the four keys `text`/`authorId`/`authorName`/`createdAt`, `text` bounded 4000 and non-empty, `authorId == myDocId()`, `createdAt == request.time`; `update`/`delete` admin-only). `parentAppointment()` moved up out of the `images` block to the parent `appointments` match so both subcollections share it. **It carries the 2026-09-07 audit's B5 fix**, which is the reason the cap is 250 and not 200: `composeEmployeeName` joins two 100-char halves with a space and legitimately reaches 201, and `users.name` is capped at 250, so a 200 cap made a crew note `permission-denied` for anyone in that range with no field to correct. **Live rules were re-read after deploying** and carry all of it, the 250 included. **Section 4a was checked and did not apply**: every `assertPayloadShape` allowlist in `functions/wave/callables.js` is key-for-key identical to the `4fd4a976` tree (`new Set()` x4, `new Set(["schedule"])` x1) — the five Wave callables moved from `assertPayloadShape` to the composed `assertAdminCall`, which changes the opening but not one key, the same shape as the 2026-09-03 row. So this deploy breaks no build in the fleet. Also in `functions/`: `wave/sync_run.js`, `wave/triggers.js` and `wave/import_schedule.js` changes from the same audit batch, plus seven `functions/scripts/*` edits which do not deploy. Pre-flight: `npm run lint` clean, jest **1848 passed / 86 suites** — which matches the figure `docs/audits/CODEBASE_AUDIT_2026-09-07.md` recorded, so that count is now verified rather than claimed. `flutter analyze` and the Dart suite were NOT run: no Dart ships in this target, they are step 4's gate. Post-deploy logs 17:13-17:43Z: 16 ERROR entries, **all** the known Cloud Run startup-probe noise (`Invalid request, unable to process.` out of the CORS middleware in `https.js`, one pair per updated callable) timestamped 17:42:14-17:42:35, the rollout moment — same signature as the 2026-09-03 and 2026-09-06 rows; the six WARNINGs are `Request has invalid method. GET` from the same probe. Nothing real. **Deployed from an UNPUSHED tree** — `462a1907` was local-only at deploy time; push it so this hash is resolvable. **Only step 4, the app build, still stands**, and note `462a1907` sits 22 commits above the 1.58.0+87 release commit with no CHANGELOG entry, so that build needs a version bump first. Two prod scripts remain outstanding and are unrelated to this deploy: `backfill-client-address-street.js` (dry-run only since 2026-08-28) and a re-run of `backfill-search-tokens.js` just before the app build ships, since currently-shipped builds write no `searchTokens`. |
| 2026-09-09 | `462a1907` | **no deploy — prod script verification only** | 29 (unchanged) | **Two outstanding prod scripts resolved, and NEITHER needed a write.** Recorded here because the row above names both as outstanding and the plan docs point at this log as the authority. **(1) `audit-wave-contract.js --verbose` RAN against prod** — the last open step of the Wave contract's Phase 1, blocked since 2026-08-30 for want of credentials: `724 clients scanned, 0 would be REFUSED by Wave (blocking), 1 advisory (phone:NOT_DIALABLE)`. The report is CLEAN — not one client on file would dead-letter. 724 tracks the 714 the address dry run saw on 2026-08-28 and the 720 the token backfills saw on 2026-09-06, so the scan reached the whole collection. The single advisory is the already-analyzed `2wcEiCNztsWYUYNXYBEm`, a person's NAME typed into the `phone` box which Wave has synced as that customer's phone; it is advisory by design, documented at the rule in `customer_contract.js`, and needs no fix. This UNBLOCKS Phase 2 (enforce) — but note the design's own gate cuts both ways: zero refusals is equally consistent with the contract not yet catching anything, since all three founding incidents were repaired BEFORE this ran, so Phase 2's first question is what it would catch that Wave caught for us, not whether to flip enforcement on. **(2) `backfill-client-address-street.js --dry-run` returned `724 scanned, 0 reduced, 724 left alone`** (plus 40 skipped as the documented no-locality-fields class), so its LIVE RUN IS WITHDRAWN RATHER THAN PENDING — it would write nothing. The 2026-08-28 figure of `114 reduced` predated the segment-removal guard and was the pure-re-spacing class that guard exists to refuse (`streetFromAddress` rejoins with `", "`, so a doc whose tail does not match its own locality fields still read as changed); two examples were spotted in that list and read as outliers, and on this evidence they were the whole population. **The script's decision logic is unchanged since the guard landed** — verified by diff: `a808fe03` was the `bootstrapScript` refactor and `462a1907` only added `scanByName` paging. Two alternatives cannot be excluded from this box — an unrecorded live run, or the Wave import having rewritten those docs — but each needs an event nothing recorded, and the import gates on `lastSyncedHash`, which both address shapes hash identically, so it would have SKIPPED them. **Incidental, worth recording because it cost a false start:** `functions/node_modules` did not exist on the Windows box at all, so every script died on `Cannot find module 'firebase-admin/app'` from `_project.js` before printing a banner. `npm ci` in `functions/` fixed it; installed tree verified `firebase-admin@14.3.0` / `firebase-functions@7.3.2` with `@google-cloud/firestore 8.7.1` and `Query.prototype.count` PRESENT — the check the 2026-08-10 downgrade incident calls for, since the jest suite mocks admin and passes either way. **Still outstanding after this: only the app build**, plus the `backfill-search-tokens.js` re-run immediately before it ships. |
| 2026-09-10 | (uncommitted at run time; tree = `e0460805` + the `--verbose` flag below) | **no deploy — prod scripts only** | 29 (unchanged) | **Three live backfills run, and the whole read-only sweep re-run behind them.** Recorded because the row above names the token backfill as the release prerequisite and the plan docs point at this log as the authority. **(1) `backfill-clients-archived.js` — 1 patched** (`GAQJI0Ctadf8ppVHbSOE`, `name=5145531449`, a person under the `clients.name`-IS-the-phone rule). That doc was INVISIBLE in the clients list, which filters `archived == false`, while still turning up in search. Both create paths stamp the field, so one missing it is an anomaly rather than a legacy straggler and its origin is unexplained. Re-verified after: `0 patched, 725 already had the field`. **(2) `backfill-client-sort-fields.js` — 725 scanned, 2 patched**, the two being new clients with no appointment yet, so `recountClientJobs` had never stamped `jobCount` and they were absent from the Most jobs sort. That is the documented normal state, NOT a defect to fix in the app: `jobCount` is function-owned and `firestore.rules` refuses any client write that touches it (`allow create ... && !('jobCount' in request.resource.data.keys())`), so this backfill is the fix and it stays a release prerequisite. **(3) `backfill-search-tokens.js` — 0 patched live**, against a dry run minutes earlier reporting `13 clients / 1 appointment`. **That gap is UNEXPLAINED and is the one thing on this row to carry forward.** The only writes in between were the 3 documents above, but Cloud Functions logs show ~14 distinct client-document writes at `18:25:06Z`, each firing `waveUpsertCustomer` and `propagateClientEdits` under one `cloud_event_id`, plus one `recountClientJobs`. The suspected chain is the `runWaveDaily` rider on `waveUpsertCustomer` running a full import, whose update branch writes `searchTokens` — but that is a RECONSTRUCTION from timing and event count, not a confirmed finding; do not carry it forward as fact. **Consequence for the next operator: a dry-run count here can go stale if anything writes a client doc before the live run.** Re-verified after: `0 / 0` across 725 clients and 104 appointments. **Read-only sweep, all clean:** `audit-wave-contract.js --verbose` 725 scanned / 0 blocking / 1 advisory (the same `2wcEiCNztsWYUYNXYBEm`); `count-legacy-image-urls.js` 16 image docs / 0 url-only / 0 `pictures[]` arrays; `count-multi-day-appointments.js` 104 scanned / 5 multi-day runs / 3 still open, longest 12 d — the standing per-day-split decision, unchanged; `backfill.js --dry-run` 7 scanned / 0 orphans; `backfill-appointment-images.js` and `clear-appointment-picture-arrays.js` both 0/0, confirming the photo migration complete; `drain-wave-queue.js --dry-run` 0 queued. **Still outstanding: only the app build**, plus the `backfill-search-tokens.js` re-run immediately before it ships. |
| 2026-09-11 | `dd210c71` | **`firestore:indexes` ONLY** | 29 (unchanged) | **Step 1 of the Wave Phase 2 release, and the ordering is INVERTED — read this before deploying the rest.** One composite created: `clients (wave.syncState ASC, name ASC)`, id `CICAgPj-05MK`, declared by `e0460805`. `firestore.indexes.json` was the ONLY deployable file touched in this run; `functions/`, `firestore.rules` and `storage.rules` were deliberately left behind, and `firestore.rules` and `storage.rules` remain byte-identical to `462a1907`. **The usual backend-before-app rule does NOT apply to this phase** (`docs/plans/2026-09-10-wave-validated-contract-phases-2-4.md`, Deploy ordering): `WaveSyncBadge._badgeConfig` (`wave_sync_badge.dart:97`) renders `SizedBox.shrink()` for a state it does not know, so a backend that starts writing `blocked` before the app build ships leaves every shipped build showing those clients NO badge at all — strictly less signal than today, where the same client eventually dead-letters and reads "Sync error". Correct order from here: **this index READY → the 1.60.0+89 app build → the Wave enforcement backend → the Phase 3 backfill.** Pre-flight: `npm run lint` clean, jest **1876 passed / 87 suites** (from 1848 / 86 at `462a1907`; Phase 2 added the contract-sole-producer suite and `20205f51` added script cases). Run `--non-interactive`, so any prompt would have failed the deploy rather than hung; none fired — **no deletion prompt, no index-drift line, no secret prompt**. Env vars cleared and echoed empty in the SAME shell invocation as the deploy — note PowerShell tool state does not persist between calls, so clearing them in a prior command would have been a no-op and the audit log would have carried the `agent-name/claude_code` stamp. **The export list was NOT re-verified in this run and does not need to be** — no `functions` target was deployed; the 29-name diff against `functions/index.js` from the 2026-09-07 row still stands. Post-deploy: the new index was `CREATING` immediately after the deploy and again on a re-read minutes later. **`firebase firestore:indexes` does NOT report state** — it lists a `CREATING` index identically to a `READY` one, so the Firebase MCP `firestore_list_indexes` (parent `.../collectionGroups/clients`) is the only source that settles it; `CICAgPj-05MK` reached `READY` later in the same session and was re-read to confirm it: **all 20 composites `READY`, none `CREATING`, no drift**. Step 1 is therefore COMPLETE and the app build is not waiting on an index. Nothing queries the new index yet — Phase 2's Dart is unshipped and its backend is undeployed — so a slow build blocks nothing but step 2. |
| 2026-09-11 | `dd210c71` | **no deploy — prod script only** | 29 (unchanged) | **`backfill-search-tokens.js`, run LIVE: `clients: 725 scanned, 0 token rows patched` / `appointments: 106 scanned, 0 token rows patched`.** Banner read `target: schedulingapp-88727 (LIVE)`. This was the live run, not a dry run — the banner and both count lines carried no `[dry-run] ` prefix, which is the only thing that distinguishes them (`_project.js:printTargetBanner`, and the `tag` in `backfill-search-tokens.js:98`). It wrote nothing, so skipping the dry run cost nothing on this occasion; the sequence still stands for any script that patches. **Zero patched is the finding, and it is worth more than a clean no-op.** Against the 2026-09-06 run (720 clients / 84 appointments patched) both collections have GROWN — +5 clients, +22 appointments — and every new document already carries tokens that match what `searchIndexTokens` derives. So nothing has been writing the pre-2026-09-04 shape, and there is no drift accumulating behind the shipped fleet. **It does NOT close the release prerequisite on its own.** `docs/plans/README.md` §1 requires the re-run to be *immediately before* the app build uploads, because a client edited between now and then is invisible to `searchClients` until the tokens are rebuilt; the script is idempotent and this run proves a re-run is cheap (one full scan, zero writes). Treat today's numbers as a measurement of drift, and the ship-time run as the one that satisfies step 2. Unrelated to the same day's `firestore:indexes` deploy in the row above — this script touches no index and the `clients (wave.syncState, name)` composite's build state has no bearing on it. |
| 2026-09-12 | `595091d9` (unpushed at deploy time) | **`firestore:indexes` ONLY** | 29 (unchanged) | **Step 1 of Issue 2 (cancelled jobs excluded from `clients.jobCount`, `docs/plans/2026-09-11-four-bug-fixes.md`).** One composite created: `appointments (clientId ASC, status ASC, dayIndex ASC)`, id `CICAgNiZnYEK`, `CREATING` on the re-read right after the deploy; the other 20 composites all `READY`, so live now matches `firestore.indexes.json` (21). No drift line, no prompt, run `--non-interactive`; env vars cleared and echoed empty in the SAME PowerShell invocation. **`functions` was deliberately HELD, by owner call:** the backend diff against `462a1907` is not just Issue 2 (`client_job_count.js`) - `dev` also carries Wave Phase 2 enforcement (`wave/customer_contract.js`, `customers.js`, `customers_import.js`, `triggers.js`, `worker.js`, `callables.js`), and that phase's INVERTED order forbids it before the 1.60.0+89 app build ships (the owner confirmed it has not). A full `functions` deploy from this tree would have shipped both. Live functions verified by NAME: the 29 deployed match the 29 `exports.` in `functions/index.js`, zero missing, zero orphans - still the `462a1907` code. Pre-flight on this exact tree: `npm run lint` clean, jest **1913 passed / 89 suites**. `firestore.rules` and `storage.rules` are byte-identical to `462a1907`, so neither was a target. **Still standing:** confirm `CICAgNiZnYEK` reaches `READY` via `firestore_list_indexes` (`firebase firestore:indexes` does not show state); the unverified question of whether `clientId ==` + `status ==` alone is served by index merge; then the app build; then `functions` (Wave enforcement + Issue 2 together); then `recount-client-jobs.js` dry run and live, and `backfill-wave-blocked.js` last. |
| 2026-09-12 | (uncommitted at run time; tree = `91610d1b` + the 1.61.0+90 release prep) | **no deploy — pre-build prod checks only** | 29 (unchanged) | **The two release-prerequisite backfills before the 1.61.0+90 app build, plus the index gate.** `backfill-search-tokens.js --dry-run`: `clients: 726 scanned, 0 token rows patched`, `appointments: 107 scanned, 0 token rows patched` — up one of each since the 2026-09-11 live run and both already tokenized, so the shipped build is still writing the index; no live run was needed. `backfill-client-sort-fields.js --dry-run`: `726 scanned, 1 sort rows patched`, run LIVE by the owner, then a re-run dry run read `726 scanned, 0 sort rows patched`, which is the proof it landed (the live output itself was not captured). The one doc was almost certainly a client added since 2026-09-06 with no booking: **neither create path stamps `jobCount`** — the app cannot (rules reject the field) and `wave/customers_import.js` does not — so a new client is absent from the Most jobs sort until its first appointment write. Not release-blocking; it will RECUR, and wants a server-side `jobCount: 0` stamp on create. Both banners read `target: schedulingapp-88727 (LIVE)`. **Index gate:** `CICAgNiZnYEK` `appointments (clientId, status, dayIndex)` confirmed `READY` via `firestore_list_indexes`, all 21 composites `READY`, none `CREATING`. **The app build is unblocked.** Still standing, in order: the 1.61.0+90 upload, then `functions` (Wave Phase 2 enforcement + `recountClientJobs`), then `recount-client-jobs.js` dry run and live, then `backfill-wave-blocked.js` last. |
| 2026-09-13 01:46Z | `38c8225b` (+ uncommitted `scripts/repair-client-address-mojibake.js`, which no function imports) | **`functions:placesAutocomplete,placesGetDetails,placesReverseGeocode` ONLY** | 29 (unchanged) | **The Places mojibake fix (`mojibake.js`, `38c8225b`), deployed ALONE by owner call.** All three callables now pass their upstream response through `repairMojibakeDeep`, so `Calixa-Lavallã©E` reaches the app as `Calixa-Lavallée`. Response shape and accepted payload keys are unchanged, so every shipped build is compatible and rollback is safe. **Named targets are what kept this from shipping the held work:** the uploaded bundle is the whole `dev` tree (Wave Phase 2 enforcement and the Issue 2 `client_job_count.js` included), but only these three services were updated, and the other 26 still run `462a1907` code. **So any later `functions:<name>` deploy from this tree ships that function's Phase 2/Issue 2 code too.** Pre-flight: `npm run lint` clean, jest **1935 passed / 91 suites** (the mojibake and places-shaping suites from `38c8225b`, plus the repair script's). Run `--non-interactive`; env vars cleared and echoed empty in the SAME PowerShell invocation; no deletion, secret or retry prompt. Verified by NAME: 29 deployed = 29 `exports.` in `functions/index.js`, identical diff. Post-deploy logs for all three contain no startup error, only the known `Request has invalid method. GET` / `Invalid request, unable to process.` pairs at 01:46:22–27Z, which is the unauthenticated outside sweep described below, not our code. **Existing corrupt data is NOT fixed by this deploy:** the new `repair-client-address-mojibake.js` repairs `address`/`addressLine2`/`city`/`province`/`postalCode`/`country` and rebuilds `searchTokens`; not yet run against prod. Each patched client fires `propagateClientEdits` (FUTURE appointments follow) and `waveUpsertCustomer` (Wave gets the corrected spelling); past appointments keep the old address. **Still standing, unchanged:** the 1.61.0+90 upload, then the full `functions` deploy (Wave Phase 2 + `recountClientJobs`), then `recount-client-jobs.js`, then `backfill-wave-blocked.js`. The Issue 2 index-merge question (`clientId ==` + `status ==`) is STILL unverified; the MCP aggregation tool was unavailable this run. |
| 2026-09-13 | `38c8225b` (+ uncommitted repair script) | **no deploy — prod script only** | 29 (unchanged) | **`repair-client-address-mojibake.js --dry-run`: `clients: 726 scanned, 0 repaired`**, banner `target: schedulingapp-88727 (LIVE)`. No stored client carries the known mojibake pattern, so no live run is needed and the Places deploy above is the whole fix. The script matches only the `Ã`/`Å` lead-byte pattern `mojibake.js` repairs, and scans `/clients` only: an appointment address picked straight from Places was not checked. |
| 2026-09-13 02:07Z | `38c8225b` (+ uncommitted repair script, which no function imports) | **full `functions`** (26 updated; the 3 Places callables skipped as unchanged since the 01:46Z row) | 29 (unchanged) | **Step 3 of the Wave Phase 2 inverted order, and Issue 2's function — deployed after the owner confirmed the 1.61.0+90 app build SHIPPED.** This is the held work from the 2026-09-12 rows: Wave contract enforcement (`wave/customer_contract.js`, `customers.js`, `customers_import.js`, `triggers.js`, `worker.js`, `callables.js`) and the cancelled-visit `jobCount` aggregate (`client_job_count.js`). `firestore.rules`, `storage.rules` and `firestore.indexes.json` have no commits since `595091d9` and no uncommitted diff, so none was a target; `firestore_list_indexes` re-read immediately before the deploy: **all 21 composites `READY`**, `CICAgNiZnYEK` included. Pre-flight on this tree: `npm run lint` clean, jest **1935 passed / 91 suites**. Run `--non-interactive`; env vars cleared and echoed empty in the SAME PowerShell invocation; no deletion, secret or retry prompt. **Verified by NAME:** 29 deployed = 29 `exports.` in `functions/index.js`, zero missing, zero orphans. **Post-deploy logs (01:50Z → 02:08Z, WARNING+):** only the rollout-time `The request was not authenticated … Empty Authorization header value` on each trigger's Cloud Run URL and the known `Request has invalid method. GET` / `Invalid request, unable to process.` pairs on the callables — no application error, no startup failure, no `FAILED_PRECONDITION`. `recountClientJobs` (revision `recountclientjobs-00034-rir`) and `waveUpsertCustomer` (`waveupsertcustomer-00064-qaq`) both `ACTIVE`, startup TCP probe passed first attempt; neither had processed a real event yet at 02:08Z, so neither new code path is proven in prod. **The Issue 2 index-merge question was settled from CONFIG, not a live query:** `fieldOverrides` keeps `ASCENDING`/`COLLECTION` single-field indexes on both `appointments.clientId` and `appointments.status`, which is what lets Firestore serve the equality-only `clientId == + status ==` count by merging them; both empirical probes failed on tooling (`firestore_run_aggregation_query` not found; `firestore_query_collection` → `400 The requested 'read_time' cannot be in the future`). The first real proof is the recount dry run below, or the next cancel — watch `recountClientJobs` for `FAILED_PRECONDITION`, which on a `retry: true` trigger is a redelivery loop. **Not run, and could not be:** `audit-wave-contract.js` (Phase 3 Step 4.1) and `recount-client-jobs.js --dry-run` both stopped before the first read — this Windows box has NO application-default credentials (no `GOOGLE_APPLICATION_CREDENTIALS`, no `%APPDATA%\gcloud\application_default_credentials.json`), in Bash or PowerShell. Known consequence of the inverted order, accepted by the plan: a device still on a pre-1.61.0 build shows NO badge for a `blocked` client until it updates. **Still standing, owner-run, in order:** `audit-wave-contract.js --verbose` (a blocking client found now has already stopped syncing); `recount-client-jobs.js --dry-run` then live, back to back; `backfill-wave-blocked.js --dry-run --verbose`, live, then `--dry-run` again expecting 0 patched (Phase 3 Steps 4.2–4.4; `blocked + advisory` must equal the audit's `flagged`); then Settings → Wave shows the advisory client. |
| 2026-09-13 | `38c8225b` (same tree as the row above) | **no deploy — prod scripts only, run by the owner** | 29 (unchanged) | **The three scripts the functions deploy above left standing; all ran clean, so Wave Phase 3 and Issue 2 are COMPLETE.** Every banner read `target: schedulingapp-88727 (LIVE)`. **(1) `audit-wave-contract.js --verbose`: 726 scanned, 0 blocking, 1 advisory** — `2wcEiCNztsWYUYNXYBEm` `phone:NOT_DIALABLE`, the same client as 2026-09-10, so enforcement stranded nobody. **(2) `recount-client-jobs.js`: dry run `726 scanned, 9 job counts patched`, then live `--verbose` `726 scanned, 9 patched`** — `2yQcDxCFk4vfa1lspm8A 0→1`, `D3UAcS5cgQGrlDnXYqbH 4→3`, `HsFuz1lkC5XlMRtzSOTB 1→0`, `fkwhgTWTBnrIhn2Oy9gP 2→1`, `gDBC0c9KFqizVBP8UWxF 1→0`, `m8TPSKca7xowm9JjPx8B 2→1`, `r2y39JJDdsI4C701nQou 2→1`, `w9r7eyI3p6rZE8jlMcK2 0→1`, `zKz14nYLIajUUaZEbXXz 1→0`. **The dry run completing is also the empirical answer to the Issue 2 index-merge question**: `countJobsFor` ran its four aggregates over all 726 clients without `FAILED_PRECONDITION`, so `clientId ==` + `status ==` IS served by merging the single-field indexes and no `(clientId, status)` composite is needed. Seven moves are down by one: the cancelled-visit exclusion. **The two `0→1` are NOT that fix and are worth understanding:** `planClientSortPatch` (`client_sort_backfill_policy.js:17-18`) stamps `jobCount: 0` on any client MISSING the field without counting, so a client whose only appointments predate `recountClientJobs` (created 2026-08-01) and were never rewritten was stamped a false 0 by the 2026-09-06 sort backfill (658 patched) and sat at the bottom of Most jobs since. This absolute recount corrected every such client, so nothing is left in prod; the policy still stamps a blind 0 if the backfill is run again. **(3) `backfill-wave-blocked.js`: live `--verbose` `726 scanned, 1 verdict rows patched, 0 BLOCKED, 1 advisory` (`2wcEiCNztsWYUYNXYBEm`), then `--dry-run` `0 verdict rows patched`** — exactly Phase 3 Step 4.3's expectation and 4.4's idempotence; `blocked + advisory` = 1 = the audit's flagged count. The pre-live `--dry-run --verbose` (Step 4.2) was not captured. Owner then pressed Sync with Wave: "all up to date", which is correct — 0 blocked means nothing queued and `WaveBlockedList` renders nothing. **Still standing:** Phase 3 Step 4.5 — the advisory is NOT in Settings (that list is `blocked` only; the plan step was wrong and is corrected); confirm it on the client's own page, where the badge reads "Phone has no digits to dial". Then only Wave Phase 4, which carries its own deploy (`waveSetImportSchedule` needs the §4a allowlist treatment). |

### The `Invalid request, unable to process.` entries are NOT the rollout probe

Seven deploy rows above call these "the Cloud Run rollout probe hitting
`onCall`" and wave them through. **That diagnosis is wrong**, established
2026-08-22 by querying the whole retained window rather than only the deploy
window each row happened to look at. The rows are left as written — they record
what was believed at the time — but do not carry the claim forward.

What the log actually shows:

- The entries arrive in **tight bursts** (a few seconds), hitting many
  callables, roughly twice each.
- **Two of those bursts fall on days with no deploy at all** — 2026-08-20
  03:36Z and 2026-08-22 02:01Z. A rollout probe cannot happen without a
  rollout.
- In the same 2026-08-20 burst, `validateUploadedImage` — an auth-required
  Storage trigger, not a callable — logged *"The request was not authenticated…
  Empty Authorization header value"*. **A rollout probe is internal and
  authenticated; it does not produce IAM auth failures.**

So this is **unauthenticated GET traffic from outside sweeping the project's
Cloud Run URLs**. Services that require authentication reject it at the IAM
layer; the callables, which must allow unauthenticated invocation, reach the
container, where `firebase-functions`' own callable handler logs
`Request has invalid method. GET` and then
`Error: Invalid request, unable to process.` A `*.run.app` hostname is
published in Certificate Transparency logs, so the URLs do not need to be
guessed.

**It is benign and it is not fixable in this codebase.** Nothing reaches any
handler: the method check rejects the request before App Check, `assertAdmin`
or any payload validation runs, so no rate-limit slot is consumed and no data
is touched. The log line is emitted by the library above our code, so there is
no catch site to silence it. And the public invoker cannot be removed — the
Firebase client SDK authenticates a callable at the app layer with an ID token
plus App Check, not with Cloud Run IAM, so `allUsers` is required for the app
to work at all.

**Why it still matters:** the old note taught the reader to dismiss these as
deploy-window noise, which also dismisses a burst arriving at 03:36 on a day
nothing shipped. If you want them out of triage, add a **Cloud Logging
exclusion** on `textPayload:"Request has invalid method"` rather than reasoning
past them each time. To identify the source, query the console for the
`run.googleapis.com/requests` log and read `httpRequest.remoteIp` /
`httpRequest.userAgent` — the Firebase MCP tool does not surface those fields.

### RESOLVED 2026-08-19: `functions/` was AHEAD of prod as of 1.46.2+75

**Closed by the 2026-08-19 row above**, which deployed the whole
`functions/` tree. Everything described below now runs in prod, and the one
piece of remediation it left owed is **CLOSED as of 2026-08-22**: the download
tokens of anyone deactivated between 2026-08-16 and 2026-08-19 were never
rotated (deploying the fix does not act retroactively), but **no account was
deactivated in that window**, so the affected set is empty and there is nothing
to re-fire. Kept verbatim below because the failure mode it describes is worth
recognising again.

**Do not read this as the rotation being safe to lose.** It was deleted from
the tree in `db6686f4` and disappears from prod on the next `functions` deploy,
after which deactivating someone rotates nothing — so any legacy
`appointments/*/images` doc still carrying a `url` remains a permanent,
rules-free download link. Whether that set is empty is the image-url audit count
in the archived audit snapshots, not a question this paragraph answers.

The 2026-08-16 row above deployed the follow-up audit. The release pass cut
straight after it (**1.46.2+75**) then changed `functions/` again, so prod is
running older bodies than the repo — the same shape as the three-day gap the
deployment-status note in `docs/CLOUD_FUNCTIONS.md` warns about, and again with
**no export change (25 → 25)**, so a count check looks clean.

**One of these is a security fix that has never actually run in prod.**
`rotateAssignedImageTokens` resolved the Storage bucket into a local while
`rotatePictures` reads it off `deps`, so on the only path production takes the
bucket arrived `undefined`; every object rotation threw into that module's own
swallow and the control logged "nothing rotated" while rotating nothing. Every
test injected a bucket, so the branch was covered nowhere. It is fixed and
pinned by a new case, but **the download tokens of anyone deactivated since
2026-08-16 were NOT rotated** — re-running a deactivation (flip the person to
`active` and back) is what re-fires the trigger for them.

**A second gap in the same control is closed in this release.** The rotation's
query orders by `endTime`, and Firestore omits documents missing the ordered
field — so an appointment with no `endTime` (legacy and console-written docs
reach the server; `day_slice_utils.js` carries its own branch for them) was
never reached and kept its permanent tokens, with nothing logging it. A second
**unordered backstop pass** now covers those: same cap, served by the automatic
`employeeIds` array index, so **still no index change**.

Also pending, all `functions/`-only and behaviour-preserving apart from the
above: `syncUsersByUid` now runs the rotation **after** the Auth disable +
`revokeRefreshTokens` rather than before (ordered first, a slow rotation
delayed — or, on a timeout, skipped — the revocation the branch exists for);
the rotation's photo loop and `runOnSiteFlipPass` are chunked rather than flat
`Promise.all`s; `_pruneExpired` uses the `_chunk` helper already in its file.
`firestore.rules`, `storage.rules` and `firestore.indexes.json` are
**unchanged** since the 2026-08-16 row, so those targets may be omitted.

**One cost claim was investigated and found overstated — recorded so it is not
re-litigated.** The rotation's parent writes fire up to 500
`notifyAppointmentChanges` invocations, but each returns before any Firestore
read (a `pictures`-only diff yields no events, and `endCardOnTerminal` finds no
targets in memory), and `recountAppointmentPictures` is **not** fired by them at
all — it triggers on the images subcollection, not the parent. So the fan-out is
invocation count only, comfortably inside the free tier. The property that makes
it cheap is now pinned by a test rather than assumed.

### The `#compat-1.37.1` shim — RETIRED 2026-08-08

**Gone.** No shipping code or rule is gated on it any more. Kept here as the
record of what was removed and why, so none of it is re-added by accident.
`grep -rn "#compat-1.37.1"` still hits this file, the two CLAUDE.mds,
`docs/ARCHITECTURE.md`, `docs/CLOUD_FUNCTIONS.md`, `docs/cost-breakdown.html`
and the dated `docs/audits/` + `docs/plans/` snapshots — all of those are
history now, not instructions. It also hits `functions/wave/callables.js` and
`lib/features/wave/data/wave_service.dart`, which were **never** deletion sites
(see the `waveImportCustomers` note at the end of this section).

The shim existed for 1.37.1+64 (`2b1ace5`, head of `origin/notification`), which
was the App Store build from P4c until 1.40.0+65 replaced it. The owner
confirmed 2026-08-08 that **every device in the fleet is on 1.40+**, which is
the gate this always waited on — note the gate is "no device still RUNS it", not
"it is no longer downloadable". Retired in one sweep:

| What | Why it could go |
|---|---|
| `createEmployeeInvite`, `redeemSignupCode`, `invites.js`, `signup_code_utils.js` (+ both jest suites), the `/signupCodes` rules block and its `firestore.indexes.json` TTL entry | Only 1.37.1 called them (`firebase_employees_repository.dart:82`, `:109`). 1.40.0+ has no reference anywhere in `lib/`. The `signupCodes` collection was verified **empty in prod** before the TTL policy was dropped, so nothing is stranded. |
| `allow delete` on `/users`, and the fourth `/users` read clause (`email_verified` + `invited` + email match) | 1.40.0+ has no users-doc delete path, and an invited person reads their own doc through clause 3 (`uid` is set at creation by `createEmployeeAccount`). |
| `allow delete` on `/clients` | 1.40.0's Delete button is behind `kShowTestingDeleteClient = kDebugMode`, so it is unreachable in any release build; 1.41+ removed it outright. `deleteClient` is now the only delete path in rules as well as in code. |

**Two real holes closed with it** — while the grants were live, an admin on the
old build could delete a client with job history (orphaning those appointments,
exactly what `deleteClient`'s live `count()` gate prevents) or delete a `users`
doc (permanently orphaning every past appointment's `employeeIds` crew link).

**One related hole is still OPEN and is NOT part of this sweep:** `allow update`
on `/users` denylists only `uid`/`termsAcceptedAt`/`locationConsentAt`, so
`email` can still be written directly to Firestore without the matching Auth
change. This was closed by the 2026-09-01 audit cleanup; see
`docs/archive/CODEBASE_AUDIT_2026-09-01.md` for the original finding and
implementation note.

Also unblocked by this retirement, and likewise not done here: **disabling open
sign-up in the Firebase Auth console** (F1 in
`docs/audits/SECURITY_ASSESSMENT_2026-08-04.md`), which shared this gate because
1.37.1's invite acceptance called client-side `register()`.

Note `waveImportCustomers` was tagged `#compat-1.37.1` but is **not** a deletion
site and keeps its (inaccurate, two-way) name: renaming a deployed callable
breaks every shipped build, not just the old one.
