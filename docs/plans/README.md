# Active plans — index and outstanding work

Swept 2026-08-11, re-swept 2026-08-15, 2026-09-06, 2026-09-09 and 2026-09-12,
re-swept 2026-09-13, 2026-09-19 and **2026-10-01** against what the code, `git log` and the deploy log
actually say. **The 2026-10-01 pass** found the index ten days stale: it still
called the admin password reset undeployed (live since 2026-09-29, `306ed848` +
`cc38be5d`) and §1 still described 1.61.0+90 as the newest build, while
1.62.0, 1.62.1 and 1.63.0 have all been cut since and none has shipped. It
moved two finished plans and two superseded audits to `docs/archive/` (listed
below the index) and carried those audits' surviving owner items into §6. The 2026-09-13 pass recorded 1.61.0+90 as SHIPPED, the full
`functions` deploy (Wave Phase 2 + Issue 2, `38c8225b`) and all three prod
scripts behind it as run, and `fresh-header` as merged — three rows below still
called those undeployed, unrun or unmerged. The same pass then **moved four
finished plans to `docs/archive/`** (the address split, Wave Phase 1's task
list, the four bug fixes and Wave Phase 3, whose one unrecorded in-app check is
carried in §3), and corrected two rows the plans themselves contradicted:
analytics (GA and all custom dimensions were done 2026-09-10) and CarPlay (the
shipped build proved distribution signing). The 2026-09-12 pass corrected the fresh-header row, which still
read "PLAN, NOT STARTED" while all four phases had been built on 2026-09-11 —
`AppTopBar` has carried zero `AppBar(` since `23b3bcd0`. The 2026-09-06
pass moved fourteen documents to `docs/archive/` and rebuilt an index that had
gone 21 files behind. The **2026-09-09 pass moved six plans plus the whole
redesign program** — the search-first clients pair, the add-job client-picker
pair and the crew-record / role-gates pair, because **the deploy gate all six
banners still cited as open had closed** (the backend went live 2026-09-06/09-07
at 29 functions, all 19 composites `READY`, both prod backfills run, the
crew-notes rules grant deployed); then the redesign program spec and its 15
sub-documents, because the device runbook was that folder's last live item and
it passed the same day.

**Everything left in this directory is live work.** The closed sections of this
file were retired with them — see
[`docs/archive/2026-09-09-plans-index-retired-sections.md`](../archive/2026-09-09-plans-index-retired-sections.md).
Dated audit snapshots live in `docs/audits/` until superseded, then they move to
the archive too.

**Current state of the code is `CLAUDE.md`, `docs/ARCHITECTURE.md` and
`docs/CLOUD_FUNCTIONS.md` — never a plan doc.** A plan records how something was
decided and built; several here have unticked checkboxes for work that shipped
weeks ago, because they were executed without ticking. Trust the status banner
at the top of each file, not its boxes.

---

## Index

