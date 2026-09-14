# Active plans — index and outstanding work

Swept 2026-08-11, re-swept 2026-08-15, 2026-09-06, 2026-09-09 and 2026-09-12,
**re-swept 2026-09-13** against what the code, `git log` and the deploy log
actually say. The 2026-09-13 pass recorded 1.61.0+90 as SHIPPED, the full
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
| `2026-09-12-month-end-overdue-review.md` | **BUILT 2026-09-13 on `dev`, NOT DEPLOYED, NOT SHIPPED.** Functions deploy BEFORE the app build (old builds degrade to the calendar on tap); no index, rules or export change. Owner steps after the build ships: turn the month-end switch on for Paul, register the `count` GA dimension. The design below is what was built; the plan's banner lists the seven deviations. Mockup picked: Option C's count + checkbox cards with Option B's month splitters, one oldest-first scroll. A last-of-month 6 pm push to Paul only, via an admin-only per-person `monthEndReviewPush` switch that must be turned on for him after the build ships (a fourth isolated rider on `sendDailyJobDigest`, so no new scheduled job and the export count stays 29), a drawer row with a live count, and a select-several screen writing Complete or Not done (`cancelled`) behind a confirmation, with no Undo. Functions-only deploy — no index, rules, TTL or new export (checked against `firestore.indexes.json` and `firestore.rules` 2026-09-12). No implementation plan yet. |
| `2026-09-12-dashboard-redesign.md` | **DESIGN PICKED 2026-09-12 (Option B), NOT STARTED.** A Today / Trends switch under the title. Today: on site now with progress through each job, needs-attention chips, compact next up, crew tiles against `maxJobsPerDay`. Trends: every period number and chart. Unassigned count and banner removed (owner: a job is never unassigned). App-only, no new reads, tour ids unchanged but their copy must be rewritten. Three open questions for the build. No implementation plan yet. |
| `2026-09-12-live-map-improvements.md` | **BUILT 2026-09-13 on `dev`, NOT SHIPPED.** App-only, no backend deploy (the optional rules type check was skipped). Owner steps: once the build ships, republish `docs/legal/privacy-policy.html` to `es-pro-legal` (everything else in it went live 2026-09-14; only the three two-hour passages differ), re-check and republish the crew-map paragraph of `docs/legal/accessibility.html` (it describes 1.61's staff list, which the team sheet replaces), flip Test account on `users/AIMcaSKenB2eyYXCTEp4` after the build ships, and a device pass (fresh fix on resume, the iOS prompt after Turn on, sheet drag over the map). The plan's "As built" section records the deviations. Mockup picked: Option B's peek team sheet for the admin map plus Option C's full-screen "Be on the team map" ask page for staff. Scope: an admin-only `isTestAccount` switch that hides the Apple tester from every team list, pins hidden after 2 h, a fresh fix on app open, a sheet listing who is missing and why, and ghost-control restyle. Needs only a privacy-policy republish; no functions or indexes, and a rules type check is optional. The tester is an admin + dispatcher whose pin is a 9-day-old leftover presence doc. No implementation plan yet. |
| `2026-09-07-analytics-followups.md` | **Code COMPLETE, device-verified 2026-09-10; every open item is off-repo.** GA is enabled and linked, and all 27 custom dimensions are registered (owner, 2026-09-10) — this row called both outstanding until 2026-09-13 while the plan had them ticked. Left, all unticked and so *unknown* now that 1.61.0+90 has shipped with analytics in it: the App Store Connect privacy answers (Product Interaction, and Analytics added to Device ID) plus owner sign-off on `PrivacyInfo.xcprivacy`; whether the release build used `FIREBASE_ANALYTICS_WITHOUT_ADID=true`; four events never observed in DebugView (`search_used`, `note_added`, `photo_added`, `contact_action`); the optional `FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO` Info.plist key; and the post-release `build_env` and ~48 h Events-page checks. |
| `2026-07-10-siri-app-intents-design.md` | Design, 6 phases. Phases 5–6 unscoped. |
| `2026-07-19-siri-app-intents-implementation.md` | Phases 1–3 built; **no device pass ever run** — the one feature here that has never been exercised on hardware at all. (CarPlay has since been driven in the Simulator, so it is no longer in this category; its remaining checks are behavioural, see §4.) Six read intents in `ios/SiriIntents/`, never exercised by voice. |
| `2026-07-20-siri-phase4-write-actions.md` | **NOT STARTED.** Mac + Apple-portal session. |
| `2026-08-30-wave-validated-contract-design.md` | **Phase 1 COMPLETE** — built and deployed 2026-08-30 (`fe9edc51`, report-only), and the prod replay **ran 2026-09-09: 724 clients, 0 blocking, 1 advisory.** Phase 2 (enforce) was since built, shipped and deployed — see the phases-2-4 row. |
| `2026-09-11-fresh-header-redesign.md` | **ALL FOUR PHASES BUILT 2026-09-11, merged to `dev` and SHIPPED in 1.61.0+90** (`fresh-header` is an ancestor of the release commit `dd8c4863`). (This row said "PLAN, NOT STARTED" until 2026-09-12; the code disagreed from the day it was written — `AppTopBar` has carried zero `AppBar(` since `23b3bcd0`.) Option D, page-colour header with ghost controls on every screen; Clients took the chip row + grouped card list, Filter button and building filter kept. App-only, four phases (sheets, forms and dialogs added the same day). A post-build review caught five defects the green suite was hiding, and a 2026-09-12 simulator pass caught four more — the worst, `SheetHeaderBar` truncating "New Appointment" on the widest iPhone, reached every sheet in the app. All nine fixed and pinned. **What is left is Phase 3's DEVICE PASS.** |
| `2026-09-12-add-appointment-sheet-structure.md` | **OPTION C BUILT 2026-09-12, merged to `dev` and SHIPPED in 1.61.0+90.** The TEMPLATES section is deleted and its chips now sit under the `Service / Title` field they fill, so the form opens on the first required field; the `apptTemplates` tour step KEEPS its member and only its target moved, so no storage key changes and nobody replays. Options A and B were not taken, and **the split container vocabulary they would have resolved is still open** (SCHEDULE is a `SheetPanel`, WHO and DETAILS are loose fields). The doc also records a second same-day change to that sheet: the client and address **attached dropdowns** were rebuilt onto one shared row (fill + lift, dividers, avatars, two-line addresses, the 48pt tap floor) and the sub-floor "Attach" button AND its word were dropped by owner call. **Neither dropdown was verified on a device**, and a street/city address split is still open behind a Places field-mask change and a functions deploy. |
| `2026-09-12-open-followups.md` | **OPEN — four items still blocked, the CRLF item closed.** The 2026-09-12 session's deliberate non-actions, each blocked on a different thing: the split container vocabulary on the appointment form (an owner decision — it IS the declined Option B), the street/city address split (a functions deploy, because the Places field mask omits `structuredFormat`), device verification of both rebuilt dropdowns (macOS Accessibility permission — synthetic clicks cannot drive `TextButton`/`CupertinoSwitch`), and Phase 3's device pass. **The CRLF item is CLOSED 2026-09-12** — only two of the four files were actually CRLF in git, and both are LF now. Written because a decision that lives only in a conversation gets re-litigated. |
| `2026-09-10-wave-validated-contract-phases-2-4.md` | **PHASE 2 COMPLETE — all four inverted-order steps done.** Index `CICAgPj-05MK` `READY` (2026-09-11) → app build 1.61.0+90 shipped → enforcement backend deployed 2026-09-13 02:07Z (`38c8225b`) → Phase 3 backfill run (row below). **Phase 4 BUILT 2026-09-13 on `dev`, NOT DEPLOYED**: `worker.js` split five ways, the import's per-update transactional guard (priced and taken — only updates to existing clients transact, worst case ~726 at 25 concurrent), and the cadence deleted with `waveSetImportSchedule` kept as an accepted-and-ignored `#compat-1.61.0` no-op. Backward-compatible with every shipped build, so it can deploy before or after the next app build — but hold it a few quiet days after the 2026-09-13 enforcement deploy, since it changes the import's write path. Retiring the compat entry is its own later deploy (§4a). |
| `2026-09-04-carplay-driving-task.md` | **BUILT, COMPILED, SIGNED and DRIVEN — merged to `dev` (`78e72903`) and SHIPPED in 1.61.0+90.** Written 2026-09-04, UI design finalised 2026-09-09 (Today / Week tab bar, Today ranked Now / Next / Later, mark-complete hand-off alert, refresh on every connect, business-wide admin view — decisions 9–16), implemented the same day. **The Swift compiled clean on 2026-09-10** (Xcode 26.6, first contact with a compiler, no edits) and `RunnerTests` runs green; six files under `ios/Runner/CarPlay/` plus `ios/RunnerTests/CarPlayTemplateBuilderTests.swift`. **The signing gate is CLOSED** — the capability is on the App ID and the entitlement lives in `ios/Runner/Runner.entitlements`, with `RunnerCarPlay.entitlements` deleted; under AUTOMATIC signing the key must move BEFORE the profile can carry it, which inverts the order this row used to give. **The `CPTabBarTemplate` risk is closed too**: the tab bar installs as the root and it has been driven in the CarPlay Simulator against production data. Left: the four actions, the App Lock question and the **technician view (never on a screen — every drive was an admin snapshot)**. **Distribution signing is proven** by the shipped build, which carries the key in `Runner.entitlements` at `dd8c4863`. |
| `APP_STORE_SUBMISSION.md` | **The live release runbook**, now for updates rather than a launch — the app shipped. Its unticked boxes have never been reconciled against four shipped submissions, so read one as *unknown*, not *outstanding*. |

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

### 1. The app build — SHIPPED 2026-09-13

**1.61.0+90 is out** (release commit `dd8c4863`, owner-confirmed), and the
backend behind it is fully live: `functions` at `38c8225b` (2026-09-13 02:07Z,
29 exports by name), all 21 composites `READY`, and every prod script the
release needed has run — `backfill-search-tokens.js` and
`backfill-client-sort-fields.js` before the build (2026-09-12),
`recount-client-jobs.js` and `backfill-wave-blocked.js` after the deploy
(2026-09-13). `git log 38c8225b..HEAD` over `functions/`, both rules files and
`firestore.indexes.json` is empty, so there is no backend deploy debt. Read
`docs/DEPLOYMENT.md`'s log for what production runs — never this file.

- **Rollback direction has FLIPPED.** Roll back the APP, never the backend: the
  shipped build calls the server-side search callables, and its old client-side
  scan path is unreachable (`firebaseFunctionsProvider` is non-nullable).
- **Crashlytics re-check** on 1.61.0+90 is now possible (the 2026-09-07 audit
  carried it over waiting for a shipped build).
- **Distribution signing with the CarPlay entitlement is proven**: the key is in
  `ios/Runner/Runner.entitlements` at `dd8c4863`, and that build shipped (§4).

### 2. Siri — the one feature that has never been on a device at all

Phases 1–3 are code-complete and have **never been run on a device**; that pass
is the whole of what stands between them and done. `ios/SiriIntents/` holds
exactly the six read intents, verified 2026-09-09. It is also the single unticked
box in `APP_STORE_SUBMISSION.md` Part 6.

**Phase 4 (voice write actions) is specified end to end and nothing is landed.**
It needs one Mac session doing, in this order: the Apple-portal keychain-sharing
capability, a second Firebase app for the extension's App Attest, then the
entitlement XML — landing the XML first breaks signed builds with a provisioning
mismatch. Phases 5–6 are unscoped.

### 3. Wave — Phases 1–3 COMPLETE, Phase 4 BUILT (not deployed)

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

### 4. CarPlay — COMPILED, SIGNED and DRIVEN; behavioural checks left

Written 2026-09-04, UI design finalised 2026-09-09, built the same day, and
**merged to `dev`** (`78e72903`; `0e9cd905` is the original branch commit).
Nothing here touches `functions/`, the rules or the indexes.

**Three gates this section used to describe are CLOSED, all on 2026-09-10** —
see the status header of the plan itself, which is the authority:

- **The Swift compiled**, first time it met a compiler (Xcode 26.6), clean with
  no edits. `RunnerTests` runs green, so `CarPlayTemplateBuilderTests.swift`
  pins the template builder for real rather than on paper.
- **The signing gate is closed.** The capability is enabled on the App ID and
  `com.apple.developer.carplay-driving-task` now lives in
  `ios/Runner/Runner.entitlements`; `RunnerCarPlay.entitlements` was deleted
  with the gating scheme it existed for. **The order inverts under AUTOMATIC
  signing** — Xcode cannot request the entitlement in a profile until the key
  is already in the file, so this file's old "refresh profiles, then move the
  key" instruction was a manual-signing one and following it literally
  deadlocks.
- **The `CPTabBarTemplate` risk is gone.** It was the biggest unverified risk
  here; the tab bar installs as the root and the scene connects with
  `FlutterSceneDelegate` already owning a window scene, which was the plan's
  one genuine unknown. It has been driven in the CarPlay Simulator against
  production data.

**What is actually left is behavioural.** The four actions (Directions, Start,
Complete, Call) have never been exercised; the App Lock question is unanswered;
and **the technician view has never been on a screen at all** — every drive was
an admin snapshot, and decisions 22-23 changed that view structurally, so it is
the least-verified surface. **Distribution** signing, the last unknown here, is
settled: 1.61.0+90 shipped with the entitlement in `Runner.entitlements`.

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
  predated the first/last split. `restore-client-name-halves.js` repairs those
  from `clientName` on the client's SETTLED appointments and never touches
  `name`; `docs/audits/audit-renamed-client-names.js` is its read-only twin, and
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
