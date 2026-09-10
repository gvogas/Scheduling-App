# Archived docs

Completed plans/specs and superseded audit snapshots — kept for history, not
maintained against the current code. Started 2026-07-10; last updated
**2026-09-06**, when the docs sweep moved in fourteen documents whose work had
shipped (the simplified-auth pair, the four August calendar/day-off designs, the
per-day appointments pair, client-building grouping, the calendar holidays, the
superseded clients address filter, the feature-tour 1.57 pair and the 2026-09-03
mobile audit) and indexed eleven that were already on disk but unlisted —
companion `-design` / `-PLAN` / `-implementation` files whose sibling was
indexed and they were not. Before that, **2026-08-15**, when the sweep added the three audit snapshots this index
had been missing — the 2026-08-11 second pass (on disk but unlisted) and the two
2026-08-14 passes, which had been **overwritten in place** by the next sweep and
were restored from git history. The 2026-08-11 sweep before it moved thirteen
documents in: six plans whose work had shipped (the multi-day trio, the
closed-jobs agenda, the photo cue, the History restyle), six superseded audit
snapshots, and the pre-redesign `WORKFLOW.md`.

**Overwriting the rolling `docs/audits/CODEBASE_AUDIT.md` with the next sweep is
how a snapshot goes missing.** Copy the outgoing one here first.

**Do not treat these as accurate references.** For current state see
`docs/ARCHITECTURE.md`, `docs/CLOUD_FUNCTIONS.md`, and the active plans in
`docs/plans/`.

Documents here are frozen as written, so several still cite each other by their
old `docs/plans/` or `docs/audits/` paths. Those pointers are left alone on
purpose — a task list that says "edit `docs/plans/X`" was true when it ran, and
rewriting it would falsify the record. Read a bare filename as "same folder as
this one".

## Executed plans / specs (feature shipped)
- `INVITED_SIGNUP_REDESIGN.md` / `_PLAN.md` — canonical spec + implementation
  checklist for the one-time signup-code invite flow (shipped 1.19.4, then
  itself replaced by P4c's admin-invites flow 2026-08-02 and fully retired from
  the backend 2026-08-08 with the `#compat-1.37.1` shim). Both live here now;
  neither root `CLAUDE.md` nor `docs/CLOUD_FUNCTIONS.md` cites the spec any
  more — this is a plain historical record, not an authoritative reference. The
  checklist predates dropping `regenerateSignupCode`.
- `2026-06-06-error-animation.md` / `-design.md` — field-error shake/animation
  (shipped; now built into `LabeledTextField` / `AnimatedFormFieldWrapper`).
- `2026-07-01-ios-adaptive-feel.md` / `-design.md` — Cupertino-on-iOS adaptive
  layer (shipped; `lib/core/adaptive/`).
- `2026-07-08-admin-dashboard.md` — admin dashboard (shipped;
  `lib/features/dashboard/`).
- `2026-07-08-push-notifications.md` — FCM push triggers + iOS home-screen
  widget (implemented; `functions/notifications.js`,
  `lib/features/notifications/`, `lib/features/home_widget/`; functions + rules
  deployed to prod 2026-07-11). Residual ops items (Firestore ledger TTL policy,
  on-device verify) are tracked in CLAUDE.md, not here.
- `2026-07-11-wave-auto-import-schedule.md` / `-plan.md` — Wave auto-import
  cadence (deployed 2026-07-11; `functions/wave/import_schedule.js`,
  `waveScheduledImport` / `waveSetImportSchedule`). The design doc's "not yet
  implemented" status line was stale at archive time.
- `2026-07-13-offline-hardening.md` — offline guards + durable photo-upload
  retry queue (Tasks 1–6 implemented/committed on `notification`).
- `2026-07-13-day-route-view.md` — employee day-route timeline + multi-stop
  Google Maps hand-off (Tasks 1–5 implemented on `notification`;
  `lib/features/calendar/screens/day_route_screen.dart`). Task 6 is a
  device-only verification pass.