| Doc | State |
|---|---|
| `2026-09-28-admin-password-reset.md` | **BUILT 2026-09-29, backend DEPLOYED 2026-09-29, app NOT SHIPPED.** Admin resets an ACTIVE employee's password (emails aren't real inboxes, so Forgot password can't work): server-owned `passwordResetRequired` flag, temp password, sign-out everywhere, forced Change password screen. Both callables (30 → 32) and the rules denylist field went live at `306ed848`, the review fixes at `cc38be5d`; the app half rides 1.63.0+93. **S4** of the 2026-09-28 audit (a demoted account's reset leaves it disabled) was approved, built and DEPLOYED 2026-10-07 (`8739e48c`). Plan: `2026-09-28-admin-password-reset-plan.md`. |
| `2026-10-06-remote-config-kill-switches-design.md` | **BUILT 2026-10-06; functions DEPLOYED 2026-10-07 (`29fa4072`); app half NOT SHIPPED** (landed after 1.63.0+93 was cut). (Design approved 2026-10-06.) Remote Config kill switches (address autocomplete, presence/live map, Live Activities, Wave sync) enforced in the app AND the functions, fail-open, plus a `min_supported_build` forced-update screen. Plan: `2026-10-06-remote-config-kill-switches-plan.md`. |
| `2026-10-06-remote-config-kill-switches-plan.md` | **BUILT 2026-10-06; functions DEPLOYED 2026-10-07 (`29fa4072`); app half NOT SHIPPED** (landed after 1.63.0+93 was cut). 17 TDD tasks: functions (policy, loader, Places / Live Activity / Wave gates), then the app (service, providers, five gates, `UpdateGate`), then docs. Apple ID recorded (6788556855). |
| `2026-10-06-rules-docs-cut-down.md` | **COMPLETE 2026-10-07.** All 15 rules files cut to invariants plus one-clause reasons; history in ADR-0001..0183; `check_rules.dart` in CI; corpus ~608 KB → ~263 KB, always-loaded ~90 KB → ~43 KB. One owner decision still open (moving Flutter-only rules from `appointments.md` to the calendar file). |
| `2026-10-07-followups.md` | **OPEN.** Leftovers from the rules cut-down: isolated runs of four touched test files, the Dashboard 2x-text overflow, and two owner decisions (the `/users` create denylist; moving Flutter-only rules out of `appointments.md`). |
| `2026-10-06-shared-dart-js-fixtures.md` | **BUILT 2026-10-07 on `dev`** (`74fa736c..19713ea1`, tests only, no deploy). Nine hand-mirrored Dart↔JS pairs now read one shared JSON fixture each under `test/fixtures/shared/`; a registry test fails if a fixture loses its reader on either side. No divergence found. |
| `2026-10-06-repeatable-deploys.md` | **BUILT; first workflow deploy 2026-10-07 (`61811650`).** `deploy.yml` (manual dispatch, `production` approval, Workload Identity, never `--force`), deploy checkers, deploy-log PR, and `functions/scripts/run.js` with a fresh-count confirm. Task 1 is owner-only GCP/GitHub setup. |
| `2026-09-28-admin-password-reset-plan.md` | **EXECUTED 2026-09-29.** Task-by-task TDD plan for the design above; its "Deviations from the spec" section records where the real code forced a different shape. Archive both once 1.63.0+93 ships and S4 is decided. |
| `2026-09-12-month-end-overdue-review.md` | **BUILT (`ed59a6a5`), functions DEPLOYED 2026-09-19 (`608b817a`), NOT SHIPPED** — rides the next app build (1.63.0+93 is cut; nothing has shipped since 1.61.0+90). Owner steps after it ships: turn the month-end switch on for Paul, register the `count` GA dimension. The plan's banner lists the seven deviations from the design. |
| `2026-09-12-live-map-improvements.md` | **BUILT (`ed59a6a5`, `e544fb01`), DEVICE PASS DONE 2026-09-19 (owner), NOT SHIPPED** — rides the next app build (1.63.0+93). App-only, no backend deploy. Owner steps once the build ships: republish `privacy-policy.html` and `accessibility.html` to `es-pro-legal`, flip the Apple tester's Test account switch. |
| `2026-09-07-analytics-followups.md` | **Code COMPLETE, device-verified 2026-09-10; every open item is off-repo.** GA is enabled and linked, and all 27 custom dimensions are registered (owner, 2026-09-10) — this row called both outstanding until 2026-09-13 while the plan had them ticked. Left, all unticked and so *unknown* now that 1.61.0+90 has shipped with analytics in it: the App Store Connect privacy answers (Product Interaction, and Analytics added to Device ID) plus owner sign-off on `PrivacyInfo.xcprivacy`; whether the release build used `FIREBASE_ANALYTICS_WITHOUT_ADID=true`; four events never observed in DebugView (`search_used`, `note_added`, `photo_added`, `contact_action`); the optional `FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO` Info.plist key; and the post-release `build_env` and ~48 h Events-page checks. |
| `2026-09-12-open-followups.md` | **OPEN — three items still blocked** (items 4 and 5 CLOSED; re-verified against the code 2026-10-01): the split container vocabulary on the appointment form (an owner decision — the declined Option B), the street/city address split (a functions deploy — the Places field mask still omits `structuredFormat`), and device verification of both rebuilt dropdowns (macOS Accessibility permission). The plan it came from is archived: `docs/archive/2026-09-12-add-appointment-sheet-structure.md`. |
| `2026-09-10-wave-validated-contract-phases-2-4.md` | **Phases 2-4 DEPLOYED** (Phase 4 at `608b817a`, 2026-09-19); the design doc is archived. Left: republish privacy + terms to `es-pro-legal`; ship the app build that drops the Settings cadence picker (gone from `lib/`, rides 1.63.0+93); and, as its own §4a deploy once 1.61.0 has aged out — which cannot begin until a newer build ships — delete `waveSetImportSchedule` (still exported as a no-op). |
| `APP_STORE_SUBMISSION.md` | **The live release runbook**, now for updates rather than a launch — the app shipped. Its unticked boxes have never been reconciled against four shipped submissions, so read one as *unknown*, not *outstanding*. |

