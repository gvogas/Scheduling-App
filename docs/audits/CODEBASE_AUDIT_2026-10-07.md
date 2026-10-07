# Codebase Audit — 2026-10-07

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`.github/workflows/`, `test/`). Baseline: `dev` @ `6a19ff6a`, clean tree.
Emphasis on the code changed since the 2026-09-28 audit (`cee76f45..HEAD`, 95
commits): Remote Config kill switches + forced update, admin password reset,
the deploy workflow and its checkers, `functions/scripts/run.js`, the shared
Dart/JS fixtures.

## Summary

- Scanned: `lib/` (383 `build()`s, 924 ARB keys), `functions/` (32 exports,
  19 callables), both rules files, both workflows.
- Auto-fixed (safe, in the diff): 4 — analyzer exclude for `node_modules`, one
  log tag added to the registry, three stale doc lines.
- Reported for your decision: 21 (⚠️ 0 pre-ship · 🔴 3 security · 🟠 8 bugs ·
  🔵 6 improvements · 🟡 4 code-quality notes)
- Verification: `flutter analyze` **No issues found!** (it was **7 issues**
  before the exclude, see the table) · `dart run tool/test.dart` **3976/3976 passed** ·
  functions lint clean · functions jest 2186/2186 (run by the
  maintainability reviewer, 86.4 % lines).
- Live backend at audit time: 32/32 deployed functions match `index.js`
  exports; all 30 composite indexes `READY`.

## Decide first

**All decided 2026-10-07 (owner):** S1 re-auth + refuse admins; B2 strict `true`/`false`; B6 keep the token while paused; I6 document only.

1. **S1:** should resetting a password require fresh re-auth, and may an admin
   reset another admin? Options: (a) re-auth prompt + `assertFreshReauth`,
   admins still resettable; (b) (a) plus refuse admin targets; (c) leave as is
   (the plan allowed admin-resets-admin on purpose). Needs functions + app.
2. **B2:** what a malformed kill-switch value should mean. Options: (a) only
   exact `true`/`false` count, anything else takes the code default (fail OPEN,
   matches the invariant); (b) keep today's per-SDK parsing and only document
   it (done in this pass). (a) touches both sides and the shared fixture.
3. **B6:** should `endLiveActivity` keep the token while paused (consistent
   with "never prune while paused"), or is deleting it fine since current
   builds end their cards locally?

**Implement pass (2026-10-07):** `flutter analyze` No issues found! · `dart run tool/test.dart` **4024/4024** · functions lint clean · jest **2237/2237** (107 suites).

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `analysis_options.yaml:41` | Added `"**/node_modules/**"` to `analyzer.exclude` | `npm ci` in `tools/deploy` (the lockfile-pinned firebase CLI) installs firebase-tools' Dart templates; `flutter analyze` then reported **7 issues** (6 errors) from `tools/deploy/node_modules/firebase-tools/templates/init/functions/dart/`, breaking the `No issues found!` baseline locally. CI was unaffected (fresh checkout, no install before analyze). |
| `.claude/rules/error-handling.md:161` | Added `ANALYTICS` to the log-only tag registry | Used at `analytics_service.dart:307` and `analytics_providers.dart:45`; the registry is meant to be exhaustive. |
| `docs/plans/README.md:50-51,54` | Kill-switch rows → functions DEPLOYED (`29fa4072`), app half not shipped; repeatable-deploys row → BUILT, first workflow deploy `61811650` | Rows said "not deployed" / "PLAN, not started"; the deploy log says otherwise. |
| `docs/DEPLOYMENT.md:258-260` | Kill-switch "Values" line corrected | It claimed `1/true/t/yes/y/on` read ON on both sides; the app's `asBool` (platform interface 3.0.7) accepts only `true`/`1`. See B2. |

> Full detail is in `git diff`. Nothing below this line was auto-changed.

## ⚠️ Pre-ship checklist

None. Zero `TODO(pre-ship)` markers (zero TODO/FIXME/HACK of any form in
`lib/`, `test/`, `functions/`).

## 🔴 Security findings (review required)

