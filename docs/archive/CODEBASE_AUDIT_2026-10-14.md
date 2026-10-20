# Codebase Audit — 2026-10-14

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`.github/workflows/`, `tools/deploy/`, `test/`). Baseline: `dev` @ `d6e19618`,
clean tree. Emphasis on the 18 commits since the 2026-10-09 baseline
(`af97733f..HEAD`): 46 files, +149/−428, almost all comment trims. Code changed
in only `places.js`, `allowlist_diff.js` (+ their tests), `address_suggestion.dart`,
`tour_action_button.dart` and `tour_showcase.dart`, plus the Dependabot bumps
(setup-node 7.1.0, firebase-tools 15.33.0 in `tools/deploy`).

## Summary

- Scanned: 488 Dart files in `lib/`, 405 in `test/`, `functions/` (non-test
  modules + 106 jest suites), both rules files, the workflows.
- Auto-fixed (safe, in the diff): 0. The analyzer is clean, `dart fix` has
  nothing to fix, functions lint is clean, and every dead-code candidate is
  referenced or a deliberate test pin.
- Reported for your decision: 5 (⚠️ 0 pre-ship · 🔴 1 security, informational ·
  🟠 2 bugs, both low · 🔵 2 improvements, both low).
- Verification: `flutter analyze` **No issues found!** · `dart fix --dry-run`
  Nothing to fix · functions lint clean · `dart run tool/test.dart` **4055
  passed** · functions jest **2219/2219** (106 suites). This pass made no
  source edits, so those runs cover the tree as it stands.
- Carried open from 2026-10-09: **B1** (optional `backfill-search-tokens`
  prod backfill). Not re-filed here.

## Decide first

**Implement pass (2026-10-14):** `flutter analyze` No issues found! · `dart run tool/test.dart` **4061 passed** · functions lint clean · jest **2220/2220** (106 suites). Result: 2 done (B1, B2), 1 done with half not-a-defect (I1), 2 no action (S1, I2). B1 waits on the next backend deploy. B2 was implemented under the bare "do all".

1. **B2:** add a resume refresh to `currentDayProvider`? It is a cheap
   hardening, but the failure it guards against is device-unverified.

Everything else is low, local and test-backed, so "do all" can cover it.

## Auto-applied cleanups (review the diff)

None. `git diff` is empty apart from this report.

## ⚠️ Pre-ship checklist

None: zero `TODO(pre-ship)`/TODO/FIXME/HACK/XXX markers in `lib/` and
`functions/`.

## 🔴 Security findings (review required)

### S1 — `braces` advisory under firebase-tools in `tools/deploy` · low · confidence it is exploitable <10 %

- **Status:** **NO ACTION (by design)** — wait for the upstream firebase-tools bump; never `audit fix --force`.

- **Where:** `tools/deploy/package-lock.json` (firebase-tools 15.33.0 →
  chokidar → braces, GHSA-vfj7-8cjw-p6xm; `npm audit` shows it as 3 "high").
- **Risk:** stack exhaustion on deeply nested glob patterns. Not reachable: the
  CLI runs only in the deploy job, takes no attacker-controlled glob, and is
  installed with `--ignore-scripts` before any credential exists.
  `functions/` `npm audit --omit=dev` is 0.
- **Fix:** none now. **Do not** run `npm audit fix --force`, which downgrades to
  firebase-tools 6.8.0. Take the upstream bump when Dependabot offers it.

## 🟠 Bug findings (review required)

### B1 — `runHistoryPurge` re-counts and re-retries image-failed docs on every page · low · confidence 90 %

- **Status (2026-10-14):** **DONE.** `runHistoryPurge` counts failures in a `Set` of doc ids (`imageFailures: failedIds.size`); the per-page retry is unchanged. New jest case "counts a stuck doc refetched on a later page once" failed first (2 vs 1), passes now. **OPEN — takes effect with the next backend deploy** (not run).

