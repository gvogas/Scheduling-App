# Codebase Audit — 2026-09-19

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`ios/Runner`, `test/`, `.claude/rules/`), weighted toward the 58 commits / 227
source files landed since the previous audit's baseline `051a6b6d`.
Baseline: `dev` @ `608b817a` **plus a dirty working tree** (31 files of
uncommitted docs + overdue/live-map/location-ask edits, present before this
audit started and reviewed as-is). This audit's own edits are the four files
listed under "Auto-applied cleanups" — keep them distinct when committing.

The previous audit (`CODEBASE_AUDIT_2026-09-07.md`) is not repeated here; its
four carried-over owner items (Maps billing cap, Crashlytics re-check, Wave
"Retry failed" press, Xcode `InfoPlist.strings`) remain wherever that file and
`docs/plans/README.md` left them.

## Summary

- Scanned: 475 Dart files in `lib/`, 61 JS modules in `functions/` (+ scripts),
  384 Dart test files, 97 Functions test suites, both rules files, the CarPlay
  Swift sources.
- Auto-fixed (safe, in the diff): **4** — 1 stale doc pointer, 1 zero-reference
  design token, 2 unused JS export entries.
- Reported for your decision: **27** (⚠️ 0 pre-ship · 🔴 2 security · 🟠 2 bugs ·
  🔵 12 improvements · 🟡 11 code-quality / dead-code)
- Verification (observed after the auto-fixes): see the "Verification" section
  at the end.

**The static layer is pristine again.** `flutter analyze` No issues found,
`dart fix` Nothing to fix, ESLint clean, zero unused files, zero orphaned l10n
keys (911 EN = 911 FR, all reached), zero BOMs, SnackBars only at the three
sanctioned sites, every raw `Stream.listen` passes `onError`, no `ref.read` in a
`catch`, no `firebase_analytics` import outside its owner. The one unused-dep
hit that is not codegen tooling, `google_maps_flutter_ios_sdk9`, is a documented
platform-implementation swap (`pubspec.yaml:89-94`), not dead weight.

No finding needs a backend deploy to *report*; **B1's fix is a Functions
change and will need one.**

## Status — 20 done, 3 kept, 1 not a defect, 1 by design, 2 open for you (2026-09-19)

Verification after the implement pass (observed): `flutter analyze` **No issues
found!** · `flutter test` **3770 passed / 0 failed** (was 3760: +15 new, −5 with
the deleted dead code) · `functions` ESLint clean · `functions` jest **1986
passed / 95 suites** (was 1971). No BOMs; no generated file deleted.

Every new test was checked to FAIL with its fix removed (S2 aside, which is a
new guard): I4, I7, I11 and B1 were each re-run against the unfixed code.

**Deviations:** S2 guarded in `openAppointment` (the one choke point) ·
B1 writes nothing on a still-failing revert · B2 uses one larger live limit
(`pageToCap` is one-shot) and the badge now tops out at 1000 · I6 keeps the raw
message for non-Wave errors · I9 renamed the typedef `MonthSection` ·
I5's pattern file is `text_limits_test.dart`, not `client_record_test.dart`.

**Left for you:** deploy `functions` (B1, I6 — `docs/DEPLOYMENT.md`); confirm
and remove the three H1 worktrees; I12 needs a real bad record.

## Decide first

A blanket "do all" would otherwise have to guess on these:

1. **S1** — does CarPlay deliberately bypass the biometric app lock? Either
   document it as accepted or gate it. Product call.
2. **B2** — which fix shape: page to a larger scan cap (mirrors the server,
   no index) or add an `isPersonal == false` constraint (cheaper, needs an
   index and every legacy doc to carry the field)? Recommended: the first.
3. **D1–D6** — delete test-only public code, or keep some as documentation /
   mirror references? Recommended per item below.
4. **Q1** — the one-line comment rule is visibly not holding in new code. Trim
   now (moving rationale into rules files), or accept? It is the largest edit
   by line count in this report.