### S1 — admin password reset has no fresh-reauth gate and can target another admin · low · confidence 90 %
- **Status (2026-10-07):** **DONE — needs functions deploy + app build (ship the app with or before the deploy).** Owner chose re-auth + refuse admins. Server: `assertFreshReauth` (5 min) after `requireDocId`, before the rate limit; `target-is-admin` refused in the pre-check AND inside `markPasswordResetRequired`'s transaction. App: the confirm dialog reuses `DeleteAccountReauthDialog` (new optional title/message/confirm label) and re-authenticates before the call; Reset password is hidden for an admin target; `EmployeesFailureTargetIsAdmin` / `EmployeesFailureReauthRequired` + 3 ARB keys. (Deviated: a wrong password shows the generic invalid-credentials message, not the delete flow's "log in again" wording.)
- **Where:** `functions/employee_accounts.js:717-752` (`resetEmployeePassword`);
  `lib/features/employees/widgets/sheets/edit_person_sheet.dart`
  (`_confirmResetPassword`).
- **Risk:** someone with brief access to an unlocked admin phone (App Lock is
  optional) resets another admin, reads the plaintext password from the dialog,
  signs in elsewhere and sets their own password on the forced change screen.
  The result is a persistent admin account that outlives the stolen session and
  locks the real owner out. At 20/hour this can cover the whole roster. Unlike
  `changeEmployeeEmail`'s admin branch, the reset already has a confirm dialog,
  so a re-auth step has somewhere to go.
- **Fix:** re-auth in the confirm dialog (`DeleteAccountReauthDialog` pattern)
  and `assertFreshReauth(req.auth, "resetEmployeePassword", REAUTH_MAX_AGE_SECONDS)`
  after `assertAdminCall`. Optionally refuse `role === "admin"` targets or give
  resets a lower cap. **Ship the app half first or together**, or resets fail
  once a session is over 5 minutes old. Needs a functions deploy. See Decide first #1.

### S2 — `ci.yml` actions are tag-pinned and the workflow has no `permissions:` block · low (hardening) · medium
- **Status (2026-10-07):** **DONE.** Top-level `permissions: contents: read`; all five actions SHA-pinned at the versions their tags resolve to today (no upgrades); the emulator step runs the lockfile-pinned CLI from `tools/deploy` instead of `npx --yes`.
- **Where:** `.github/workflows/ci.yml:21,26,69,82,87,104,113`; `:111` runs
  `npx --yes firebase-tools@15.32.1` with no lockfile.
- **Risk:** `ci.yml` is also the deploy's `verify` gate (`deploy.yml:89-96`). A
  compromised upstream tag (e.g. `subosito/flutter-action@v2`) could fake a
  green gate. This is mitigated: `verify` has `contents: read` and no
  `id-token`, so it cannot mint GCP credentials.
- **Fix:** SHA-pin like `deploy.yml`, add `permissions: {contents: read}`, and
  run the CLI from `tools/deploy`'s lockfile. No deploy needed.

### S3 — the repeatable-deploys plan documents a weaker WIF condition than prod runs · low (doc) · medium
- **Status (2026-10-07):** **DONE.** Plan's `--attribute-condition` now pins repo, environment, `refs/heads/main`, `workflow_dispatch` and the `deploy.yml` `workflow_ref`; step 4.1 adds the main-only environment branch policy. Source for the live condition: the deploy-workflow memory note (DEPLOYMENT.md states it only in prose).
- **Where:** `docs/plans/2026-10-06-repeatable-deploys.md:94-95,135` vs
  `docs/DEPLOYMENT.md:136-137`.
- **Risk:** the plan's provider condition is repo + environment only, with no
  environment branch policy. Live also pins ref=main, `workflow_dispatch` and
  `deploy.yml`'s `workflow_ref`. Rebuilding from the plan would leave the
  in-workflow `gate` job as the only branch check, and anyone with push access
  can edit that.
- **Fix:** correct the plan text to the live condition.

## 🟠 Bug findings (review required)

### B1 — the allowlist superset check can compare against a sha whose functions never went live · medium · confirmed
- **Status (2026-10-07):** **DONE.** `lastDeployedSha` keeps only rows whose Targets cell names `functions` or `all` and skips "no deploy" rows; returns `61811650` against the real log. One fixture's `f` targets became `functions`.
- **Where:** `functions/scripts/deploy/deploy_log.js:33-43` (`lastDeployedSha`),
  used by `.github/workflows/deploy.yml:167-172`.
