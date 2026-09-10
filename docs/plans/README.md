# Active plans — index and outstanding work

Swept 2026-08-11, re-swept 2026-08-15 and 2026-09-06, **re-swept 2026-09-09**
against what the code, `git log` and the deploy log actually say. The 2026-09-06
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
| `2026-09-07-analytics-followups.md` | **Code COMPLETE and verified** (analyzer clean, 3547 tests). Every open item is off-repo: Google Analytics must be ENABLED on the project or the SDK reports nothing silently; custom dimensions must be registered or `user_role` and `source` are uncollectable in reports; App Store Connect privacy labels and the `FIREBASE_ANALYTICS_WITHOUT_ADID=true` release build are submission-gating. |
| `2026-07-10-siri-app-intents-design.md` | Design, 6 phases. Phases 5–6 unscoped. |
| `2026-07-19-siri-app-intents-implementation.md` | Phases 1–3 built; **no device pass ever run — and this is now the ONLY device-gated item left in the repo** (the 2026-09-09 sweep closed every other one). Six read intents in `ios/SiriIntents/`, never exercised by voice. |
| `2026-07-20-siri-phase4-write-actions.md` | **NOT STARTED.** Mac + Apple-portal session. |
| `2026-08-28-address-street-locality-split.md` | **COMPLETE 2026-09-09 — nothing outstanding.** The prod dry run came back **724 scanned, 0 reduced**, so the live run is withdrawn rather than pending; the 2026-08-28 count of 114 was inflated by the pre-guard re-spacing bug. Don't run it. |
| `2026-08-30-wave-validated-contract-design.md` | **Phase 1 COMPLETE** — built and deployed 2026-08-30 (`fe9edc51`, report-only), and the prod replay **ran 2026-09-09: 724 clients, 0 blocking, 1 advisory.** The report is clean, so **Phase 2 (enforce) is unblocked** — read §3 before writing it. |
| `2026-08-30-wave-validated-contract-implementation.md` | Phase 1's task list — every step now done, the replay included. |
| `2026-09-04-carplay-driving-task.md` | **PLAN, NOT STARTED.** Written 2026-09-04; **UI design finalised 2026-09-09** (Today / Week tab bar, Today ranked Now / Next / Later, mark-complete hand-off alert, refresh on every connect, business-wide admin view — decisions 9–16). Verified 2026-09-09 that no `CarPlay` symbol or entitlement exists anywhere. |
| `APP_STORE_SUBMISSION.md` | **The live release runbook**, now for updates rather than a launch — the app shipped. Its unticked boxes have never been reconciled against four shipped submissions, so read one as *unknown*, not *outstanding*. |

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

### 1. The app build — the only release item left

The three-release backend debt (1.56/1.57/1.58) is **PAID**: indexes deployed and
all 19 `READY`, both prod backfills run, `functions` + `firestore:rules` live at
**29 exports** (2026-09-06), and the crew-notes `fieldNotes` rules grant deployed
2026-09-07 (`462a1907`). Read `docs/DEPLOYMENT.md`'s log for what production
runs — never this file.

What is left:

- **Cut the build.** `462a1907` sits ~22 commits above the 1.58.0+87 release
  commit with no `CHANGELOG.md` entry, so it needs a version bump first.
  Everything shipped since — the crew record, the role gates, the analytics —
  reaches users only through it. `/release` owns the sequence.
- **Re-run `backfill-search-tokens.js` immediately before it ships.** It is
  idempotent, and currently-shipped builds write no `searchTokens`, so any client
  edited from a phone since 2026-09-06 has stale tokens and is invisible to the
  search that replaced the client-side scan.
- **Rollback direction flips when it ships.** The backend was safe to roll back
  only until then; afterwards roll back the APP, never the backend, because the
  old client-side scan path is unreachable in a shipped build
  (`firebaseFunctionsProvider` is non-nullable).

### 2. Siri — the one device-gated item in the repo

Phases 1–3 are code-complete and have **never been run on a device**; that pass
is the whole of what stands between them and done. `ios/SiriIntents/` holds
exactly the six read intents, verified 2026-09-09. It is also the single unticked
box in `APP_STORE_SUBMISSION.md` Part 6.

**Phase 4 (voice write actions) is specified end to end and nothing is landed.**
It needs one Mac session doing, in this order: the Apple-portal keychain-sharing
capability, a second Firebase app for the extension's App Attest, then the
entitlement XML — landing the XML first breaks signed builds with a provisioning
mismatch. Phases 5–6 are unscoped.

### 3. Wave — Phases 2–4, unblocked but deliberately unwritten

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

### 4. CarPlay — awaiting the build decision

Written 2026-09-04 with its UI design finalised 2026-09-09; nothing is built
(verified: no `CarPlay`/`CPTemplate` symbol or entitlement anywhere).

### 5. Analytics — every open item is off-repo

Code is complete and verified. What is left is a Firebase Console setting, an App
Store Connect action or a device pass — and three of them gate something real:
**Google Analytics must be ENABLED on the project** or the SDK reports nothing,
silently; **custom dimensions must be registered** or `user_role` and `source`
are uncollectable in reports; and the ASC privacy labels plus the
`FIREBASE_ANALYTICS_WITHOUT_ADID=true` release build are submission-gating.

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

**Nothing here is outstanding.** The list exists so nobody runs one again.

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
- **Run: `backfill-search-tokens.js`** (2026-09-06, 720 clients / 84
  appointments) — **re-run once more before the app build ships**, see §1.
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

### 8. One parked design question — Live Activities on a multi-day job

A card counting down to an end four days out would sit on the Lock Screen for the
whole job, so `resolveReminderForAssignee` **skips multi-day jobs outright**
(`dayCountOf(c) > 1`, built 2026-08-11); the `leaveNow` push still goes out on
day 1, the only day with a departure time. **That skip is the containment, not
the answer** — what a multi-day card should actually be (a per-day card? a
countdown to today's window end?) is unanswered. Carried forward from the
archived multi-day design doc so it is not lost with it.