- **Where:** `functions/maintenance_policy.js:146-178`
- **Problem:** the loop has no cursor and relies on deleted docs dropping out
  of the query. A doc whose image cleanup failed is kept, as designed, so it
  stays at the front of `.orderBy("startTime")`. On a full page (200) with k
  failures and at least one success, the next page fetches the same k docs
  again: `deleteImages` runs on them again and `imageFailures` grows by k
  again. The `purgeExpiredHistory: done` log over-reports failures by up to
  k × pages, and each page loses k slots. No data is lost and the loop is
  still bounded (no-progress break, 1800 s timeout). Existing tests
  (`maintenance_policy.test.js:121-198`) never pair a failure with a full page.
- **Fix:** count distinct failed ids (a `Set`, `imageFailures = failed.size`).
  Leave the per-page retry alone, since a transient failure may clear on
  retry. Add a jest case: a full page with 1 failure, then a short page →
  `imageFailures: 1`. Functions-only change, so it needs a deploy to matter, and
  it rides along with the next one.

### B2 — `currentDayProvider` has no resume refresh · low · confidence 60 %

- **Status (2026-10-14):** **DONE.** `currentDayProvider` now also holds an `AppLifecycleListener` and invalidates itself on a resume that crosses the day, via a new injectable `currentDayClockProvider` (same shape as `overdueReviewClockProvider`). Put in the provider rather than `AppSyncListeners`, which has no lifecycle hook and no dispose. `test/core/utils/current_day_provider_test.dart` (2 cases), mutation-checked: removing the resume branch fails the rollover case. `docs/ARCHITECTURE.md` line updated. The symptom itself is still device-only.

- **Where:** `lib/core/utils/current_day_provider.dart:13`
- **Problem:** the midnight `Timer` is the only thing that moves "today". Dart
  timers on iOS run on a monotonic clock that does not advance while the device
  sleeps. After an overnight lock the timer can fire late, so the calendar's
  today marker, the day-route "today" button and the off-screen mirrors
  (widget, Siri, drawer, roster) keep yesterday until it catches up. Nothing in
  `lib/` invalidates the provider on `AppLifecycleState.resumed`. Not
  verified on a device.
- **Fix:** in an existing resume listener (`AppSyncListeners` already owns
  app-wide lifecycle sync), call `ref.invalidate(currentDayProvider)` when
  `DateTime.now().dateOnly` differs from the held value. Add a unit test with an
  overridden clock. Verifying the symptom itself is device-only: lock overnight,
  open after midnight.

## 🔵 Areas to improve (review required)

### I1 — two logic files have no test of their own · low · confidence 60 %

- **Status (2026-10-14):** **DONE (half NOT A DEFECT).** `appointment_images_store.dart` is covered by 16 cases in `firebase_appointments_repository_images_test.dart` under the repository's name, so there was nothing to add. `buildDayRoute` gained `test/features/calendar/domain/day_route_test.dart` (4 cases) for the two rules no screen test pinned: a stale admin pick falls back to the first assignee by name, and the roster → `employeeNames` → raw-id name fallback, plus kept-pick and technician cases.

- **Where:** `lib/features/calendar/domain/day_route.dart` (142 lines,
  `buildDayRoute`), `lib/features/calendar/data/appointment_images_store.dart`
  (92 lines).
- **Opportunity:** both are reached only through a screen test
  (`day_route_screen_test.dart`) or a controller test, so a regression shows
  up as a widget failure far from the cause. Every other logic file has a test,
  and `functions/` has no gaps.
- **Suggested improvement:** one small unit test file each, covering the
  ordering/edge cases of `buildDayRoute` and the store's add/remove. Skip it if
  you'd rather wait for a bug there.

### I2 — 2-4 line comment blocks (I3 follow-on) · low · confidence high

- **Status:** **NO ACTION (by design)** — trim-on-touch, as 2026-10-09 I3.

- **Where:** about 1,055 blocks of 2+ consecutive `//` lines, or 3+ `///`
  lines, across 310 files. The worst are `details_edit_body.dart` (21),
  `clients_list_view.dart` (15), `firebase_employees_repository.dart` (13),
  `add_client_sheet.dart` (12), `details_view_body.dart` (12) and
  `holidays.dart` (13 `///`).
- **Opportunity:** 2026-10-09 I3 cleared every 5+ line block and left these
  2-4 line blocks to trim-on-touch. That stance still holds, and none of these
  blocks are new since `af97733f` (that diff is net comment *removal*).