- `2026-07-09-travel-time-notifications.md` — travel-aware "time to leave"
  reminders with live background GPS presence (implemented + committed on
  `notification`, shipped in 1.31.0+50; `functions/travel_utils.js`,
  `lib/features/presence/`). Residual ops items (Routes API console enable +
  functions deploy + Mac Time-Sensitive entitlement) are tracked in CLAUDE.md,
  not here.
- `2026-07-15-live-staff-map.md` — admin-only Find-My-style live staff map
  (implemented + committed on `notification`, shipped in 1.32.0+51;
  `lib/features/presence/screens/live_map_screen.dart`, `LiveMapAggregator`,
  `placesReverseGeocode`; **functions + rules deployed to prod 2026-07-18**,
  client Maps keys + Geocoding API provisioned). Residual items (verify Routes
  API is enabled/restricted, on-device pass, App Store Location privacy
  declaration) are tracked in CLAUDE.md and the iOS handoff, not here. The
  plan's own header status line was stale (pre-deploy) at archive time.
- `2026-07-19-ios-live-activities.md` / `-implementation.md` — the iOS Live
  Activity "time to leave" Lock Screen card (built 2026-07-19; **functions,
  rules, and the two required composite indexes deployed to prod 2026-07-19**
  in 1.34.1). `functions/apns_client.js`, `live_activity_*.js`,
  `lib/features/live_activity/`, `ios/ScheduleWidget/JobLiveActivity.swift`.
  **Both header status lines were stale at archive time** — the design doc still
  said "NOT started, NOT approved to build" and the implementation doc still
  called the APNs secrets a deploy blocker; the secrets were created 2026-07-19
  and the deploy has happened. Residual item (on-device verification) is tracked
  in CLAUDE.md and `ios/ScheduleWidget/LIVE_ACTIVITY_README.md`, not here.
- `2026-07-22-feature-tour-design.md` / `-implementation.md` — per-tab,
  role-aware in-app feature tours (showcaseview 5.x; built + committed on
  `notification`, "live tour of app"). `lib/features/feature_tour/`; CLAUDE.md
  carries the full invariant. On-device verification is the one residual item.

- `2026-08-03-client-archive-and-delete.md` / `-plan.md` — archive-instead-of-
  delete for clients, plus the `deleteClient` callable gated on a live `count()`
  of the client's appointments (built + committed on `redesgin`; **functions,
  rules and the `(archived, name, __name__)` index deployed 2026-08-03**, with
  the required prod backfill run first — 674 clients patched). The design doc's
  own "approved, not implemented" status line was stale at archive time and was
  corrected. `allow delete` on `/clients` was withdrawn 2026-08-08 with the
  `#compat-1.37.1` shim, so `deleteClient` is now the only delete path in rules
  as well as in code.
- `2026-08-04-drawer-icons-and-tour-expansion.md` / `-PLAN.md` — tinted icon
  chips on the nav drawer rows, and the feature tour regrown from 14 screen-level
  steps to 43, including the three create-flow **sheet** tours that the sealed
  `TourScope` split made expressible (pushed, `059a2cf9`..`07131173`).
  `lib/features/feature_tour/domain/tour_scope.dart`. On-device verification is
  the one residual item.

- `2026-08-02-multi-day-appointments.md` (design) / `-PLAN-1-app.md` /
  `2026-08-03-multi-day-appointments-PLAN-2-mirrors.md` — an appointment spans
  up to 14 days and its two times are a **daily window**. Plan 1 built the app
  half (`e0518c9`, 2026-08-03): `AppointmentDaySlice` as the one owner of
  day-scoping, and every consumer of the range stream re-scoped through
  `runsOn`. Plan 2 built the off-screen mirrors (2026-08-10): the home widget,
  `functions/day_slice_utils.js`, the Siri snapshot at **schema v3** and the
  push date line, so days 2+ of a run stopped being invisible outside the app.
  The design doc's §8 mirror table is complete and its §10 question 2 (a
  `firestore.rules` span bound) was **closed and built 2026-08-11**
  (`isValidAppointmentSpan`). **One open item was carried out of §10 rather than
  archived with it** — what a Live Activity for a multi-day job should look like
  — and now lives in `docs/plans/README.md` §5; the containment (skip multi-day
  jobs outright) is built. The rules bound and the skip are **not deployed**.
  Both Swift halves are Xcode/device-unverified. Every invariant is in
  `CLAUDE.md`; the unticked checkboxes in both plans are an artifact of how they
  were executed.