5. **H1** — three stale agent worktrees; remove only after you confirm their
   uncommitted work landed.

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `lib/features/wave/data/wave_service.dart:9,90` | Pointer `SYNC_PUSH_BUDGET_MS` in `wave/callables.js` → `wave/sync_run.js` | Stale pointer: the constant is defined at `functions/wave/sync_run.js:205`; `callables.js` only imports it |
| `lib/core/theme/design_tokens.dart:240` | Removed `AppRadius.rIcon = 12` | Zero references in `lib/`, `test/`, rules; only archived plan docs mention it. Unlike `r24` it carries no "deliberate empty rung" note |
| `functions/recount_claim.js:133` | Dropped `claimBody` from `module.exports` | Used only inside its own module; no importer, no test |
| `functions/scripts/backfill-wave-blocked.js:199` | Dropped `sameProblem` from `module.exports` | Used only inside its own module (via `sameProblems`); no importer, no test |

> Nothing below this line was auto-changed. `expandRunWindows`
> (`functions/day_slice_utils.js:304`) was also export-unused but was **kept**,
> because I1 below needs the export to test it.

## ⚠️ Pre-ship checklist

None. Zero `TODO(pre-ship)` markers in the tree; App Check activated and
enforced on every callable.

## 🔴 Security findings (review required)

### S1 — CarPlay writes status and fetches client phones past the app lock · severity: low · confidence: high (behaviour), product call (whether it matters)  · **DONE — accepted by owner (documented in `notifications.md`, no code change)**
- **Where:** `lib/core/app/carplay_bridge.dart:~98-111` (`_writeStatus`) and
  `:~115-123` (`_dialableNumber`); Swift callers in
  `ios/Runner/CarPlay/CarPlaySceneDelegate.swift:~205` and `CarPlayBridge.swift`.
- **Risk:** iOS runs CarPlay on a locked phone by default. Neither method-channel
  path consults `AppLockController`/`appLockEnabledProvider`, and the Swift side
  does not check lock state. Someone holding a user's locked phone in a car can
  mark jobs started/complete (an admin: any job in the business) and pull client
  `tel:` numbers, without the Face ID gate the user enabled. No privilege
  escalation — Firestore rules still bound writes to the signed-in role.
  `.claude/rules/notifications.md:44` documents and accepts the locked-readable
  *snapshot*; the on-demand phone lookup and the status write are not weighed
  against the app lock anywhere.
- **Fix:** either record in `notifications.md` that CarPlay deliberately bypasses
  the app lock, or return `false`/`null` from both paths when the lock is enabled
  and protected data is unavailable (Swift: `UIApplication.shared
  .isProtectedDataAvailable`, hiding the two buttons the same way they hide with
  no Flutter engine). App-only; no deploy.

### S2 — Deep-link `id` reaches `.doc(id)` without a doc-id shape check · severity: low · confidence: low  · **DONE (deviated — guarded once in `openAppointment`, which all three entry points share, instead of in `classifyDeepLink` + `handleWidgetTap`)**
- **Where:** `lib/core/deep_links/deep_link_target.dart:32` →
  `firebase_appointments_repository.dart:~132`. Pre-existing, not new code.
- **Risk:** an id containing `/` (`…?id=<appt>/fieldNotes/<note>`) addresses a
  subcollection document. For an admin it opens as a garbage appointment sheet
  with admin actions (Delete included) — deleting something that admin could
  delete anyway. Needs a tricked admin acting on an obviously broken record.
- **Fix:** reject ids containing `/` or longer than 128 chars in
  `classifyDeepLink` and `handleWidgetTap`, mirroring `isValidDocIdField` in
  `firestore.rules`. App-only.

## 🟠 Bug findings (review required)

### B1 — A Wave-"blocked" client stays blocked forever if edited back to its last-synced values · severity: medium · confidence: high  · **DONE — OPEN for a `functions` deploy (deviated — a revert that still fails the contract writes nothing)**
- **Where:** `functions/wave/triggers.js:111` (`shouldEnqueueClientWrite` runs
  before the contract block at ~125-151); rule in `functions/wave/enqueue.js:36-39`.
