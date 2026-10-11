# Codebase Audit — 2026-10-09

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`.github/workflows/`, `test/`). Baseline: `dev` @ `af97733f`, clean tree.
Emphasis on the 42 commits since the 2026-10-07 audit baseline
(`6a19ff6a..HEAD`, 148 files in `lib/`+`functions/`+rules), above all
`af97733f` (undeployed): pre-1.63 compat retirement, `updateFieldNotes` and
`waveSetImportSchedule` deleted, History admin-only, the assignee parent rule
narrowed, `placesAutocomplete` street/city lines, and 60 `build()` splits.

## Summary

- Scanned: 488 Dart files in `lib/`, 408 in `test/`, 209 JS files in
  `functions/`, both rules files, both workflows.
- Auto-fixed (safe, in the diff): 0. `dart fix` had nothing to fix, the
  analyzer was clean, and every dead-code candidate turned out referenced or
  intentionally kept.
- Reported for your decision: 6 (⚠️ 0 pre-ship · 🔴 1 security · 🟠 1 bug ·
  🔵 4 improvements), plus one deploy step.
- Verification: `flutter analyze` **No issues found!** · `dart fix --dry-run`
  Nothing to fix · functions lint clean · `dart run tool/test.dart`
  **4053 passed** · functions jest **2220/2220** (106 suites). The bug reviewer
  ran the test suites at `af97733f`. This pass made no source edits, so those
  runs cover the tree as it stands.
- **Compat check of `af97733f` against the 1.63.0+93 fleet (`cc38be5d`):**
  safe to deploy. No 1.63 phone calls `waveSetImportSchedule` or
  `updateFieldNotes`. It always sends `newPassword`, and its History route is
  `AdminOnly` with `employeeId: null`. Its photo touches write only
  `updatedAt`, which the narrowed rule still allows. Its `AddressSuggestion`
  ignores the added fields. `employeeId` stays in the allowlist as
  `#compat-1.63.0`, so no allowlist key was dropped.

## Decide first

**Decided 2026-10-09 (owner):** S1 "older of both", implemented as check-both (see S1). B1 is left for the owner (prod backfill).

**Implement pass (2026-10-09):** `flutter analyze` No issues found! · `dart run tool/test.dart` **4053/4053** · functions lint clean · jest **2222/2222** (106 suites). Result: 3 done (S1 deviated, B2 new, I3), 2 not a defect (I1, I2), 1 no action (I4), 1 open (B1).

1. **S1:** should the deploy workflow's allowlist base keep coming from
   `origin/dev`? See S1 for the options.
2. **B1:** re-run `backfill-search-tokens.js` after the backend deploy? It is
   optional, it is a prod backfill, and it is never auto-run.

## Auto-applied cleanups (review the diff)

None. `git diff` is empty apart from this report.

## ⚠️ Pre-ship checklist

None: there are zero `TODO(pre-ship)`/TODO/FIXME/HACK markers in `lib/`,
`test/` and `functions/`.

**Before the next backend deploy** (not pre-ship, but it blocks the workflow):

- [ ] Run `firebase functions:delete waveSetImportSchedule --region us-central1`
  from the owner's shell first. `export_diff.js` aborts a deploy that would
  delete a function. See ADR-0184 and `.claude/rules/wave.md`.

## 🔴 Security findings (review required)

### S1 — the allowlist superset check takes its base sha from `origin/dev` · low · confidence 85 %

- **Status (2026-10-09):** **DONE (deviated: checks against BOTH bases, not the older one).** The owner picked "older of both", but an older base misses a key that was added in a deployed commit main's log doesn't list yet, which is exactly the lag that dev's copy covers. `deploy.yml` now runs `allowlist_diff.js` against main's and dev's last-deploy sha (deduped) and fails if either fails. A dev push can't weaken it, and main lagging can't either. Dry-run under `bash -e`: exit 0.

- **Where:** `.github/workflows/deploy.yml:167-169`
- **Risk:** the step reads `docs/DEPLOYMENT.md` from `origin/dev`, on purpose
  because deploy-log rows land on `dev` first, and uses its last-deploy sha as
  the base for `allowlist_diff.js`. Anyone who can push to `dev` can move that
  sha to a commit whose allowlists already match `main`. The check then passes
  a key removal that throws `unexpected-field` on every stale phone. The
  impact is availability only. It needs repo write access, and the
  `production` approval is still a human tap.
- **Fix (pick one):** (a) read only `main`'s deploy log and accept the lag;
  (b) read both and fail, or use the older sha, when they disagree; (c) leave
  it and document the trust assumption in `docs/DEPLOYMENT.md` §4a. No deploy
  is needed for any of these.