- `2026-08-08-completed-jobs-agenda.md` — closed jobs (`done` **and**
  `cancelled`) sink below the day's open work in the calendar agenda, take the
  success tint, and render collapsed under a labelled rule (built 2026-08-08).
  `_agendaOrder` in `appointment_day_slice.dart`, `AgendaSliverList`,
  `AppointmentCard(collapseWhenClosed:)`. Only the calendar sinks them — every
  other appointment surface keeps its own sort and the full-height card.
- `2026-08-10-photo-cue-and-day-count.md` — two small agenda signals (built
  2026-08-10): a photo glyph at the end of the title line when a job carries
  pictures, and the agenda header's `4 JOBS · 1 DONE` second clause. Not
  device-verified.
- `2026-08-11-history-restyle.md` — P7's History half (built 2026-08-11): a left
  date rail under a sticky month bar, replacing the bold year separator, with
  the shared `AppointmentCard` untouched. `HistoryMonthBar`, `HistoryDateRail`,
  `clients/domain/history_grouping.dart`. Its build record is P7 phase D in
  `docs/plans/redesign-subdocs/2026-08-11-p7-dashboard-history.md`, which stays
  active-adjacent with the rest of the redesign sub-docs.

### Added by the 2026-09-09 sweep

- `2026-07-29-redesign-program.md` and `redesign-subdocs/` (15 files) — the
  navigation redesign program spec and the per-project build record for P1
  through P7, moved together so every relative link between them still resolves.
  **The program is COMPLETE and owes nothing:** P1-P5 and P7 shipped, P4b was
  withdrawn and replaced by P4c, and **P6 Time off and P7b Wave invoices were
  CANCELLED by owner call 2026-09-06** — which makes two consequences permanent
  rather than deferred, both documented at their sites: the dashboard's **Year**
  period and its six money sections stay absent (don't "add Year back" by
  widening `fetchInRange`), and a personal block / day off IS the time-off
  answer, because `findBusyEmployees` deliberately does not filter it. The
  folder's last live item was the device runbook
  (`2026-07-30-p1-p2-DEVICE-TEST.md`), closed 2026-09-09 when the P5 block's 18
  checks passed as a technician and the unrunbooked surfaces were swept — all
  owner-reported, no console capture, so read a later contradiction as "re-run
  that check" rather than a regression. Four files outside the folder were
  repointed at these paths: `docs/CLOUD_FUNCTIONS.md`,
  `.claude/rules/employees.md`, `.claude/rules/appointments.md`, `ios/CLAUDE.md`.
- `2026-09-09-plans-index-retired-sections.md` — the sections trimmed out of
  `docs/plans/README.md` the same day, verbatim, when that index was cut down to
  live work only: the redesign roll-up, device verification, the parked
  multi-day Live Activity design question, the App Store history, and the
  function-SDK-downgrade lesson (**the jest suite mocks firebase-admin, so it
  passed on the broken versions too** — check installed versions directly after
  any dependency change there).

### Added by the 2026-09-09 sweep

All six shipped **and** deployed; the deploy gate each banner still cited was
closed by the 2026-09-06/09-07 backend deploys (25 -> 29 functions, all 19
composites `READY`, both prod backfills run, the crew-notes rules grant live).

- `2026-09-04-clients-page-search-first.md` / `-implementation.md` — the clients
  tab's five-control chip row replaced by one search field, a pinned Filter
  button and a filter sheet, plus a sort control, and the ~700-doc building scan
  taken off the tab open. Implemented 2026-09-05 (`767ec99e` + `b2adc705`),
  released 1.58.0+87; its two `clients` composites reached `READY` and
  `backfill-client-sort-fields.js` ran live 2026-09-06 (720 scanned / 658
  patched). Supersedes `2026-08-29-clients-address-filter.md`.