- **Suggested improvement:** none now. If you want it done in one go, it is the
  same deliberate pass as I3: move a reason to a rules file or ADR before
  cutting it. Never trim mechanically.

## 🟡 Code-quality suggestions (optional)

- `image_viewer.dart:224,323` (`Colors.white` on the dark viewer chrome) and
  `dashboard_hero.dart:98` (alpha-blended `Colors.black`). Both are
  intentional, with no token to map them to. Leave them.
- About 25 off-scale `EdgeInsets` literals (e.g. `appointment_card.dart:186`
  14/9, `appointment_form_fields.dart:672`). These are optical tuning with no
  matching `AppSpacing` token, so they aren't an auto-fix.

## Checked and sound

- **Security:** `enforceAppCheck: true` on all 20 `onCall`s, and there are no
  `onRequest`s. Guard order holds everywhere (`assertAdminCall` /
  `assertActiveCall` / the documented hand-opened three → payload →
  `assertFreshReauth` → durable limit). `assertActiveCall` spreads the auth uid
  last. Per-doc scoping holds: `mayRestore`, `findAppointmentConflicts`
  `scope-denied`, `resolveEmailChangeCaller`. `firestore.rules` and
  `storage.rules` are deny-by-default with the `/users` denylists on create and
  update, the TTL cap and the 4-value status allowlist. The S1 rework in
  `deploy.yml` is injection-safe: hex-only sha, `execFileSync`. The new
  setup-node pin is a SHA.
- **Bugs:** a comment-filtered diff of `af97733f..HEAD` confirms 38 files
  changed only comments. `address_suggestion.dart` now reads
  `structuredFormat.*.text` and has no compat gap: the deployed backend
  `0ab3f05c` never emitted the top-level fields, and the field has a fallback.
  The 48 px tour-button tap target keeps its semantics. All 12 raw
  `Stream.listen`s have `onError`. About 30 post-await `ref.read`/`setState`
  hits are all guarded or hoisted. The `isSubmitting` ordering is right in both
  appointment controllers. `pageToCap`, the 30-id chunking and the hand-mirrored
  Dart/JS pairs all check out.
- **Performance:** every `.snapshots()` is capped with a warn. Range providers
  are `autoDispose.family` with a 3 min grace and share one mirrors listener.
  There are no `ref.watch` calls in item builders, thumbnails decode at
  `cacheWidth`, and the functions sweeps are concurrent with caps. One known
  trade-off is left alone: the dashboard history refetch after the grace lapses
  (ADR-0059).
- **Maintainability:** no `build()` is over 60 lines (the longest are 61
  counting braces). The god files didn't grow. There is no 3+-site duplication
  worth a helper, and the only swallowed catches are the two documented carve-outs.
- **Dead code:** no BOMs, no `throw Exception(`, no stray
  `FirebaseFirestore.instance`, and only the 3 sanctioned SnackBar sites. EN/FR
  ARB sets are identical and every key is used. The log-tag registry matches the
  code both ways. `main.dart` is the only Dart file without an importer. Unused-dep
  hits are the known false positives (`build_runner`, `freezed`,
  `flutter_launcher_icons`, `very_good_analysis`,
  `google_maps_flutter_ios_sdk9`). There are no unreferenced `functions/`
  exports. Test-only pins (`monthGridMaxRows`, `allTourScopes`,
  `searchQueryTokens`, the mirrored pair) are kept on purpose.

## Notes / uncertainties

- Jest dropped from 2222 (2026-10-09) to 2219. That's expected: `85ce8329`
  removed four `places_response_shaping` tests with the server-side
  `mainText`/`secondaryText` step and added one pass-through test.
- `scripts/static_scan.sh`'s unused-file heuristic (one grep per file) didn't
  finish in 10 min on Windows and was stopped. The dead-code reviewer covered
  the same check in full, and the dependency heuristic was re-run by hand.
- B2's root cause, whether the Dart timer pauses during iOS device sleep, is
  platform behaviour this pass did not verify on a device.
- Static review only for rules: the emulator rules tests weren't run here
  (CI runs them), and the live backend and console password policy weren't
  queried.