## 🟠 Bug findings (review required)

### B1 — appointments indexed before `af97733f` keep a reduced `all:` token set · low · confidence 85 %

- **Status:** **OPEN — needs a prod backfill** (after the backend deploy and once 1.64 is on every phone).

- **Where:** `functions/search_tokens.js:153` / `lib/core/search/search_tokens.dart:67`
  (new writer); old docs in prod
- **Problem:** before `af97733f`, the 240-entry `historySearchScopes` budget
  was split across `all:` and one `emp:<id>:` scope per assignee. On an old
  multi-assignee job, an admin History search can therefore miss a late-listed
  term until the doc is next written. It is not a regression, since admin
  search read the same `all:` set before. The dead `emp:` entries also linger.
  Docs saved by 1.63 phones keep writing the split budget until 1.64 ships.
- **Fix:** after the backend deploy and once 1.64 is on every phone, run
  `node functions/scripts/run.js backfill-search-tokens` (dry run first, then
  `--live`). ADR-0187 already names it as the optional cleanup.

### B2 — the allowlist check went blind for the six callables the module split moved · low · confirmed

Found during the implement pass, while dry-running S1.

- **Where:** `functions/scripts/deploy/allowlist_diff.js` (`compareTrees`)
- **Problem:** owners were matched only within the same file path. `2641c3e5` moved six callables from `employee_accounts.js` to `employee_accounts_{admin,self}.js`, so a check against the last deploy (`364d4812`) only WARNED "not found now" for all six. A removed key on any of them would have passed the deploy gate.
- **Status:** **DONE.** A vanished owner is now looked up by name across the HEAD files and compared when exactly one file defines it; ambiguous names stay warnings. HEAD files are parsed too, so an unreadable allowlist in a new file now fails loudly as well. Two jest cases added. Against `364d4812` only the really-deleted `waveSetImportSchedule` still warns. Mutation check: dropping `"email"` from `changeEmployeeEmail` now exits 1 with an error.

## 🔵 Areas to improve (review required)

### I1 — confirm the split widgets are still exercised by tests · medium · confidence 60 %

- **Status:** **NOT A DEFECT.** `dart run tool/test.dart --coverage` (4053 passed): all 12 files 76–100 % line coverage (`availability_panel` lowest at 76 %, `auth_scaffold`/`info_card`/`tour_action_button`/`business_trends_section`/`client_name_phone_lift` 100 %), reached through parent screen tests.

- **Where:** `auth_scaffold`, `client_name_phone_lift`,
  `business_trends_section`, `employee_workload_section`,
  `new_clients_section`, `availability_panel`, `tour_action_button`,
  `live_map_team_sheet`, `staff_focus_panel`, `appearance_settings_card`,
  `info_card`, `list_item_tile`
- **Opportunity:** these were reshaped by `af97733f`/`228b0782`, and no test
  file names them. Most are probably pumped through a screen test, for
  example `dashboard_screen_test.dart`, which gained 260 px / 2x coverage in
  `8d296a04`. The bug reviewer read every changed line of the split and found
  no behaviour change, so this is regression insurance, not a defect.
- **Suggested improvement:** run `dart run tool/test.dart --coverage` and add a
  `_harness` 260 px / 2x case only for a file with zero line hits. Start with
  `live_map_team_sheet` (211 lines changed) and `staff_focus_panel`.

### I2 — the `purgeExpiredHistory` trigger loop is untested · low-medium · confidence 70 %

- **Status:** **NOT A DEFECT.** The page loop already IS `maintenance_policy.runHistoryPurge` with injected `db`/`deleteImages`, and `maintenance_policy.test.js:121-198` pins images-first, keep-on-failure, and the empty / short / no-progress-full-page stops. The uncovered 33 % of `maintenance.js` is the `onSchedule`/`onObjectFinalized` registration and the `deleteAppointmentImages` try/catch wrapper.

- **Where:** `functions/maintenance.js` (33 % line coverage)
- **Opportunity:** the decisions live in `maintenance_policy.js`, which is
  tested (ADR-0029). The glue that applies them is not: images first, keep the
  doc on an image failure, stop on a no-progress full page. This is the one
  unattended deleter.
- **Suggested improvement:** extract the page loop into the policy module with
  injected `db`/`bucket`, as ADR-0029 prescribes for new decisions, and add
  one test per invariant.

### I3 — multi-line comment backlog (2026-10-07 I5, still open) · low · confidence high