- **Problem:** synced client (hash H) → admin edits it into a contract-refused
  state → trigger writes `wave.syncState: 'blocked'` + `wave.problems` and cancels
  the job. `verdictPatch` (`customer_contract.js:286`) never touches
  `wave.lastSyncedHash`. Admin types the original values back → `mappedFieldsHash`
  is H again → Rule 2 (`afterHash === wave.lastSyncedHash`) returns false before
  the contract is re-evaluated → the stale `blocked` verdict and its reasons stay
  in `WaveSyncBadge`/`WaveBlockedList` for a client that is valid and already
  matches Wave. Nothing else heals it: the dispatcher's `noop` heal needs a queued
  job (cancelled), `backfill-wave-blocked.js` deliberately leaves blocked-but-passing
  docs alone (`wave.md`), and the import skips it through the same hash gate.
- **Fix:** in the trigger, when Rule 2 would short-circuit but
  `after.wave?.syncState === 'blocked'`, run `buildCustomerPayload(after)` and on
  an ok verdict write `verdictPatch(contract, {clearedState: 'synced'})`. Pin with
  a jest case: synced → blocked edit → revert. **Needs a `functions` deploy.**

### B2 — The overdue review's 500-row cap is consumed by personal blocks and days off · severity: medium · confidence: high (mechanism), timing depends on data  · **DONE (scan 5000 / list 1000, filtered in the repository; one live limit, not `pageToCap`, which cannot back a stream)**
- **Where:** `lib/features/calendar/data/firebase_appointments_repository.dart:74`
  (`_overdueReviewLimit`) and `:461-481` (`watchOverdueOpen`), filtered afterwards
  by `overdueJobsAt` (`lib/features/calendar/domain/overdue_review.dart:12`).
- **Problem:** the query is `status in open`, `endTime < now`, newest `endTime`
  first, `limit(500)`. `displayStatusAt` (`appointment_record.dart:137-146`) keeps a
  personal block on its stored status forever, and a day off stays stored
  `pending` forever — so every past personal block and day off (each occurrence
  of a recurring one) sits in this window permanently, dropped only in Dart after
  the limit. As they accumulate they take the newest slots, and the real overdue
  jobs — the OLDEST rows — are the ones pushed off the end. The screen and the
  drawer badge under-count, and the `APPT-REVIEW … hit the 500-doc cap` warn then
  fires on every snapshot for every admin with the drawer open, even when no
  overdue job is actually lost. The server twin `runMonthEndOverdueReview` already
  separates a 5000 scan cap from a 1000 report cap for exactly this reason
  (`notifications.md`), so the push can say "N jobs" while the screen lists fewer.