- `2026-09-05-add-job-client-picker.md` / `-implementation.md` — the phone-first
  add-job client picker, built for an admin typing a full ten-digit number while
  on the call: `PhoneQueryPolicy`, `ClientSearchWindow`, `ClientPicker` and
  `SelectedClientCard`. Built and released the same day as 1.58.0+87
  (`101d0c0a`), boxes ticked in `394d67af`; the `searchClients` callable it
  depends on went live 2026-09-06.
- `2026-09-06-crew-record-and-role-gates.md` / `-implementation.md` — eight
  changes to the appointment flow, the employee interface and the crew field
  record: Recent removed from the add sheet, the job address following the
  toggle, a back control on the filter sheet, the Day Route selector and History
  gated on the LIVE Firestore role (`isActiveAdminProvider`), employee photos
  staying visible, the attached client-search dropdown, and author-stamped crew
  notes in the new `appointments/{id}/fieldNotes` subcollection. Built
  2026-09-06/07 across thirteen commits (`b3ca82a2`..`051a6b6d`); its rules
  grant deployed 2026-09-07 (`462a1907`), without which the notes were inert in
  prod.

### Added by the 2026-09-06 sweep

- `2026-08-21-simplified-auth-design.md` / `-implementation.md` — removed the
  email-verification step from employee setup and the admin toggle from account
  creation, replacing the shared `Welcome123!` with a random per-account
  starting password. Shipped 1.48.0+77, backend deployed 2026-08-21
  (`1c89892a`, then `229b6e24` restoring account creation the first deploy
  broke). Backend rollback is unsafe — the dependent build is on the App Store.
- `2026-08-24-assignee-availability.md` — the assignee picker dims crew who
  can't take the job on the chosen date rather than hiding them. Built
  2026-08-24, shipped 1.51.0+80. Shares `findClashingAppointments` with the
  sibling below; the invariants live in `.claude/rules/appointments.md`.
- `2026-08-24-timeoff-clash-alert.md` — the same clash from the other
  direction: booking a personal block over existing jobs lists them and offers
  to swap the crew. Built with its sibling in one pass, shipped 1.51.0+80.
  `personal_block_clash_dialog.dart`.
- `2026-08-24-day-off-card.md` — the day-off strip's appearance (option B, "day
  banner", no side colour). Shipped 1.50.0+79; `_DayOffStrip` in
  `appointment_card.dart`. Its banner said "uncommitted" until this sweep.
- `2026-08-25-day-off-strip-title.md` — the strip renders a typed title instead
  of throwing it away, plus the light-mode container fix. Shipped 1.52.0+81.
- `2026-08-27-per-day-appointments.md` / `-plan.md` — a multi-day job books as
  one document per day, linked by `seriesId` with a stored `dayIndex`/`dayCount`,
  so marking day 1 complete no longer closes days 2–5. Implemented 2026-08-27,
  shipped 1.53.0+82, rules deployed 2026-08-29 (`77c6a66f`).
- `2026-08-28-client-building-grouping.md` — grouping clients by building, made
  the case by the address backfill's prod dry run (32 clients across 7 Prom.
  Paton buildings). Shipped; `client_building.dart` and the filter sheet. Its
  dependency, `2026-08-28-address-street-locality-split.md`, is **still in
  `docs/plans/`** — that doc's live prod backfill has never been run — so the
  bare-filename link in here does not resolve inside this folder.
- `2026-08-29-calendar-holidays.md` — display-only Québec statutory, Greek
  Orthodox and CCQ construction holiday markers, computed in Dart with no I/O.
  Built 2026-08-29, shipped 1.54.0+83; `calendar/domain/holidays.dart`.
