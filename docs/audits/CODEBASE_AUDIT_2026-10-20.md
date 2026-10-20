# Codebase Audit — 2026-10-20

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`firestore.indexes.json`, `.github/workflows/`, `ios/` Swift, `test/`).
Baseline: `dev` @ `a8072b6`, clean tree. Emphasis on the 7 commits since the
2026-10-19 audit (`33cde361..a8072b6`): 145 source files, +13.8k/−3.4k
including tests (the 10-19 implementation, release 1.65.0+97, the 10-20 UX and
performance review and its implementation, the range tail query + `isPersonal`
equality).

## Summary

- Scanned: 499 Dart files in `lib/` (75,490 lines), 425 test files,
  `functions/` (114 jest suites + 3 emulator scripts), both rules files, the
  index file, both workflows, the two changed Swift files.
- Auto-fixed (safe, in the diff): 2 edits across 4 files — one dead state
  field (with its freezed regen and two test assertions) and one stale doc
  mention. Nothing else was auto-applied: the static layer was already clean
  (`flutter analyze` No issues found!, `dart fix` Nothing to fix!, functions
  lint clean, `tool/check_rules.dart` 0 violations, no BOM, no orphaned ARB
  key, no unused dependency, no zero-import file).
- Reported for your decision: 20 (⚠️ 0 pre-ship · 🔴 0 security · 🟠 3 bugs ·
  🔵 13 improvements · 🟡 4 code-quality).
- Verification (after the fixes): `flutter analyze` **No issues found!** ·
  `dart run tool/test.dart` **4398 passed** (baseline 4398; final run recorded
  below) · functions lint clean · jest **2353/2353** (114 suites) ·
  `tool/check_rules.dart` 0 violations.

## Decide first

1. **B1 (high):** turning location sharing ON reverts itself while the iOS
   prompt is open. Two fixes are possible: decide the permission before
   writing the flag (recommended, smallest), or make `runCoalesced` return a
   future that completes after the queued rerun. The first changes the order
   of the one iOS prompt relative to the Firestore write; the second changes
   a shared primitive used by three controllers.
2. **B2 / I1:** gate `_watchRange`'s first emission on both snapshots. The
   rule in `appointments.md` says "emits on either" — the fix keeps that for
   every later emission but adds a both-landed gate for the first. Confirm
   you want that wording amended (one clause).
3. **I2:** the rules do not type-bound `isPersonal`, and two production
   queries now key on it. Adding `isPersonal is bool` when present to
   `isValidAppointmentData` is a rules deploy; confirm before it rides with
   the next backend deploy.
4. **Q1:** 225 multi-line `//` comment blocks vs the one-line rule in
   `code-quality.md`. Either a deliberate sweep (rationale → rules/ADR, one
   clause stays) or relax the rule text. Not something an implement pass
   should decide.

Everything else is local and test-backed, so "do all" can cover it. I2 (rules)
and S-obs-1 (functions) take effect only with the next backend deploy. There
is nothing that needs a prod backfill.

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `lib/features/calendar/application/event_details_controller.dart:55,264` | removed `EventDetailsState.endDateTouched` (`@Default(true)`, set in `selectEndDate`, never read) | dead state: the only reader is `AddEventController` (`add_event_controller.dart:165`), a different state class |
| `lib/features/calendar/application/event_details_controller.freezed.dart` | regenerated (`dart run build_runner build`) | follows the field removal; the other 11 freezed outputs were no-ops |
| `test/features/calendar/event_details_controller_test.dart:418,452` | dropped the two `endDateTouched` assertions; renamed the `selectEndDate` test | they pinned the removed field |
| `docs/ARCHITECTURE.md:1011-1012` | dropped `EntityFormHeader` from the "shared rows" list | `frontend.md` (ADR-0126) says it is deleted and "a mention is a doc to fix"; line 1078 of the same doc already says so |

> Full detail is in `git diff`. Nothing below this line was auto-changed.

Two candidates were tried and reverted or declined:
- `_ClashLine`'s `struckThrough` parameter (`personal_block_clash_dialog.dart:594`)
  was reported as "always `true`"; it is passed `true` at 2 of 4 `_line` call
  sites (`_RowDone`/`_RowStuck` rely on the `false` default), so removing it
  would strike through finished rows. Reverted; not a finding.