- **Fix (see Decide first #2):** page through `pageToCap` to a larger scan cap and
  apply `overdueJobsAt` before the display cap — mirroring the server's two caps —
  and key the warn on overdue jobs actually lost. Alternative: an
  `isPersonal == false` constraint plus a composite index, only safe if every
  legacy doc carries the field.

## 🔵 Areas to improve (review required)

### I1 — The server conflict check has none of the Dart side's overlap examples · impact: high · confidence: high  · **DONE — all 12 Dart examples hold in JS; no mirror drift**
- **Where:** `functions/day_slice_utils.js:261` (`expandRunWindows`), `:289`
  (`dailyWindowsOverlap`); `functions/__tests__/day_slice_utils.test.js`.
- **Opportunity:** that suite claims "the SAME worked examples" as
  `test/features/calendar/domain/appointment_day_slice_test.dart`, but calls
  neither function (grep: 0 hits). Dart has 6 + 6 examples; JS has 4 callable-level
  cases in `indexed_search_conflicts.test.js`. Unpinned in JS: overnight shift
  clashing in its small hours, touching windows not clashing, a reversed window
  never clashing, the all-day 00:00–23:59 expansion, the 14-day clamp. CLAUDE.md
  records this check already shipped wrong once.
- **Suggested improvement:** add `describe("expandRunWindows")` and
  `describe("dailyWindowsOverlap")` blocks copying the 12 Dart examples
  value-for-value, plus a one-line pointer to the JS suite atop the Dart test.
  Tests only.

### I2 — `overdueOpenJobsProvider` re-reads the whole overdue set on a cold drawer open · impact: medium · confidence: high  · **DONE (`keepWarmWithGrace` gained an optional `grace:`)**
- **Where:** `lib/features/navigation/widgets/app_nav_drawer.dart:~308`, watching
  `overdueOpenJobsProvider` (`overdue_review_providers.dart:19-33`).
- **Opportunity:** a closed drawer doesn't build, so only `keepWarmWithGrace`
  (3 min) keeps the listener. A drawer opened after the grace starts a new query
  with a fresh `now` — a full re-read (≤500 docs) to show one number, and the badge
  appears late. Same on the screen's 15-min `invalidateSelf`. Cost is small in
  dollars; the visible symptom is the late badge.
- **Suggested improvement:** hold this provider for `kOverdueReviewRefresh` rather
  than the shared 3-min grace. Do NOT switch the badge to a `count()` aggregate —
  `overdueJobsAt` filters in Dart and `appointments.md` requires badge and screen
  to agree. Interacts with B2; do them together.

### I3 — `AnalyticsIdentityListener` has no test · impact: medium · confidence: high  · **DONE**
- **Where:** `lib/core/app/analytics_identity_listener.dart` (0 references in `test/`).
- **Opportunity:** it holds the last role across loading/error, clears on an empty
  role, and skips same-value emissions. A regression misattributes every event for
  a session and the reports still look plausible.
- **Suggested improvement:** one widget test overriding `userRoleProvider` and
  `analyticsServiceProvider` with a fake; walk admin → loading → error → '' →
  employee and assert the exact `setUserRole` sequence.

### I4 — Resuming the app takes a GPS fix before checking whether it may upload it · impact: medium · confidence: high  · **DONE**
- **Where:** `lib/features/presence/application/presence_sync_controller.dart:288-312`
  (`_freshFixOnResume`).
- **Opportunity:** every resume while sharing is on calls
  `Geolocator.getCurrentPosition(medium)`, and only then checks
  `shouldWritePresenceFix` (≤1 upload / 2 min). A resume inside that window powers
  the location hardware and discards the fix. Battery, not Firestore.
- **Suggested improvement:** check the throttle against `_lastUploadAt` before the
  await. Caveat: the fix also refreshes `_lastPosition`, which the trailing flush
  can use — confirm that freshness isn't wanted before skipping it.

### I5 — Wave problem-field vocabulary is hand-mirrored and unpinned · impact: medium · confidence: high  · **DONE — no missing label (all 10 fields covered)**
- **Where:** `functions/wave/customer_contract.js` (9 `field:` names) ↔
  `lib/features/wave/widgets/wave_problem_list.dart:70` (`_fieldLabel`). Neither
  the mapping nor `WaveProblemList` has a test.
- **Opportunity:** a server-side rename silently degrades to showing the admin the
  raw key ("postalCode").
- **Suggested improvement:** a Dart test that reads `customer_contract.js` source
  and asserts every `field: "x"` has a non-fallback label —
  `client_record_test.dart:261` already reads `mappers.js` the same way.

### I6 — Two Wave log sites record the raw error instead of `describeWaveError` · impact: low · confidence: medium  · **DONE (deviated — sanitized `error` + `errorDetail` split, since `describeWaveError` blanks non-Wave errors) — OPEN for a `functions` deploy**
- **Where:** `functions/wave/sync_run.js:142` (failed import), `:249` (drain that
  wraps Wave). Eight more `String(e)` sites in `wave/` catch Firestore errors and
  are fine.
- **Opportunity:** `wave.md` names `describeWaveError` as the log-side owner
  because Wave's raw message can quote the offending value (customer data).
- **Suggested improvement:** switch those two sites. Functions deploy to take effect.

### I7 — The inline add-client double-tap guard has no test · impact: low · confidence: high  · **DONE**
- **Where:** `lib/features/calendar/widgets/sheets/inline_add_client_host.dart`
  (`requestAddClient`), `lib/features/clients/widgets/sheets/add_client_flow.dart`.
- **Suggested improvement:** one widget test tapping twice in one frame, asserting
  one sheet opens.

### I8 — Oversized `build()` methods · impact: low · confidence: high  · **DONE**
Measured `Widget build(` → closing brace: `details_view_body.dart:69` 143 (was 140
at I18 — grew back), `clients_list_header.dart:86` 134 (new; ~75 lines are the
hand-painted sort pill), `clients_screen.dart:139` 133 (new), `notice_listener.dart:195`
124, `employee_picker.dart:53` 109, `add_appointment_sheet.dart:289` 104.
- **Suggested improvement:** only `clients_list_header.dart` is a clean win — move
  the `PopupMenuButton` child (~160-212) into a private `_SortPill` in the same
  file. Leave the rest unless touched for another reason.

### I9 — The calendar domain now imports a clients domain helper · impact: low · confidence: high  · **DONE (deviated — typedef renamed `MonthSection` in `lib/core/utils/month_sections.dart`)**
- **Where:** `lib/features/calendar/domain/overdue_review.dart:3` imports
  `clients/domain/history_grouping.dart` for `monthSectionsOf` (uncommitted working
  tree).
- **Suggested improvement:** it now has callers in two features — promote
  `monthSectionsOf` + `HistoryMonthSection` to `lib/core/utils/` per CLAUDE.md's
  promotion rule; its test moves with it.

### I10 — Two owners of locale-keyed `DateFormat` caches, reading different locale sources · impact: low · confidence: medium  · **DONE**
- **Where:** `lib/core/utils/date_utils_helper.dart:5-11` (keyed on
  `Intl.defaultLocale`) vs `lib/features/calendar/domain/month_grid.dart:50-81`
  (keyed on a passed `Localizations.localeOf`). The working tree just moved
  `overdue_month_splitter.dart` from one to the other.
- **Suggested improvement:** no merge — record in `.claude/rules/frontend.md` which
  owner to use (context-bound UI → `month_grid`; context-free → `DateUtilsHelper`).

### I11 — Live map Retry may not re-subscribe · impact: low · confidence: low  · **DONE — reproduced: Retry did nothing; now invalidates the errored sources**
- **Where:** `lib/features/presence/screens/live_map_screen.dart` —
  `onRetry: ref.invalidate(liveMapTeamProvider)`.
- **Opportunity:** that is a derived `Provider`; invalidating it re-reads the same
  errored `allPresenceStreamProvider` instead of re-subscribing. Pre-existing shape.
  Worth a quick test before changing anything.

### I12 — `repairMojibake` may miss cp1252-style misdecoding · impact: low · confidence: low  · **OPEN — needs a real misdecoded record to confirm before any change**
- **Where:** `functions/mojibake.js`.
- **Opportunity:** it repairs Latin-1-style misdecoding; cp1252 (`Å“` for `œ`,
  capital accented letters) would not match. Unconfirmed which Google returns —
  check against a real bad record before changing.

## 🟡 Code-quality suggestions and dead code (optional)

### D1 — `WaveProblemSeverity.hasBlocking` is test-only and a second spelling of the blocking test  · **DONE**
`lib/features/wave/domain/models/wave_problem.dart:88-89`. Last production caller
went in `e0460805`; `wave.md:375` allows exactly one spelling. **Recommend delete**
(with its test cases).

### D2 — `toggledFilter` is test-only; its doc names the retired `ClientTypeFilterBar`  · **DONE**
`lib/features/clients/domain/models/clients_filter.dart:63-67`. Caller went in
`b2adc705`. **Recommend delete.**

### D3 — `tourScopeByKey` is test-only  · **DONE**
`lib/features/feature_tour/domain/tour_scope.dart:61`. Last caller went in
`4c82eb60`. **Recommend delete.**

### D4 — `monthGridMaxRows` is test-only  · **KEPT by recommendation**
`lib/features/calendar/domain/month_grid.dart:5`. Reads as a documentation
constant. **Recommend keep.**

### D5 — `searchQueryTokens` / `kSearchTokenQueryLimit` have no `lib/` caller  · **DONE (doc fixed, code kept)**
`lib/core/search/search_tokens.dart:3,7`. Query tokenizing moved server-side
2026-09-04; the Dart copy anchors the shared-example mirror test, and CLAUDE.md
names the constant. **Recommend keep, and fix `docs/ARCHITECTURE.md:35`**, which
still says the app uses it.

### D6 — `HubShellState.currentTab` is test-only  · **KEPT by recommendation**
`lib/routes/hub_shell.dart:64`. Tests reach shell state through it. **Recommend keep.**

### D7 — `digitsOnly` export in `functions/search_tokens.js:219` has no importer  · **KEPT by recommendation**
Kept for symmetry with the public Dart twin. **Recommend keep.**

### D8 — `SYNC_PUSH_BUDGET_MS` pointer is one-way  · **NOT A DEFECT — `sync_run.js:~191` already points back to `wave_service.dart`**
`lib/features/wave/data/wave_service.dart:90` says "each carries a pointer to the
other", but `functions/wave/sync_run.js:205` has no pointer back to
`WaveService`'s timeout. Add one line.

### Q1 — The one-line comment rule is not holding in new code  · **DONE — 825 → 271 comment lines across 12 files; rationale moved into 8 rules files**
Since `051a6b6d`: 1,105 of 8,508 added `lib/` lines and 772 of 2,246 added
`functions/` lines are comments. Worst: `analytics_service.dart` (20 multi-line
blocks, longest 18), `personal_block_clash_dialog.dart` (21 / 17),
`dashboard_providers.dart` (17 / 17), `schedule_snapshot.dart` (longest 23 at
:104), `analytics_privacy.dart:35` (23), `analytics_identity_listener.dart:6` (14),
`carplay_bridge.dart:16` (11), `date_utils_helper.dart:121-129` (9).
`code-quality.md` calls the rule "enforced, not aspirational". Rationale must move
into the rules file first (`analytics.md` already exists) or it is lost. JSDoc
skeletons stay for jsdoc-lint. See Decide first #4.

### Q2 — Multi-widget files in changed code  · **NOT IMPLEMENTED by design — the recommendation was split-on-touch**
`details_view_leaf_widgets.dart` (6 widgets), `live_map_overlays.dart` (4),
`agenda_sliver_list.dart` (3), `settings_tile.dart` (3), `crew_filter_button.dart`
(2), `auth_scaffold.dart` (2). Split only when touched.

### H1 — Three stale agent worktrees  · **OPEN — needs YOUR confirmation before `git worktree remove`**
`.claude/worktrees/agent-a20df93257b0f9426` (branch `wave-phase4`, 37 uncommitted),
`agent-a4aadab900dd5788a` (`month-end`, 59), `agent-aaf2499f3c640eead` (41) — all at
`ba2fdb05`, already merged into `dev`. Gitignored, but every repo-wide grep that
doesn't exclude them double-counts. Confirm their uncommitted work landed, then
`git worktree remove`.

## Notes / uncertainties

- Raw spacing numbers in `app_nav_drawer.dart:73,134,353`, `appointment_card.dart:186`,
  `agenda_sliver_list.dart:263`, `calendar_header_block.dart:65`,
  `sheet_header_bar.dart:55` mix on-scale and off-scale design values; none has a
  single unambiguous token target, and the spacing memory records intentional
  off-scale values. Not auto-fixed, not reported as drift.
- ~45 symbols named in rules/CLAUDE.md no longer exist in code; every one sampled
  is a correctly worded historical "deleted/removed" note, not a live pointer.
- ~140 JS exports used only by `__tests__` are the repo's deliberate
  export-for-test pattern — not reported.
- Security: `firestore.rules` changed only by the already-deployed B5 cap
  (200 → 250); `storage.rules` unchanged; all five Wave callables open with
  `assertAdminCall` + `enforceAppCheck`; `waveSetImportSchedule` is a correct
  `#compat-1.61.0` accepted-and-ignored no-op; analytics `allParams` carries no
  free text; no secrets in tracked files.
- Findings came from static reading; B1 and B2 were traced by hand through the
  code paths, not reproduced at runtime.

## Verification

Observed after the four auto-fixes:
- `flutter analyze`: **No issues found!**
- `flutter test`: **3760 passed / 0 failed**
- `functions` ESLint: clean
- `functions` jest: **1971 passed / 95 suites**