- `2026-08-29-clients-address-filter.md` — the clients address chip menu.
  **Superseded 2026-09-04** by the search-first direction, which deleted
  `client_address_filter_menu.dart` outright and moved shared addresses into a
  filter sheet. Archived as the record of what shipped in between.
- `2026-09-04-feature-tour-1-57-update.md` / `-implementation.md` — eight new
  tour steps for the 1.56/1.57 features and the move from per-screen to
  per-STEP seen flags (`tour_seen_steps`, seeded once from `tour_seen_tabs`).
  Implemented 2026-09-05, shipped 1.58.0+87; app-side only, nothing to deploy.
  The tour now runs 52 steps across 12 scopes.

### Indexed by the 2026-09-06 sweep (already on disk, never listed)

These were moved in by earlier sweeps alongside a sibling that got the index
row; each is the companion design or task-list half of a document listed above.

- `INVITED_SIGNUP_REDESIGN_PLAN.md` — the implementation checklist half.
- `2026-06-06-error-animation-design.md` — the design half.
- `2026-07-01-ios-adaptive-feel-design.md` — the design half.
- `2026-07-11-wave-auto-import-schedule-plan.md` — the task-list half.
- `2026-07-19-ios-live-activities-implementation.md` — the implementation half.
- `2026-07-22-feature-tour-implementation.md` — the 67k task list behind the
  original showcaseview tour.
- `2026-08-02-multi-day-appointments-PLAN-1-app.md` — Plan 1 (app) of the
  multi-day trio; Plan 2 (mirrors) was already indexed.
- `2026-08-03-client-archive-and-delete-plan.md` — the task-list half.
- `2026-08-04-drawer-icons-and-tour-expansion-PLAN.md` — the task-list half.
- `CLOUD_FUNCTIONS_refresh_history.md` — six "Previously refreshed" entries
  (2026-08-19 → 2026-08-29) trimmed out of `docs/CLOUD_FUNCTIONS.md`'s header on
  2026-09-06, where the stack had reached nine.

## Superseded session snapshots
- `2026-07-20-session-handoff.md` — a point-in-time "resume here" snapshot; its
  live next-action (the Siri Phase 4 write-actions runbook) lives in the active
  `docs/plans/2026-07-20-siri-phase4-write-actions.md`. Kept for history only.
- `WORKFLOW.md` — the user-side UI map of the **pre-redesign** app (~2026-07-29),
  written as the brief the redesign was specified against. Archived 2026-08-11
  now that P1–P5 and P7 have shipped: the nav rail, `table_calendar`,
  `AppointmentTile`, `AuthBrandHeader`, `google_fonts`, the `todayFab` and the
  signup-code flow are all deleted, there are four hub tabs rather than six, and
  it predates personal jobs, all-day blocks and multi-day appointments. It had
  carried a SUPERSEDED banner since the redesign began and was flagged by the
  2026-08-04 audit for presenting itself as current. Kept for its §6 constraints
  and as the record of what the redesign was answering. Current sources of
  truth: `CLAUDE.md`, `docs/ARCHITECTURE.md`.

## Superseded audit snapshots
Point-in-time whole-repo audits; each run's findings were implemented at the
time. Superseded by later audits. The active
`docs/audits/CODEBASE_AUDIT.md` file is now a cleaned current action list, not a
full historical snapshot. `docs/audits/` also keeps
`SECURITY_ASSESSMENT_2026-08-04.md` and `AUDIT_FOLLOWUPS.md` (the owner-only
Maps budget cap), plus two read-only repair-audit scripts for the client-rename
damage (`audit-renamed-client-names.js` and the earlier
`audit-client-phone-backfill-damage.js`).
- `CODEBASE_AUDIT_2026-09-03-rolling.md` — the outgoing rolling file, copied
  here 2026-09-05 before the 2026-09-05 audit overwrote it. Its still-open
  items (the Maps billing cap, the Crashlytics re-check needing a shipped
  build, the Wave "Retry failed" press, the Xcode `InfoPlist.strings`
  confirmation) are NOT repeated in the current rolling file and are still open.