- **Problem:** it returns the newest Deploy log row with a backticked sha,
  whatever that row deployed. The log already has indexes-only, rules-only and
  "backfills only (no deploy)" rows, and the workflow appends more. Scenario:
  functions deploy at S1, an allowlist key is removed in source, an
  indexes-only deploy logs S2, and the next functions deploy diffs against S2
  and reports nothing. Shipped builds that still send the key then get
  `unexpected-field`, which is the breakage `security.md` and DEPLOYMENT §4a
  exist to stop. The workflow also reads the log from `main`, while new rows
  land via PRs to `dev`, so the base can lag further.
- **Fix:** accept only rows whose Targets cell contains `functions` (or
  `all`), skip "no deploy" rows, and add a test with a trailing indexes-only
  row. No deploy needed (CI tooling).

### B2 — kill-switch booleans parse differently in the app and in functions, and a malformed value fails CLOSED · medium · confirmed
- **Status (2026-10-07):** **DONE — needs functions deploy + app build.** Owner chose strict `true`/`false`. Both sides read the raw string: case-insensitive, trimmed `true`/`false` only, anything else takes the code default (ON). 19 bool + 12 int cases in the shared fixture, read by both suites. (Deviated: `min_supported_build` also tightened to a plain integer on both sides — functions' `getNumber` accepted `1.5`/`1e3`/`0x10`/empty and the app's `asInt` accepted `0x10`; anything else now reads 0 on both.) Runbook Values line updated.
- **Where:** `lib/core/remote_config/feature_flags.dart:20` (`v.asBool()`: true
  only for `true`/`1`); functions use admin `getBoolean` (truthy set
  `1,true,t,yes,y,on`); `test/fixtures/shared/feature_flags.json` pins only
  defaults.
- **Problem:** a parameter set to `yes`/`on` reads ON in functions and OFF in
  the app. Any typo or empty string reads OFF on both sides, so a fat-fingered
  publish pauses a feature, contrary to "kill switches FAIL OPEN". The runbook
  misstatement is corrected in this pass; the behaviour is not.
- **Fix:** see Decide first #2. If (a): in both readers, treat anything other
  than case-insensitive `true`/`false` as the code default, and add parse cases
  to the shared fixture so both suites pin them. App + functions deploy.

### B3 — pausing address autocomplete leaves reverse-geocode and stale-suggestion taps calling the refused callables · low-medium · 85 %
- **Status (2026-10-07):** **DONE (app build).** `reverseGeocodeProvider` returns null without calling while paused (watched via `.select`, so a re-enable re-resolves); the field clears suggestions on flip (`ref.listen`) and `_selectSuggestion` fills the suggestion's own text instead of calling `getPlaceDetails`. (Deviated: no `_suppressFetch` on the paused tap, which would swallow the next keystroke.) The optional breadcrumb-instead-of-warn was not done: no client call reaches that path while paused any more.
- **Where:** `lib/features/maps/application/maps_providers.dart`
  (`reverseGeocodeProvider`, no flag read);
  `lib/features/maps/data/google_places_repository.dart:85,157`;
  `lib/shared/widgets/fields/address_autocomplete_field.dart` (`_selectSuggestion`).
- **Problem:** the server gates all three Places callables. The client gates
  only typing. While paused, the live-map roster
  (`live_map_team_sheet.dart:279`) and `staff_focus_panel.dart:36` call
  `placesReverseGeocode` per staff row. Each refusal logs
  `ADDR-PLACES … failed` as a Crashlytics non-fatal: about one per row every 5
  minutes with the map open, for a deliberate operator state. Suggestions
  already on screen when the flag flips stay tappable, and a tap shows
  "couldn't load address details" and files another non-fatal.
- **Fix:** return null early from `reverseGeocodeProvider` while the flag is
  off, check the flag in `_selectSuggestion`, and clear suggestions on flip.
  Optionally breadcrumb instead of warn on `feature-disabled`. App only.