- **Status:** **DONE.** All 48 blocks of 5+ lines in `lib/` are now one line (38 files, +48/−316; re-scan finds 0). The comments-only claim was checked with a filtered diff: no non-comment line changed. Facts that weren't recorded anywhere went into rules: root `CLAUDE.md` (app-lock session release), `images.md`, `firestore-indexes.md`, `clients.md`, `employees.md` (3), `notifications.md` (2). No new ADRs, so 0189 is still next. The 2-4 line blocks stay trim-on-touch.

- **Where:** 617 `//` blocks of 2+ lines in `lib/`: 337 ×2, 173 ×3, 59 ×4,
  26 ×5, 12 ×6-7, 10 ×8+. The longest are
  `employee_schedule_providers.dart:122` (15), `app_palette.dart:72` (14),
  `app_dialog_frame.dart:37` (11), `app_routes.dart:74` (11),
  `employee_details_view.dart:60` (10) and
  `details_view_leaf_widgets.dart:303` (10).
- **Suggested improvement:** a dedicated trim pass over the ~48 blocks of 5+
  lines. Move each reason to the scoped rules file or an ADR first, keeping at
  most one clause inline. Leave the 2-3 line blocks to trim-on-touch.

### I4 — large files (split on touch, no action now) · low · confidence high

- **Status:** **NO ACTION (by design)**, split on touch.

- **Where:** `firebase_appointments_repository.dart` 912 (down from 1021),
  `event_details_controller.dart` 839, `main_calendar_screen.dart` 794,
  `details_view_body.dart` 772, `appointment_card.dart` 725;
  `functions/notification_utils.js` 709, `wave/customers.js` 639.
- **Opportunity:** all are cohesive. `details_view_body` and `appointment_card`
  grew because the split's helper methods moved in. Only one `build()` is over
  60 lines: `new_clients_section.dart:213` at 61, already accepted. Keep the
  split-on-touch stance.

## 🟡 Code-quality suggestions (optional)

None. The three `errorSnackBar` sites are the sanctioned carve-outs
(`frontend.md:67`). There is no `throw Exception(`, no stray
`FirebaseFirestore.instance`, no hand-spelled email normalization, no
`Color(0x…)` outside the theme, no BOMs and no import-order drift.

## Checked and sound

- **Security:** App Check is on all 20 callables, including both
  `employee_accounts_*` modules. Guard order holds: admin `assertAdminCall` →
  validation → `assertFreshReauth` where applicable → durable limit;
  self-service `assertActiveCall`, `findAppointmentConflicts` keeps
  `scope-denied`. `2641c3e5` is a pure move (sorted-line diff empty).
  `3000b7e4` and the assignee rule narrowing only tighten.
  `setupRequiresPassword` stays on both `/users` denylists. All four password
  fields set `kCredentialImePersonalizedLearning`. Workflows are SHA-pinned
  with least-privilege `permissions`.
- **Bugs:** the bug reviewer isolated the ~1,300 lines in the 60-method split
  that changed rather than moved, and read every one. No key, branch, callback,
  `context` or l10n key was lost. `d93b50f7`/`6f947913` are comment-only.
  Every raw `Stream.listen` has `onError`. The Dart/JS `appointmentHistoryScopes`
  mirrors match.
- **Performance:** the splits are builder methods on the same State/widget, so
  no new Element boundaries. No `ref.watch` widened, no `const` lost. History
  search dropped from N per-scope windows to one (fewer reads). Every
  controller, subscription and Debouncer in changed files is disposed.
- **Dead code:** no orphans from the retirements. EN/FR ARB key sets are
  identical and every key is used. No Dart file lacks an importer, no
  declared-only symbol or provider exists, and the log-tag registry matches the
  code. The scan's unused-dependency hits are the known false positives
  (`google_maps_flutter_ios_sdk9` override, `integration_test`,
  `build_runner`, `freezed`, `flutter_launcher_icons`).
- **CI:** the emulator rules checks (`safety_checks.js`) do run in CI, via
  `storage_rules.smoke.js:165` from `ci.yml:122`.

## Notes / uncertainties

- `placesAutocomplete` now returns `text`, `structuredFormat` and
  `mainText`/`secondaryText` (2-3× bytes on ≤5 entries). This is negligible
  and left alone.
- The maintainability reviewer's `mounted`/`isSubmitting` sweep was
  window-limited (13 hits, 3 read). The bug reviewer's targeted checks found
  no defects, but this is not an exhaustive proof.
- The live backend was not queried this pass. Its function list and index
  states are as of the 2026-10-07 deploy (32 deployed, 31 defined after
  `af97733f`).