**Moved to `docs/archive/` on 2026-10-09.** Cancelled by the owner (not
needed): `2026-09-12-dashboard-redesign.md` and the three Siri docs
(`2026-07-10-siri-app-intents-design.md`, `2026-07-19-siri-app-intents-implementation.md`,
`2026-07-20-siri-phase4-write-actions.md`).

**Moved to `docs/archive/` on 2026-10-01.** Two plans and two audits:
`2026-09-12-add-appointment-sheet-structure.md` (shipped in 1.61.0+90; its open
items are the open-followups row), `2026-08-30-wave-validated-contract-design.md`
(all four phases deployed; the tail is the phases-2-4 row), and the superseded
audit snapshots `CODEBASE_AUDIT_2026-09-07.md` and `CODEBASE_AUDIT_2026-09-19.md`
(their surviving owner items are in §6). The two 2026-09-19 moves below were
also missing from `docs/archive/README.md` until this pass.

**Moved to `docs/archive/` on 2026-09-19.** Two plans, both finished:
`2026-09-04-carplay-driving-task.md` (shipped in 1.61.0+90; the behavioural
checks — the four actions, the technician view, App Lock — confirmed all clear
by the owner 2026-09-19) and `2026-09-11-fresh-header-redesign.md` (shipped in
1.61.0+90; Phase 3's device pass done 2026-09-19).

**Moved to `docs/archive/` on 2026-09-13.** Four plans, all shipped and deployed:
`2026-08-28-address-street-locality-split.md` (its backfill had nothing to do),
`2026-08-30-wave-validated-contract-implementation.md` (Phase 1's task list),
`2026-09-11-four-bug-fixes.md` (1.61.0+90, function `38c8225b`, recount run) and
`2026-09-11-wave-validated-contract-phase-3.md` (backfill run live; Step 4.5 is
in §3). The Wave design doc and the phases-2-4 plan stay here for Phase 4.

**Moved to `docs/archive/` on 2026-09-09.** Six shipped-and-deployed plans:
`2026-09-04-clients-page-search-first.md` + its implementation plan,
`2026-09-05-add-job-client-picker.md` + its implementation plan (1.58.0+87), and
`2026-09-06-crew-record-and-role-gates.md` + its implementation plan (crew notes,
the live admin gate, History made admin-only). Their one shared outstanding item
— shipping the app build — is §1 below, not six open plans. Plus the **redesign
program**: `2026-07-29-redesign-program.md` and `redesign-subdocs/` (P1–P7's
build record, the device runbook included), complete and owing nothing.

---

## What is outstanding

Everything below is open. This file is a work list; it is not where the history
goes.

### 1. The app build — 1.63.0+93 CUT, NOT SHIPPED (re-verified 2026-10-01)

**The newest SHIPPED build is still 1.61.0+90** (`dd8c4863`, 2026-09-13).
1.62.0+91 never shipped, 1.62.1+92 was superseded before shipping, and
**1.63.0+93** (`cc38be5d`, `pubspec.yaml`) is the build that carries everything
since: the month-end overdue review, the live map rework, Wave Phase 4's
cadence-free Settings, the 2026-09-19 / 09-23 / 09-28 audit fixes and the admin
password reset.

**Its backend is fully live**, so there is no deploy debt ahead of it:
`functions` at 32 exports, all deployed — `306ed848` (2026-09-29, the two
admin-reset callables, the `passwordResetRequired` rules denylist, the 09-28
audit fixes) then `cc38be5d` (the review fixes). The 2026-09-23 rollout's rules,
indexes and `backfill-client-buildings.js` ran 2026-09-29 (`e70b494d`); its
step 6, the app release, is this build. `git diff cc38be5d HEAD` over
`functions/`, both rules files and `firestore.indexes.json` is empty. Read
`docs/DEPLOYMENT.md`'s log for what production runs — never this file.

- **Rollback direction is APP, never backend** — unchanged since 1.61.0+90: the
  shipped build calls the server-side search callables, and the backend has
  only grown supersets since.
- **After it ships:** the owner steps in the month-end, live-map and analytics
  rows; the legal republish (privacy, terms, accessibility); the Crashlytics
  re-check on the new build. Once 1.61.0+90 then ages out, the
  `waveSetImportSchedule` deletion (§3) becomes possible.
- **Distribution signing with the CarPlay entitlement is proven** by 1.61.0+90
  (closed in §4).

### 2. Siri — CANCELLED 2026-10-09

Owner: not needed. Phase 4 onward will not be built and the Phase 1–3 device
pass is dropped. The plans are archived (`docs/archive/2026-07-*-siri-*.md`).

### 3. Wave — Phases 1–4 DEPLOYED

**Update (2026-10-01): unchanged since 2026-09-19 — the cadence-free app build is 1.63.0+93, cut but unshipped, and the design doc is archived.** **Update (2026-09-19): Phase 4 is DEPLOYED** (`608b817a`, all 29 updated, no
export change) and the cadence wording is gone from `docs/legal/`. Left:
republish privacy + terms to `es-pro-legal`, ship the app build that drops the
cadence picker, and later — its own §4a deploy once 1.61.0 has aged out —
delete `waveSetImportSchedule`.

**Current state (2026-09-13):** Phase 2 enforcement is shipped (1.61.0+90) and
deployed (`38c8225b`), and the Phase 3 backfill ran live (726 / 1 patched /
0 blocked / 1 advisory). Phase 4 is built on `dev` and waits on its deploy
(see the phases-2-4 row). **Phase 3 Step 4.5 is DONE**
(owner, 2026-09-13): the in-app check of `2wcEiCNztsWYUYNXYBEm` was confirmed
on the shipped build. The history below explains how it
got here; its "unshipped"/"waits on" wording is the state at the time.

Phase 1 is complete: deployed 2026-08-30 (`fe9edc51`, report-only) and the prod
replay ran **2026-09-09 — 724 clients, 0 blocking, 1 known advisory** (a person's
name typed into the `phone` box on `2wcEiCNztsWYUYNXYBEm`, which Wave has synced
and which is advisory by design).

**Zero refusals is a question, not a green light.** The design's gate says
enforce once the report is clean, and it is — but all three founding incidents
(the `CA-NY` province, the stale `waveCustomerId`, the blank name) were fixed or
repaired *before* the replay ran, so a clean report is equally what a repaired
backlog looks like. What the replay cannot tell us is whether the contract would
catch a NEW failure shape. So Phase 2 opens with *"what would this contract have
caught that Wave caught for us, and what would it still miss?"* — enforcement's
value here is prospective, not a backlog to clean. Phases 3–4 (backfill, then the
`worker.js` split and cadence removal) follow it.

**Phase 2 was written and built 2026-09-10** — `e0460805` on branch
`wave-contract-enforce`, pushed, **nothing deployed and no app build shipped**.
`docs/plans/2026-09-10-wave-validated-contract-phases-2-4.md` is the task list
and its deploy-ordering section is binding: this phase **inverts** the repo's
backend-first rule. Phase 4's `waveSetImportSchedule` removal is a callable
deletion and needs its own deploy under `docs/DEPLOYMENT.md` §4a, not a
ride-along.

**Phase 3 now has its own plan**, written 2026-09-11 and archived 2026-09-13:
`docs/archive/2026-09-11-wave-validated-contract-phase-3.md`. It supersedes
Task 9 of the phases-2-4 doc, whose three-step stub was wrong on two counts —
the backfill does NOT write nothing (`verdictPatch` records advisory problems
too, and there is one advisory client on file), and it must carry no scan cap.
Its Tasks 1-3 were built 2026-09-12 (`functions/scripts/backfill-wave-blocked.js`,
17 jest tests); Task 4 is the live run and waits on the enforcement deploy.

### 4. CarPlay — CLOSED 2026-09-19

Shipped in 1.61.0+90, and the behavioural checks that were the last open item
— the four actions (Directions, Start, Complete, Call), the technician view and
App Lock — were confirmed all clear by the owner on 2026-09-19 (App Lock kept
as it behaves today). The plan is archived at
`docs/archive/2026-09-04-carplay-driving-task.md`.

### 5. Analytics — every open item is off-repo

Code is complete and device-verified (2026-09-10), **Google Analytics is enabled
and all 27 custom dimensions are registered** — this section called both
outstanding until 2026-09-13, while the plan had them ticked. What is left is
unticked in the plan, so read it as *unknown* rather than *outstanding* now that
1.61.0+90 has shipped with analytics in it: the ASC App Privacy answers (Product
Interaction, and Analytics added to Device ID), whether the release build used
`FIREBASE_ANALYTICS_WITHOUT_ADID=true`, four events never observed in DebugView,
and the post-release `build_env` and Events-page checks.

### 6. Off-repo and console items

- **A hard budget cap for Google Maps Platform is still unset** —
  `docs/audits/AUDIT_FOLLOWUPS.md`, the one item there still open. Needs GCP
  billing access.
- **The Time Sensitive Notifications capability** on the App ID in the Apple
  Developer portal. The entitlement itself is in the repo (`af92e7fe`).
- **ASC App Privacy needs Precise Location added.**
- **The `liveActivityCards` TTL policy** cannot be created yet — blocked by
  Firestore itself.
- **Carried from the archived 2026-09-07 audit** (unverified since; read as
  *unknown*): the **Crashlytics re-check** on a shipped build (possible since
  1.61.0+90 — do it on 1.63.0+93 once out), the **Wave "Retry failed" press**
  on a real dead-letter, and the **Xcode `InfoPlist.strings`** confirmation.
  Its I25 is open BY DESIGN — fix only if observed in the wild.
- **Carried from the archived 2026-09-19 audit:** **I12**, which needs a real
  bad record to reproduce. (Its other item, the three stale `.claude/worktrees/`
  agent directories, was DONE 2026-10-01: each held only uncommitted snapshots of
  work that is on `dev` in a later form, and they were removed.)

### 7. Prod scripts — what must never be re-run, and what is closed

**Nothing here is outstanding** (2026-09-13). The list exists so nobody runs
one again, or runs one expecting work it already did.

- **Run: `backfill-wave-blocked.js`** — 2026-09-13, live: 726 scanned,
  1 patched, 0 blocked, 1 advisory; re-run 0. Idempotent, so a later re-run is
  free and should read 0.
- **Run: `recount-client-jobs.js`** — 2026-09-13, live: 726 scanned, 9 patched
  (7 cancelled-visit corrections, 2 false zeros left by
  `backfill-client-sort-fields.js`, whose policy stamps `jobCount: 0` without
  counting — re-running THAT backfill can mint the false zero again).

- **`backfill-client-phone-from-name.js` — NEVER RUN IT AGAIN.** It ran
  2026-08-08, lifting the phone out of `clients/{id}.name` and renaming `name` to
  "First Last". Correct for the app, wrong for Wave — `name` syncs VERBATIM as
  the Wave customer name, so it renamed those customers on real invoices. The
  rule was reversed by owner call 2026-08-14.
- **`backfill-client-name-with-phone.js`** ran 2026-08-14 (504 renamed) and
  **destroyed the stored name on docs with no `firstName`/`lastName`** — it
  predated the first/last split. `restore-client-name-halves.js` (deleted 2026-09-28; in git history) repaired those
  from `clientName` on the client's SETTLED appointments and never touches
  `name`; `docs/audits/audit-renamed-client-names.js` (also deleted) was its read-only twin, and
  the two are kept deliberately in step — reading one rule's report and running
  another rule's repair is the failure mode.
- **Run: `backfill-search-tokens.js`** — 2026-09-06 (720 clients / 84
  appointments patched), re-run LIVE 2026-09-11: **725 clients / 106
  appointments scanned, 0 patched**. Both collections have grown since and
  every new document already carries correct tokens, so nothing is writing the
  pre-2026-09-04 shape and no drift is accumulating. The pre-ship re-run
  was done 2026-09-12 (dry run: 726 clients / 107 appointments, 0 to patch) and
  1.61.0+90 has shipped, so this is closed.
- **Run: `backfill-client-sort-fields.js`** (2026-09-06, 720 scanned / 658
  patched).
- **Closed with nothing to do: `backfill-client-address-street.js`.** The
  2026-09-09 dry run returned 724 scanned, **0 reduced**; the 2026-08-28 figure
  of 114 predated the segment-removal guard and was the pure-re-spacing class it
  refuses. A live run would write nothing.
- **Closed: the appointment-images migration**, all four steps, verified in prod
  2026-09-06. The empty-array residue is PERMANENT and is not a defect — the
  clear script early-returns on a zero-length array, so no number of runs removes
  those fields.
- **`purgeExpiredHistory` was found PAUSED once** (resumed 2026-08-23) with no
  record why. Only the Cloud **Scheduler** page shows a job's STATE —
  `functions:list` and Cloud Run render a paused job identically to a healthy one
  — so check it there after any deploy touching a scheduled function.
- **The `signupCodes` collection and its TTL policy stay in prod**, deliberately:
  verified empty, rules deny all access. Never `--force` the policy away.
- **One accepted risk is live in the rules:** the 500-char cap on
  `clients.addressLine2` (2026-08-15) sits over docs the already-deployed Wave
  import wrote uncapped. If an opaque `permission-denied` ever appears on an
  ordinary client save, check that field first.

### 8. Live Activities on a multi-day job — DECIDED 2026-09-12, not built

**Owner call: one card per day.** Not taken: a countdown to today's window end on
one long-lived card, or keeping the skip.

A card counting down to an end four days out would sit on the Lock Screen for the
whole job, so `resolveReminderForAssignee` only starts a card for a single-day
window (`dayCountOf(c) <= 1`, `functions/travel_utils.js`, built 2026-08-11); the
`leaveNow` push still goes out on day 1, the only day with a departure time.

**What the decision actually reaches is narrower than it reads.** Multi-day
CLIENT jobs have been one document per day since 2026-08-27, so each day already
passes `dayCountOf <= 1` and already gets its own card — that half is the chosen
behaviour today. What still skips is a WIDE document: a multi-day *timed*
personal block (all-day blocks never reach the travel sweep) and any legacy wide
doc. **The build is not just dropping the guard:** the sweep gates on
`startTime > now`, so days 2+ of a wide document never become candidates at all.
A per-day card there needs the sweep to consider each day's window through
`day_slice_utils.js`, not the document's first start.