- `location_sharing_view.dart:160-168` → `destructiveOutlinedButtonStyle`:
  the hand-rolled style also sets an `r12` shape the shared style lacks, so
  the swap is a visual change. Reported as Q3.

## ⚠️ Pre-ship checklist

No `TODO(pre-ship)`/TODO/FIXME/HACK/XXX markers in `lib/` or `functions/`.
Nothing to act on before release beyond the documented deploy order for the
`isPersonal` backfill (`docs/DEPLOYMENT.md` §4d: indexes READY → backfill →
app build), which is already recorded and is not a finding.

## 🔴 Security findings

None at the bar. Every candidate traced to an existing guard, rule clause or
documented carve-out. Coverage is listed under "Checked and sound". Three
below-the-bar observations:

- **S-obs-1** `functions/appointment_edit_policy.js:118-122` · low · med —
  `validateEditedAppointment` validates the MERGED record against the
  four-value allowlist, so an admin editing a doc whose stored status is a
  legacy `completed`/`confirmed` WITHOUT touching status gets
  `invalid-appointment-status` and cannot save. Fail-closed and admin-only, so
  not a security finding; it is a functional gap, filed as **B3**.
- **S-obs-2** `.github/workflows/ci.yml:116` · informational — the CI
  `functions` job runs `npm ci` with lifecycle scripts; the deploy job uses
  `--ignore-scripts`. The CI job holds only a read-only `GITHUB_TOKEN` and no
  GCP credential. Optional hardening: add `--ignore-scripts` there too.
- **S-obs-3** `lib/routes/app_routes.dart:56` · informational — the
  `forgotPassword` arm reads `settings.arguments as ForgotPasswordArgs?`
  rather than `_args<T>` (ADR-0017). Arguments are in-process objects, not
  deep-link controllable, so robustness only. Filed as **Q4**.

## 🟠 Bug findings (review required)

### B1 — turning location sharing ON reverts itself while the iOS prompt is open · high · confidence high
- **Where:** `lib/features/presence/application/presence_sync_controller.dart:90-112`
  (`applyLocationSharing`), with `lib/core/app/app_sync_listeners.dart:96-105`
  (`_presenceSync`) and `lib/core/utils/reentrant_sync.dart:32-50`
  (`runCoalesced`). New in `e5587f5`.
- **Problem:** `updateSelfDetails` is a plain `update()`, which resolves only
  on server ack, but `currentUserDocProvider` (plain `snapshots()`) emits the
  latency-compensated local write immediately. `AppSyncListeners._presenceSync`
  fires `presence.sync()` on that emission; its `_syncGuarded` run reaches
  `await ensureLocation()` (`:280-283`) and blocks on the OS prompt. One RTT
  later `applyLocationSharing` resumes, calls `presence.sync()` — which hits
  `runCoalesced` with `_activeRun != null`, sets `_syncPending` and **returns
  at once** — then reads `permissions.currentStatus()`. Geolocator maps
  `notDetermined` to `denied` while the prompt is up, so the flag is written
  back to `false`, `unregister()` → `invalidateSync()` abandons the prompting
  run, and the user sees "permission refused". Tapping Allow afterwards
  leaves sharing off. This is the first-run path for every new employee
  (`ShareLocationAskScreen._turnOn`) and the Settings switch; a second tap
  works, which is why it has not been noticed.
- **Test gap:** `test/features/presence/apply_location_sharing_test.dart:50`
  stubs `presence.sync` as instantly resolving, so coalescing never runs.
- **Fix:** decide before writing — `final permission = await
  permissions.ensureLocation();` first (it awaits the prompt), write the flag
  only when granted, then `sync()`. Add a test where `sync` is already in
  flight when `applyLocationSharing` calls it (a `Completer`-backed stub) and
  assert the flag is not reverted. Alternative: make `runCoalesced` return a
  future that completes after the queued rerun — touches a primitive shared
  by three controllers, so prefer the first.

### B2 — range streams emit a partial window on every cold subscription · medium · confidence high
- **Where:** `lib/features/calendar/data/firebase_appointments_repository.dart:659-690`
  (`_watchRange`). New in `a8072b6`.