- `MOBILE_APP_AUDIT_2026-09-03.md` — a mobile-focused pass over the Flutter app,
  rules, functions, iOS platform code and dependencies. All findings were
  implemented on 2026-09-03/09-04; it also records the `firebase-admin`
  13.10.0 → 14.3.0 upgrade. Moved here 2026-09-06, superseded by the rolling
  audit.
- `CODEBASE_AUDIT_2026-06-26.md`
- `CODEBASE_AUDIT_2026-07-01.md`
- `CODEBASE_AUDIT_2026-07-04.md`
- `CODEBASE_AUDIT_2026-07-07.md`
- `CODEBASE_AUDIT_2026-07-19.md` — the same-day deep pass that replaced the
  `-earlier` run below.
- `CODEBASE_AUDIT_2026-08-02-pre-p4c.md` — the 1.39.0+64 release cut, audited
  *before* the P4c employee-account commits landed.
- `CODEBASE_AUDIT_2026-08-02-post-p4c.md` — the re-run over the P4c result.
  Supersedes the pre-P4c snapshot.
- `CODEBASE_AUDIT_2026-08-04-first-pass.md` — closed 21 findings at `7166d03`.
- `CODEBASE_AUDIT_2026-08-04-second-pass.md` — a fresh sweep over the shipped
  result at `a8cf8d3`, not a re-run of the first pass's checks; it found a
  distinct set.
- `CODEBASE_AUDIT_2026-08-11-first-pass.md` — 20 findings at `102a6b21`, all
  actioned in `96a514a2`. Superseded the same day by the second pass below.
- `CODEBASE_AUDIT_2026-08-11-second-pass.md` — 31 findings at `4ec9ad8a`, closed
  in `d0f99f23` + `45302651`. It caught the rules span bound that DST would have
  made reject legal saves, before that bound deployed.
- `CODEBASE_AUDIT_2026-08-14-first-pass.md` — 30 findings at `0edf80b7`,
  implemented the same day in `2ca8013b`; it found the edit sheet renaming real
  Wave customers. Its ⚠️ pre-deploy item (deleting three live Cloud Functions)
  ran in the 2026-08-14 deploy.
- `CODEBASE_AUDIT_2026-08-14-pre-deploy.md` — a fresh sweep run immediately
  before that deploy and before the Wave client-name/phone backfills, weighted
  toward what breaks once deployed. 27 findings, all closed at `10545972`.
  **Both 2026-08-14 snapshots were restored from git history on 2026-08-15** —
  each had been overwritten in place by the sweep that followed it.
- `CODEBASE_AUDIT_2026-08-19.md` — the follow-up audit after the appointment
  image migration and Wave fixes; its active items were carried into later
  deploy logs and audits.
- `CODEBASE_AUDIT_2026-08-28-second-pass.md` — the late-August sweep; all
  reported findings were closed, with the index lesson later corrected in the
  2026-09-01 deploy log.
- `CODEBASE_AUDIT_2026-09-01.md` — the full audit snapshot that produced the
  current rolling action list. Most findings were closed in-tree; the remaining
  owner-only, product and refactor work is tracked in
  `docs/audits/CODEBASE_AUDIT.md`.
- `MOBILE_AUDIT_2026-07-13.md` — a mobile-optimization-lens pass (perf, memory,
  battery, network, mobile UX) rather than a general audit. Nothing mechanical
  to fix; its verdict was that the hot paths already implement the mitigations
  it hunts for.
- `CODEBASE_AUDIT_2026-07-19-earlier.md` — the first 2026-07-19 run, which
  reported zero security findings and zero bugs. The **same-day deep pass that
  replaced it contradicts that conclusion** (it found the disabled-employee read
  hole and the two missing indexes), so this snapshot is kept only as a record
  of what a shallower pass missed. Its auto-applied spacing/token cleanups
  remain valid.
- `WAVE_REVIEW_FINDINGS.md` — Wave-integration ultra review (fixes applied
  2026-06-21; Wave shipped).