### B4 — dismissing the edit sheet mid-reset throws away the only copy of the new password · low-medium · 85 %
- **Status (2026-10-07):** **DONE (deviated — `PopScope` cannot veto a modal bottom sheet's drag-dismiss in Flutter 3.47.2, whose `onClosing` calls `Navigator.pop` directly).** The root navigator is captured before the await and the credentials dialog is shown through it if the sheet unmounted. Test fails with the branch disabled.
- **Where:** `lib/features/employees/widgets/sheets/edit_person_sheet.dart:363-395`
  (`if (!mounted) return;` at ~380).
- **Problem:** the sheet is a plain `showModalBottomSheet`, and `isBusy` only
  disables Cancel, so a swipe or barrier tap still dismisses it. By then the
  server has rotated the password, set the flag and revoked tokens. The
  credentials are dropped and the employee is locked out until a second reset,
  which costs another rate-limit slot. Nothing tells the admin.
  (`invite_person_sheet.dart:151` has the same shape, but there the pending
  account stays listed and can be acted on again.)
- **Fix:** block dismissal while `isResettingPassword`, or show the dialog from
  a root-navigator context captured before the await. App only.

### B5 — a failed App Store launch on the forced-update screen shows nothing · low · 80 %
- **Status (2026-10-07):** **DONE.** `UpdateRequiredScreen` is stateful; a `false` from `launchExternalUri` shows an inline error line (`error_somethingWentWrongPleaseTryAgain`, no new key). Two tests.
- **Where:** `lib/main.dart:~432` (`UpdateGate` replaces `AppLock →
  NoticeListener → Navigator`); `lib/core/remote_config/update_required_screen.dart:40-47`.
- **Problem:** `launchExternalUri` reports failure through `notices.error`, but
  no `NoticeListener` or overlay is mounted while the gate is up. The only way
  forward fails silently (it is logged).
- **Fix:** surface the failure inline, or via `ScaffoldMessenger.of(context)`,
  which sits above `builder`. Add one tap/failure test to `update_gate_test.dart`.

### B6 — `endLiveActivity` deletes the token while paused, against "never prune while paused" · low · confirmed
- **Status (2026-10-07):** **DONE — needs functions deploy.** Owner chose keep. `endLiveActivity` returns before any send, token delete or marker clear while paused. Two tests in `live_activity_feature_flag.test.js`.
- **Where:** `functions/live_activity_dispatch.js:324-340`.
- **Problem:** `_sendToRow` returns 0 without sending while
  `feature_live_activities` is off, but `endLiveActivity` then calls
  `deleteActivityToken` (and `clearCardMarker`) anyway. A job cancelled during a
  pause loses its end push and its token. Current builds end cards locally on
  pause (`e6d83d49`), so only older builds' cards linger until iOS stales them.
- **Fix:** see Decide first #3. If keeping: return before the delete loop when
  paused. Functions deploy.

### B7 — the ChangePassword "Log out" path skips the analytics teardown · low · high
- **Status (2026-10-07):** **DONE.** `_signOutToLogin` calls `logSignOut()` + `setUserRole(null)` after `signOut()` succeeds, the provider hoisted before the awaits; the test asserts both calls.
- **Where:** `lib/features/auth/screens/change_password_screen.dart:183-205`
  vs `lib/features/settings/widgets/views/delete_account_flow.dart:72-74`.
- **Problem:** no `analytics.logSignOut()` / `setUserRole(null)`, so events
  logged after sign-out still carry the old `user_role`.
- **Fix:** add the two calls and an assertion in the existing "Log out tears
  the device down" test. App only.

### B8 — `allowlist_diff.js` silently skips a base file it failed to read · low · medium
- **Status (2026-10-07):** **DONE.** `base.read` returns null only for a file absent from the `ls-tree` listing and rethrows otherwise, so `main` exits 1. (Deviated: `gitTrees`/`main` take an injectable git runner, defaulting to the real one, to test without git.)
- **Where:** `functions/scripts/deploy/allowlist_diff.js` (`gitTrees().base.read`
  swallows every `git show` error as `null`; `compareTrees` ~:118 `continue`s
  on `null`).
- **Problem:** a file `ls-tree` listed but `show` failed on is skipped, and the
  deploy gate passes when it should have checked.
- **Fix:** return `null` only for files absent from `base.list()`, rethrow
  otherwise, and add a test that `main` returns 1 on a git failure.

## 🔵 Areas to improve (review required)

### I1 — the bridge backfill's delete path is untested · medium · high
- **Status (2026-10-07):** **DONE.** Extracted `reconcileBridges(db, {dryRun, pruneOrphans})` from `main()` (output and the `run.js` count line unchanged); 4 tests: dry run writes nothing, no prune flag keeps the orphan, `--prune-orphans` deletes it, a uid claimed by a skipped doc is retained.
- **Where:** `functions/scripts/backfill.js` `main()` (~:83-235, 13 % lines).
- **Opportunity:** this is the only script that deletes (`--prune-orphans`
  removes `usersByUid` rows every rules gate resolves through). Neither the
  dry-run gate nor the prune-off-by-default branch has a test; every other
  write backfill has its "dry run writes nothing" test.
- **Suggested improvement:** two tests, mirroring the other backfills: a dry run
  writes nothing, and without `--prune-orphans` an orphan is reported but not
  deleted.

### I2 — no-op full-width button styles at 10 sites · low · high
- **Status (2026-10-07):** **DONE.** All ten no-op sizes removed; `destructiveOutlinedButtonStyle` with a null size inherits the theme's identical one.
- **Where:** the theme already sets the size (`themes.dart:162/177`, `:345/:360`).
  Six sites pass `OutlinedButton.styleFrom(minimumSize: Size(double.infinity, 48))`
  and nothing else: `details_action_bar.dart:85,101,165`,
  `add_client_sheet.dart:424`, `client_detail_view.dart:117`,
  `edit_person_sheet.dart:681`. Four pass the same size into
  `destructiveOutlinedButtonStyle`: `details_action_bar.dart:204`,
  `details_edit_body.dart:556`, `client_detail_view.dart:136`,
  `edit_person_sheet.dart:692`.
- **Suggested improvement:** delete the no-op `style:`s on touch. No new helper.
  (Leave `details_action_bar.dart:129,177`, which carry real overrides.)

### I3 — `employee_accounts.js` grew to 808 lines · low · high
- **Status (2026-10-07):** **DONE** (`2641c3e5`). Pure move into `employee_accounts_admin.js` (create/delete/reset) and `employee_accounts_self.js` (setup/complete-reset/email change); same 32 exports, 2237/2237 jest, gate mocks proved non-vacuous. **Not deployed:** the next functions deploy runs `allowlist_diff.js` against a base that still has `employee_accounts.js`, so it prints six "renamed or deleted? Check it by hand" lines and exits 0 — the six allowlists were hand-checked identical (no key removed); the check is per-file again once that deploy moves the base sha.
- **Opportunity:** the natural seam is admin create/reset/delete vs
  self-service setup/complete-reset/email. Other functions modules over 600
  lines: `notification_utils.js` 712, `wave/customers.js` 639,
  `travel_utils.js` 616.
- **Suggested improvement:** split on next touch along the existing
  `*_policy.js` / module line; the export set must not change.

### I4 — long `build()`s and god files (split on touch) · low · high
- **Status (2026-10-07):** **PARTLY DONE** (`228b0782`): the six named `build()`s split via private builder methods (clients_screen 137→49, details_view_body 143→66, notice_listener 124→41, employee_picker 109→56, live_map_team_sheet 93→30, main 87→51). The other ~57 long builds and the god files stay split-on-touch.
- 63 of 383 `build()`s exceed ~60 lines. Changed this window:
  `clients_screen.dart:139` (137 lines; seams: header row :189-215, list stack
  :220-260, FAB), `live_map_team_sheet.dart:45` (93), `main.dart:366` (87,
  `MaterialApp` builder nesting). Largest overall:
  `details_view_body.dart:69` (143), `notice_listener.dart:195` (124),
  `employee_picker.dart:53` (109). Largest files:
  `firebase_appointments_repository.dart` 1021 (+99),
  `event_details_controller.dart` 839, `main_calendar_screen.dart` 789,
  `edit_person_sheet.dart` 720 (+81).

### I5 — multi-line comment backlog against the one-line rule · low · high
- **Status (2026-10-07):** **PARTLY DONE** (`6f947913`): the six named files trimmed, comment-only diff; 12 unrecorded reasons moved first into `employees.md`, `notifications.md`, `images.md`, `appointments.md` and root `CLAUDE.md`. The rest of the backlog stays trim-on-touch; overlaps the not-started rules-docs cut-down plan.
- About 6,000 lines sit in consecutive `//`/`///` blocks of 2+ lines across
  `lib/`. Worst among files changed this window:
  `employee_form_controller.dart` (87 lines; blocks at 118 and 202),
  `employees_repository.dart` (65), `live_activity_registration_controller.dart`
  (61), `edit_person_sheet.dart` (48), `sign_in_controller.dart` (42),
  `firebase_appointments_repository.dart` (42).
- **Suggested improvement:** trim on touch, moving any unrecorded WHY into the
  rules files first. Don't do it as a mechanical sweep, because many blocks are
  the only record of a reason. This overlaps the not-started
  `2026-10-06-rules-docs-cut-down.md`.

### I6 — `UpdateGate` keeps `AppSyncListeners` running behind the blocking screen · low · medium
- **Status (2026-10-07):** **DONE (owner chose document).** `docs/DEPLOYMENT.md` kill-switch notes now say the update screen blocks the UI only and is not a fence against a backend-incompatible build.
- **Where:** `lib/main.dart` builder.
- **Opportunity:** presence uploads and the other sync listeners keep running
  while the user is told the build is unsupported. This is fine unless
  `min_supported_build` is ever used to fence off a backend-incompatible build;
  if it is, those listeners are exactly the writes to stop.
- **Suggested improvement:** decide whether the gate should also pause sync. If
  not, note it in the kill-switch runbook so nobody assumes it does.

## 🟡 Code-quality suggestions (optional)

Status 2026-10-07: Android FCM key **DONE** (removed with its test pin; needs a functions deploy to matter, harmless otherwise); `VALID_ROLES`/`digitsOnly` exports **DONE**; `appointment_image_ids.js` **KEPT** as the parity pin; durations **LEFT** (half-tokenizing a pair reads worse).

- `functions/notification_utils.js:168` — `android: {priority: "high"}` plus an
  Android doze comment in the FCM message. An Android remnant on an iOS-only
  fleet; drop it on next touch after checking what tests pin. (Confidence 0.6.)
- `functions/bridge_policy.js:104` `VALID_ROLES` and `functions/search_tokens.js`
  `digitsOnly` are exported with zero external readers; drop them from
  `module.exports` on next touch.
- `functions/appointment_image_ids.js` is test-only (the hand-mirrored parity
  anchor for `appointment_image_doc_id.dart`). Keep it as the pin, or delete it
  together with its two tests if the pin is no longer wanted.
- `lib/features/calendar/widgets/dialogs/image_viewer.dart:32-33` and
  `overdue_review_screen.dart:159` — raw 250/200 ms durations next to
  `AppDuration.normal`/`popIn`. Only the 250 is an unambiguous match, and
  half-tokenizing a pair reads worse, so it was left alone.

## Checked and sound

- **Security:** S1–S4 of 2026-09-28 have not regressed. `passwordResetRequired`
  is in both `/users` denylists and only written server-side in transactions.
  Every callable enforces App Check. Admin callables open with
  `assertAdminCall`; self-service with `assertActiveCall` or the documented
  explicit guards. Credential fields all pass
  `kCredentialImePersonalizedLearning`. `deploy.yml` routes `notes` through
  `env:` (no script injection), choice-typed targets, a validated `ref`,
  top-level `permissions: {}`, SHA-pinned actions and a `--force` guard.
  `run.js` resolves only through a fixed registry and spawns without a shell.
- **Kill switches:** the functions flag cache never throws, keeps last-good and
  shares one load. Flag gates run before rate limiters. App watchers use
  `.select` and `RemoteConfigService` dedups emits, so the root doesn't rebuild
  on unrelated template pushes. `UpdateGate` fails open on an unparsable build.
- **Performance:** I1, I2 and I5 of 2026-09-28 hold. No leaked
  subscriptions/controllers in the new UI.
- **Dead code:** no Dart file without an inbound import, no unreferenced public
  symbol, no orphaned ARB key (924/924 EN/FR, all used), no BOMs, no
  unsanctioned SnackBars, no `throw Exception(`. The scan's unused-dependency
  hits are false positives: `google_maps_flutter_ios_sdk9` is the commented
  federated override, `integration_test/` exists, and `build_runner`,
  `freezed` and `flutter_launcher_icons` are tooling.

## Notes / uncertainties

- The Firebase MCP server did not connect. The live function list and index
  states came from `firebase functions:list` and
  `gcloud firestore indexes composite list` (read-only).
- B3's non-fatal rate is estimated from the 5-minute failure cooldown, not
  observed in Crashlytics, so check Crashlytics for `ADDR-PLACES` after a real
  pause.
- B6 and I6 depend on how the switches will actually be used. They are listed
  so the choice is deliberate.