- **Problem:** each of the two `snapshots().listen` callbacks does
  `controller.add(...)` with no "both initial snapshots present" gate. The
  tail query (`isPersonal == true`, 14-day lookback) is small and usually
  answers first, so the first emission is "personal blocks only" (typically
  `[]`). `MainCalendarScreen._prepareBuild` treats any delivered value as
  settled (`delivered != null`), so a month swipe past the 3-minute grace can
  paint a dotless grid / "0 JOBS" for a frame before the main snapshot;
  `widgetPayloadProvider` and the Siri snapshot write the partial payload then
  the full one (two App Group writes, two WidgetKit reloads — the
  `stillHolds` dedup cannot help because the two payloads genuinely differ);
  `_refreshDayIndex` and `dashboardStatsProvider` reduce twice. Before
  `a8072b6` one query meant one complete first emission. Reported
  independently by the bug and performance reviewers.
- **Fix (2 lines):** in the listen callback, after `_applyRangeChanges`,
  `if (latest.contains(null)) return;` before `controller.add` — both initial
  snapshots then produce one emission; later emissions are unchanged. Keep
  `onError` as is (a denied listener must still surface for `retryStream`).
  Pin it in `firebase_appointments_repository_range_stream_test.dart`: two
  fake query streams, assert one emission after both land, and amend the
  `appointments.md` clause ("emitting on either" → "after both have landed,
  then on either").

### B3 — `saveAppointmentEdits` refuses an untouched legacy status · low · confidence medium
- **Where:** `functions/appointment_edit_policy.js:118-122`
  (`validateEditedAppointment`).
- **Problem:** the merged `next` record is validated against the four-value
  allowlist. A doc still carrying `completed`/`confirmed` (legacy-tolerant on
  READ per `appointments.md`) whose edit leaves status alone yields no
  `status` patch, so `next.status` stays legacy and the callable throws
  `invalid-appointment-status`. The admin must change the status before any
  other edit lands. `firestore.rules`' `appointmentClosedStatusPreserved`
  tolerates exactly this case for direct writes, so the callable is stricter
  than the rules.
- **Fix:** validate `patch.status` when present, else accept an unchanged
  stored status; one jest case in `appointment_edits.test.js` with a stored
  `completed` and a title-only edit. Functions-only; needs the next backend
  deploy.

## 🔵 Areas to improve (review required)

### I1 — the two-listener range stream has no "both landed" test · medium · confidence high
- **Where:** `test/features/calendar/data/firebase_appointments_repository_range_stream_test.dart`.
- **Opportunity:** the suite pins the query shapes (main starts at the window,
  tail 14 days back, employee scoping, cap-warn) but not the merge timing —
  the gap B2 lives in.
- **Suggested improvement:** lands with B2 (above).

### I2 — `isPersonal` is a query key with no rules type bound · medium · confidence high
- **Where:** `firestore.rules` `isValidAppointmentData` (0 hits for
  `isPersonal`); `firebase_appointments_repository.dart:720,740`.
- **Opportunity:** `a8072b6` made `isPersonal` an equality in both the overdue
  query (`== false`) and the tail query (`== true`). A client write of
  `isPersonal: "yes"` (or any non-bool) drops the doc out of both — the same
  class as the ADR-0189 "doc with no field" caveat, but client-reachable.
  `AppointmentRecord.fromMap` reads `== true`, so the app would also render
  it as a client job.
- **Suggested improvement:** one line in `isValidAppointmentData`
  (`!('isPersonal' in d) || d.isPersonal is bool`) with a `#compat` note, plus
  an emulator assert in `safety_checks.js`. Rules deploy.

### I3 — the three assignee `allow update` disjuncts and `fieldNotes` create have no emulator coverage · medium · confidence high
- **Where:** `functions/__tests__/emulator/{appointment_edits_checks,safety_checks}.js`
  (0 hits for `done`/`in_progress`/`fieldNotes`).
- **Opportunity:** `appointment_edits_checks.js` covers the admin branch well
  (`editProtocol`, `sessionEpoch`, `editRevision`, legacy transitions) but the
  mark-done, photo-touch (`hasOnly(['updatedAt'])`) and Start-job disjuncts
  and the `fieldNotes` create (`authorId == myDocId()`, 4000-char cap) are
  pinned only by the source-reading Dart tests
  (`appointment_employee_update_rules_test.dart`), which cannot catch a
  semantic regression.
- **Suggested improvement:** ~6 asserts in `safety_checks.js`: assignee
  `pending`→`done` and `pending`→`in_progress` allowed, `cancelled`→`done`
  refused, non-assignee refused, parent touch with an extra key refused,
  `fieldNotes` with a foreign `authorId` refused.

### I4 — `DashboardAggregator.writeTouchesHistory` is untested · high · confidence high
- **Where:** `lib/features/dashboard/domain/dashboard_aggregator.dart`
  (+26/−9 this week); `dashboard_aggregator_test.dart` unchanged; 0 references
  in `test/`.
- **Opportunity:** it is the gate that decides whether a local write re-reads
  seven weeks of history (yesterday's I2 fix). Three pure cases: held id,
  start inside `[fetchStart, end)`, `heldIds == null`.
- **Suggested improvement:** three `test(...)` cases in the existing file.

### I5 — `AppointmentFormConcerns.searchClients` has no direct test · high · confidence high
- **Where:** `lib/features/calendar/application/appointment_form_concerns.dart`
  (279 lines; `searchClients` 96 lines: phone-rung narrowing via
  `_clientWindow.canNarrowTo`, request-id drop).
- **Opportunity:** reached only through the two controller suites
  (`searchClients(` 105× in `test/`, all via controllers); the rung ladder and
  the stale-request drop are not pinned on their own.
- **Suggested improvement:** a direct test with a fake repository: a
  narrowing rung reuses the window, a widening one refetches, a stale
  request id is dropped.

### I6 — `EventDetailsController.save` (144 lines) and `AddEventController.submit` (159 lines) · medium · confidence high
- **Where:** `event_details_controller.dart:551-694` (+ `_applySeriesChange`
  `:696-790`, 95), `add_event_controller.dart:301-459`.
- **Opportunity:** each does gate → seed-settle → 7–10-field snapshot →
  conflict/upload → write → outcome, with ~8 exit points that must each reset
  the busy flag (a CLAUDE.md invariant). Yesterday's bug items touched exactly
  these.
- **Suggested improvement:** extract the "snapshot form state" block
  (`:614-624` / the 7-field twin) into a private record and the create branch
  (`:598-614`) into `_saveNew(...)`. No pipeline class —
  `EventDetailsSavePipeline` already exists. Keep `isSubmitting = true` before
  the first await exactly where it is.

### I7 — `firebase_appointments_repository.dart` is 1205 lines, 44 methods · medium · confidence high
- **Where:** `lib/features/calendar/data/firebase_appointments_repository.dart`
  (+252/−130 this week).
- **Opportunity:** range streams + tail merge, history scan/search patching
  (`_patchHistoryDocs :1022`, `_patchSearchResults :1060`,
  `_CachedHistoryScanWindow :1200`), busy lookup, write-owner capture and the
  30-chunk `whereArrayContainsAny` share one class.
- **Suggested improvement:** move only the history scan/search window
  (`:986-1198`, ~210 lines touching just `_history*`/`_search*` state) into
  `appointment_history_scan.dart` as a plain class the repository composes.
  Do not split the range stream — its `docChanges` merge is shared state.
  `search.md`'s "`_patchWindow` from every write path" source-reading test
  must keep passing.

### I8 — History status chip auto-pages up to 500 reads for an empty answer · low · confidence high
- **Where:** `lib/features/clients/widgets/views/appointment_history_view.dart`
  (`_emptyFilterFetchCap = 20` × 25 rows; `_mayAutoFetch` ~`:213-225`; the
  `requestFirstPage` loop in `_buildFiltered` ~`:457-466`).
- **Opportunity:** only the Year chip short-circuits; a `Cancelled` or
  employee chip over an archive of mostly done jobs pays 20 × 25 reads before
  the empty state. Admin-only and deliberate (U5), but the status half is one
  server `where` away: `(status ASC, startTime DESC)` is already declared.
- **Suggested improvement:** thread an optional `status` into
  `HistoryPager.fetchPage` → `fetchHistoryPage(status:)`, swapping `whereIn:
  terminalStatusQueryValues` for `isEqualTo` when the chip is set. Leave the
  employee chip on the pager loop (narrowing it would need the retired `emp:`
  scopes).

### I9 — `calendar_view_prefs.dart` promises best-effort but has no `catch`, and no test · medium · confidence high
- **Where:** `lib/features/calendar/data/calendar_view_prefs.dart` (new, 34
  lines; only `main_calendar_screen.dart:126` reads it).
- **Opportunity:** the doc comment says a failure leaves the defaults, but the
  guard is in the one caller (`_restoreViewPrefs`), so a second caller would
  crash on a plugin failure. Also untested.
- **Suggested improvement:** move the `try`/`catch` (log-only, `SETTINGS`) into
  `load()`/`save()` or move the comment to the caller; one
  `SharedPreferences.setMockInitialValues` round-trip test including an
  unknown stored mode → day.

### I10 — new code since 33cde361 with no test · medium · confidence high
- **Where:** `clients/widgets/sections/duplicate_phone_notice.dart` (+76, new,
  `DuplicatePhoneNotice` 0 refs in `test/`); `clients/widgets/sheets/add_client_flow.dart`
  (`runAddClientFlow`, three-way `AddClientNext` switch incl. `isTwoPane`, 0
  refs); `routes/app_routes.dart` (+64: `textSize`, `locationSharing`,
  `notificationAsk` routes and the now-optional `LoginArgs` — no route test
  names them); `details_view_leaf_widgets.dart` (`DetailsEmployeePill` 0
  refs); `settings/widgets/cards/delete_account_card.dart` (+32),
  `clients/widgets/cards/archived_pill.dart` (+21).
- **Suggested improvement:** one widget test each for the first two; one
  `onGenerateRoute` case per new route (null args → `InvalidRouteScreen` for
  the two `SettingsDetailArgs` routes, `LoginArgs` null → login); the three
  leaf widgets are low priority.

### I11 — exit prologue repeated at exactly three sites · low · confidence high
- **Where:** `auth/screens/change_password_screen.dart:199-216`,
  `settings/widgets/views/delete_account_flow.dart:63-78` (`signOut`) and
  `:182-197` (`_runDeletion`).
- **Opportunity:** identical 12 lines: `confirmPendingPhotoExit(...)` →
  null/`!isCurrent` → reset busy → `deregisterThisDevice(devices)` →
  `deregistered = devices` → `!devices.isCurrentExit` → reset busy.
  Yesterday's I10 said "leave until a fourth site"; the count is now the
  rule's threshold of three (`account_setup_screen.dart:295` is a different
  shape — no device de-registration — and stays out).
- **Suggested improvement:** `Future<DeviceDeregistrationDeps?>
  exitDevicesAfterPhotoCheck(context, devices)` beside `confirmPendingPhotoExit`
  in `core/app/pending_photo_exit.dart`, returning null on any bail-out; each
  caller keeps its own busy-flag reset.

### I12 — `travel_policy.js` and `wave/outbox_core.js` have no direct suite · medium · confidence high
- **Where:** `functions/travel_policy.js` (283 lines, pure; reached only
  through `resolveReminderForAssignee`, 123 lines); `functions/wave/outbox_core.js`
  (305; `claimJob`/`commitOutcome` — the "outcome write only while still
  `inflight` with the same `claimedAt`" invariant in `wave.md` is pinned only
  through `wave_outbox_queries.test.js` and dispatch tests).
- **Suggested improvement:** a table-driven `travel_policy.test.js` over the
  decision function; one `outbox_core.test.js` asserting the claimedAt guard.
  (`bridge_reconcile.js`, `firestore_errors.js`, `job_naming.js`, `params.js`,
  `customer_queries.js`, `outbox_keys.js` are small and exercised indirectly
  by suites that do not mock them — fine.)

### I13 — `AppLock` keeps offering "Continue" after biometrics return · low · confidence medium
- **Where:** `lib/core/security/app_lock.dart:150-171` (`_authenticate`),
  `:40-42` (`_unavailable`).
- **Opportunity:** `_unavailable` is set when `isAvailable()` is false and
  cleared only by `_release()`. Leave the overlay up, background, resume: the
  retry now finds biometrics available and prompts, but the Continue button
  is still rendered, so a tap releases without authenticating while Face ID
  is up. ADR-0016 accepts "the switcher window, not a hard guarantee", so a
  narrowing, not a break.
- **Suggested improvement:** in `_authenticate`, `if (available &&
  _unavailable) setState(() => _unavailable = false);` before prompting; one
  case in `app_lock_test.dart`.

## 🟡 Code-quality suggestions (optional)

- **Q1** `lib/` (225 sites, 0 longer than 4 lines) — multi-line `//` blocks
  vs `code-quality.md`'s one-line rule ("enforced, not aspirational"). Sampled
  sites (`status_chip.dart:7`, `main.dart:82/394/460`, `hub_shell.dart:125`,
  `app_routes.dart:315`, `delete_account_flow.dart:53/203/211/248`,
  `clients_list_view.dart:399/438/457`) are all WHY-rationale that the obvious
  "fix" would get wrong, so this is an owner call (see Decide first). Only 4
  three-line blocks were ADDED this week (`appointment_card.dart:206`,
  `appointment_form_fields.dart:552`, `clients_list_view.dart:175,458`). On
  the JS side `wave/customers.js:264-297` (`upsertCustomer`) carries two 9–13
  line rationale blocks already recorded in ADR-0148/0150 — that trim is
  unambiguous.
- **Q2** `lib/core/images/image_storage_service.dart:41,25` —
  `uploadImage(appointmentId, file)` and its only dependant `composeFileName`
  have no production caller (`uploadQueuedImage` and `deleteImages` are the
  live paths); 7 tests in `image_storage_service_test.dart:268-343,356-371`
  drive them, including the magic-byte rejection. Delete both AFTER porting
  the magic-byte/size-cap cases to `uploadQueuedImage` (which duplicates the
  checks at `:97-101`), so the `images.md` invariant stays pinned. Not
  auto-applied because the tests guard a security invariant.
- **Q3** `lib/features/settings/widgets/views/location_sharing_view.dart:160-168`
  — hand-rolled destructive outlined style; `frontend.md` names
  `destructiveOutlinedButtonStyle` (`core/theme/button_styles.dart`, 6
  callers). The local one adds an `r12` shape the shared one lacks: either
  pass the shape through the helper or accept the default shape. `build()`
  there is 71 lines; extracting the button as `_ClearLocationButton` brings it
  under the ~60 guide.
- **Q4** `lib/routes/app_routes.dart:56` — `forgotPassword` reads
  `settings.arguments as ForgotPasswordArgs?`; every other typed arm uses
  `_args<T>` (ADR-0017). Switch it so a wrong type degrades to
  `InvalidRouteScreen`.
- Smaller, noted only: `personal_block_clash_dialog.dart:363,383` `setState`
  after `await _write(...)` relies on `_write` returning `false` when unmounted
  (`:412-414`) — one inline clause would stop a future `true` path forgetting
  the re-check; `EventDetailsController` hosts a second `Notifier`
  (`FieldNoteDrafts :899`) against one-class-per-file — moving it to
  `field_note_drafts.dart` is the one zero-risk cut from that 917-line file;
  `password_reauth_dialog.dart:101` tints the eye icon with
  `CupertinoColors.secondaryLabel.resolveFrom(context)` rather than a token
  (brightness-aware, so dark mode works); `build()` methods between 61 and 69
  lines in `app_lock.dart:240`, `details_view_body.dart:218`,
  `appointment_image_carousel.dart:33`, `app_empty_state.dart:21`,
  `onboarding_screen.dart:40`, `new_clients_section.dart:213`,
  `appointment_status_picker.dart:18`, `login_screen.dart:206` — all within a
  sub-widget of the guide, none urgent.

## Checked and sound

- **Callables (all 18):** guard order auth → `assertAdminCall`/`assertActiveCall`
  → payload/`requireString`/`requireDocId` → re-auth where applicable →
  `enforceDurableRateLimit` → work; `enforceAppCheck: true` on every one; no
  `data.*` consumed unvalidated; errors are enum-shaped codes, no upstream
  bodies or stacks; uids hashed in logs. `saveAppointmentEdits`: 4 MiB / 400
  commands, every command validated before `onValidated()` consumes the
  limiter, `startedAt`/`completedAt`/`pictureCount`/`editProtocol`/`editRevision`
  unreachable from the payload, `historySearchScopes` server-rebuilt,
  `checkConflicts` folded into the transaction with the operation's own ids
  excluded. `findAppointmentConflicts` `scope-denied` for a non-admin naming
  anyone else. `createEmployeeAccount` hard-codes `role: employee` and mints
  the starting password per call, never persisted. `assertActiveCall` spreads
  `uid` last; `assertFreshReauth` fails closed.
- **Rules:** every `allow` carries an admin/active/owner clause; `users` read
  has three clauses; both `/users` denylists intact; `clients` create/update
  refuse `waveCustomerId`/`wave`/`jobCount`/`deletionToken`/`buildingKey`;
  exactly three assignee disjuncts, each `hasOnly`-bounded with `updatedAt ==
  request.time`; admin update on `editProtocol == 1` docs limited to
  status/`updatedAt`/`seriesOpId` forward transitions; `liveActivityTokens.expiresAt`
  `< request.time + 31d`; all server ledgers `if false`. `storage.rules`
  assignee create requires `resource == null`. Query/rule match: the new
  `_rangeTailQuery` keeps `employeeIds` scoping; `watchOverdueOpen` is
  admin-only; `watchEmployees` keeps `status == 'active'`. The three new
  composites and the overdue DESC/ASC pair are declared.
- **lib/ invariants:** `FirebaseFirestore.instance` only in the three allowed
  files; no role from SharedPreferences; `normalizeEmail` the only
  lowercasing; every `obscureText` field sets
  `kCredentialImePersonalizedLearning`; no PII in logs; App Check activated,
  `persistenceEnabled: true`; kill switches fail OPEN; splash/sign-in gates
  (`isInvited` before active, `passwordResetRequired` after,
  `resumeAfterSignUp` restating the gate); `isSplashAuthFailure` never admits
  anyone to the hub; `AppLock` tri-state preserved and log-out routed through
  `AccountExitController.exitAccount` (deregister before `signOut`);
  `_allowedStatuses` four values; employee visibility filter on both range
  queries; `fcmTokens` `platform` write retained.
- **Since-33cde361 logic:** range tail query shapes and `_orderedRangeRecords`
  dedup pinned; `isPersonal` equality vs legacy docs documented (ADR-0189,
  DEPLOYMENT §4d); the backfill is idempotent, dry-run through
  `bootstrapScript`, reports wide client jobs read-only, `--live` resolved by
  `run.js`; `overdueReviewBoundary` quarter floor + timer; yesterday's B2, B3,
  B5, B6, I10 intact; offline guard before the in-flight flag in
  `delayAppointment`/`saveChanges`/`submit`; `_employeesBusyOf` →
  `CalendarFailureEmployeesBusy` → `conflictHitOf`; `searchClients` is one
  200-read window + 5-read exact probe; notices park non-error behind an
  action notice and an error pre-empts; `scoreRecord` NANP strip on both
  sides; `DuplicatePhoneCheck` supersedes stale lookups and fails open;
  clients list `_lastPageFull`/`_pageBoundaryValues` patching; mirror dedup
  requires uid + signature + `stillHolds`; `SessionFencedSync.isAttemptStale`
  a straight refactor; ask gates mark seen before pushing; dashboard refetch
  gated by `writeTouchesHistory` and a 2-s `Debouncer`; form frames'
  `PopScope` + `_isConfirming`; l10n EN/FR identical key sets, every `@` block
  present, `untranslated.json` empty.
- **Performance:** every new `TextEditingController`/`FocusNode`/`Debouncer`/
  `Timer`/listener in the changed files has a matching dispose; `DetailsViewBody`
  watches with `.select`; `_noteStampFormatFor` memoized; `_RemoteSlide`
  caches its `loadBytes()` future; disk cache `read` awaits only `_clearing`;
  functions cold start adds no top-level heavy require; `minInstances: 1` on
  the three callables is the deliberate P1 spend.
- **Dead weight:** 970 ARB keys, all referenced; no en/fr drift; no provider
  without a `ref.*`/override; no file with zero inbound imports; all five
  pubspec heuristic hits are expected false positives
  (`google_maps_flutter_ios_sdk9` SPM override, `integration_test`,
  `build_runner`, `freezed`, `flutter_launcher_icons`); `functions/package.json`
  clean; the three `test/support/` files all imported.
- **CI/CD, native:** `deploy.yml` `workflow_dispatch` only, `permissions: {}`,
  WIF, pinned SHAs, `--ignore-scripts` before any credential, `--force`
  refused; `ci.yml` `contents: read`, pinned SHAs; the two Swift diffs are
  date comparisons only.

## Notes / uncertainties

- Static review only; nothing was executed against Firebase or a device.
- B1 was traced from the latency-compensated snapshot ordering; the one
  assumption is that Geolocator reports `denied` while the iOS prompt is
  open (`notDetermined` → `denied` in its mapping), which matches the plugin.
- Function-length counts are brace-anchored (2-space method header to the
  next `  }`), verified by hand on `save`, `submit` and `onGenerateRoute`.
- "No direct test" (I4, I5, I10) means no test imports or names the symbol; a
  parent-screen test can still exercise the code.
- Reviewer briefs and scratch scripts are in the session scratchpad, not the
  repo.
