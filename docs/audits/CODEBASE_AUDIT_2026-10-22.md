# Codebase Audit — 2026-10-22

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`tools/deploy/`, `.github/workflows/`, `test/`). Baseline: `dev` @ `14a5da02`
(working tree had one pre-existing edit, `docs/deployment/last_verified_backend.json`,
left untouched). Emphasis on `a8072b6..14a5da02` (90 non-doc files): the
2026-10-20 audit implementation, release 1.66.0+98, FlutterFire 5 + FID push
targets (`21ee9644`, `6b995636`), functions dep bumps, the deploy preflight fix
(`d3a28d8f`).

## Implementation status (2026-10-22)

`/audit-do` the same day: 11 DONE (2 deviated: B1, B3), B2 reverted, Q2/Q3 kept, I6 watch-only, Q5 open for an owner call. Nothing needs a deploy or backfill. Verified 2026-10-22 on Windows: `flutter analyze` **No issues found!** · `dart run tool/test.dart` **4472 passed, 0 failed** (after the release review's B2 revert) · `tool/check_rules.dart` 0 violations · functions lint clean · jest **116 suites, 2394/2394** · no BOMs.

## Summary

- Scanned: `lib/`, `test/`, `functions/`, both rules files, the deploy tooling
  and workflows; five parallel reviewers (security, bugs, dead code /
  conventions, performance, maintainability / tests).
- Auto-fixed (safe, in the diff): 2 — one dead constant with its test, one
  stale rules-file pointer. Static layer was already clean: `flutter analyze`
  No issues found!, `dart fix` Nothing to fix!, functions lint clean, no
  zero-import file, the five unused-dependency hits are all false positives
  (see Notes).
- Reported for your decision: 14 (⚠️ 0 pre-ship · 🔴 0 security · 🟠 3 bugs ·
  🔵 6 improvements · 🟡 5 code-quality).
- Verification (after the fixes): `flutter analyze` **No issues found!** ·
  `flutter test test/core/validators/text_limits_test.dart` **16 passed**.

## Decide first

1. **Q2:** `searchQueryTokens` / `kSearchTokenQueryLimit` (Dart) are reachable
   only from tests — they are the Dart reader of a hand-mirrored shared
   fixture. Keep as the mirror (default; no change) or retire both sides.
2. **Q5:** 303 comment blocks over 4 lines in `lib/`, nearly all `///` API
   dartdoc. Does the 4-line cap in `code-quality.md` apply to dartdoc? Default
   for "do all": no sweep — owner call, not an implement-pass decision.

Everything else is local and test-backed, so "do all" can cover it. Nothing
needs a prod deploy or backfill.

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `lib/core/validators/text_limits.dart:47-54` | Removed `TextLimits.imageFileName` and its stale doc block | dead since 2026-10-20 Q2 deleted `composeFileName`/`uploadImage`; only the test read it. `firestore.rules`' `isBoundedString(fileName, 300)` stays |
| `test/core/validators/text_limits_test.dart:219-228` | Removed the `'an appointment photo fileName'` case | pinned the deleted constant |
| `.claude/rules/search.md:85` | `_mapRangeSnapshot` → `_warnAtRangeCap` | `_mapRangeSnapshot` was deleted in `a8072b6c`; the cap warn lives in `_warnAtRangeCap` |

> Full detail is in `git diff`. Nothing below this line was auto-changed.

## ⚠️ Pre-ship checklist

None. Zero `TODO(pre-ship)` markers in the tree.

## 🔴 Security findings

None at or above the confidence bar. See "Checked and sound".

## 🟠 Bug findings (review required)

### B1 — a forced exit blocked by the voluntary-teardown guard is lost for good · low-medium · confidence medium

**DONE (deviated — also moved `restoreThisDevice` inside the guard, around `auth.signOut()` in `signOutAfterPhotoCheck`, so a replayed forced exit can't race the restore; the old "forced exit during a voluntary teardown is ignored" test pinned the bug and was replaced).** `exitAccount` records a call blocked by a VOLUNTARY teardown; `runVoluntaryTeardown`'s `finally` replays it if still signed in. Tests: failed teardown → forced exit runs; successful sign-out → no replay.

- **Where:** `lib/core/app/account_exit_controller.dart:60-69` (`runVoluntaryTeardown`), `:83` (`exitAccount` early return); caller `lib/core/security/app_lock.dart:208-215`.
- **Problem:** while the lock overlay's Log out runs its teardown, `_isHandlingAccountExit` is held, so `exitAccount` returns immediately. Every `AccountExitListeners` signal is a transition (disabled false→true, role leaves admin, doc populated→empty) and never re-fires. If an admin disables the person mid-teardown and the voluntary path then fails (`signOut()` throws, or `isCurrentExit` turns false), the session stays signed in until the next cold start's `SplashScreen` gate. Before 2026-10-21 there was no guard, so the forced exit ran.
- **Fix:** have `exitAccount` record the blocked call (store the arguments as a pending closure) while a voluntary teardown holds the guard; in `runVoluntaryTeardown`'s `finally`, if the user is still signed in, replay it. Test in `account_exit_listeners_test.dart`: a voluntary teardown that throws while `exitAccount` is called → the forced exit runs afterwards.

### B2 — after a forced exit wins the guard, the lock overlay sits on top of the login screen · low · confidence medium

**NOT FIXED — reverted during the 1.66.1 release review.** The fix (release on any uid → null) let a bare Firebase Auth sign-out, which navigates nowhere, drop the overlay and show the hub without biometrics, and even a forced exit leaves a frame plus the route animation unlocked. The overlay over login (Unlock still works) is the lesser problem; `app_lock_test.dart` pins that losing the guard keeps the lock. A real fix would release only once the login route has finished pushing — reopen if wanted.

- **Where:** `lib/core/security/app_lock.dart:229-233` (`if (!signedOut && auth.currentUser != null) return;`).
- **Problem:** if a forced exit already holds the guard, `signOutAfterPhotoCheck` returns false while `currentUser` is still non-null (the forced exit is mid-teardown), so `_logOut` returns without `_release()`. The forced exit then pushes login UNDER the opaque overlay; the person must pass biometrics to reach a login screen. Not a trap (Unlock works) but wrong.
- **Fix:** release the overlay when the signed-in uid goes null — listen to `authUidProvider` in `AppLock` and call `_release()` on a transition to null. This covers every exit path, not just this one.

### B3 — text typed while a crew note is posting is wiped · low · confidence medium

**DONE (deviated — keyed on the draft store, not the controller, so a sheet dismissed mid-post keeps the new text; and only the text beyond the posted prefix stays, so nothing posts twice; both from the release review).** Test: `text typed while a note posts survives the post`.

- **Where:** `lib/features/calendar/widgets/views/details_field_record_view.dart:117-119`.
- **Problem:** the field stays editable during `appendFieldNote`; on success `drafts.clear(id)` and `_notes.clear()` wipe whatever was typed during the round trip, not just the posted text.
- **Fix:** clear only when the field still holds what was posted (`_notes.text.trim() == text`); otherwise keep the field and re-store the new draft. Widget test: type, tap Post, type more before the fake write completes → the extra text survives.

## 🔵 Areas to improve (review required)

### I1 — History-search cached-answer patching is production code with no direct test · impact medium-high · confidence high

**DONE.** New `test/features/calendar/data/appointment_history_scan_test.dart`, 25 cases. Real behaviour pinned where it differs from the list: a reopen + rename removes the record (terminal check runs first); a deleted doc is removed without dropping the answer. Observed, not changed: a brand-new doc inserted into the scan WINDOW keeps any `FieldValue` from its raw patch (the window is the functions-absent path, i.e. tests only).

- **Where:** `lib/features/calendar/data/appointment_history_scan.dart:130-172` (`_patchSearchResults`, `_movesSearchFields`, `_insertIndexFor`). Live because `searchHistory` caches through `_historyScan.results` (`firebase_appointments_repository.dart:856`).
- **Opportunity:** untested branches: a rename of `clientName`/`clientPhone`/`employeeNames` drops the cached answer; a newly terminal doc not in the answer drops it; a reopened doc is removed; `FieldValue` entries are skipped in the merge; `_insertIndexFor` keeps `startTime` DESC (including a null-`startTime` neighbour). A regression shows admins stale History results for up to 2 minutes with no test failing.
- **Suggested improvement:** a plain `test()` suite on `AppointmentHistoryScan` (it takes a query factory and a clock since 2026-10-21), about six cases.

### I2 — `signOutAfterPhotoCheck`'s two abort branches are untested · impact medium · confidence high

**DONE.** Two cases in `pending_photo_exit_test.dart` (built from mocktail deps directly, not `accountExitStubOverrides()`, which needs a `ProviderScope`); the session-change case fails with the `isCurrentExit` check removed.

- **Where:** `lib/core/app/pending_photo_exit.dart:107-150`.
- **Opportunity:** (a) `!devices.isCurrentExit` after `deregisterThisDevice` must NOT call `signOut` (zero test references to `isCurrentExit`); (b) `guard` returning false must return false and release the photo hold. These are the races the 10-21 refactor centralised for three callers.
- **Suggested improvement:** two cases in `test/core/app/pending_photo_exit_test.dart`: fence flipped during deregistration → `verifyNever(auth.signOut)`; `guard: (_) async => false` → false, hold released.

### I3 — the last two unchecked route-argument casts · impact medium · confidence high

**DONE.** Both use `_args<T>`; wrong-type tests added for each.

- **Where:** `lib/routes/app_routes.dart:71` (`settings.arguments as AccountSetupArgs?`), `:87` (`as DashboardArgs?`).
- **Opportunity:** ADR-0017 says type-check with `_args<T>`; a wrong-typed argument here throws `TypeError` instead of degrading. Dashboard is HOME, which is meant to fall back to least-privilege defaults. `forgotPassword` was fixed in the last pass; these two are what remain.
- **Suggested improvement:** `final args = _args<AccountSetupArgs>(settings);` and `_args<DashboardArgs>(settings)`; the `args?.x ?? default` reads already handle null. Add a wrong-type case for both to `app_routes_argument_validation_test.dart`. (Small behaviour change, a wrong type now degrades, so it's reported rather than auto-applied.)

### I4 — `deploy/preflight.js` `main()` and the target list are untested · impact low-medium · confidence high

**DONE.** `main(argv, io = {})` seam (`exec`/`write`, production defaults unchanged); 8 new cases in `functions/__tests__/deploy_preflight.test.js` incl. the `deploy.yml` options ↔ `plan()` parity check. Takes effect on the next deploy workflow run (script only, no backend change).

- **Where:** `functions/scripts/deploy/preflight.js:105-140`, `plan()` `:22-25`; `.github/workflows/deploy.yml:15-20` and `:155-158` spell the same targets.
- **Opportunity:** this script gates every prod deploy and broke `indexes`/`all` once. Untested: the identity-regex rejection, the stderr → `impersonation-unavailable` / `deployment-token-unavailable` mapping, the exit code and report write, and a partial grant filling `missing`. A new workflow target that `plan()` doesn't know aborts the deploy.
- **Suggested improvement:** one test that reads `deploy.yml`'s `options:` and asserts `plan()` accepts each, one partial-grant case, one `main()` case with an injected bad identity.

### I5 — `exitDevicesAfterPhotoCheck` carries a never-passed parameter · impact low · confidence high

**DONE.**

- **Where:** `lib/core/app/pending_photo_exit.dart:58-85`.
- **Opportunity:** its only caller is `delete_account_flow.dart:157`, which never passes `checkPendingPhotos`.
- **Suggested improvement:** drop the parameter; don't extract further (one caller, but it holds the release-on-bail-out logic).

### I6 — god files and long `build()` methods, watch only · impact low · confidence high

**OPEN — watch only, no action by design.**

- **Where:** `firebase_appointments_repository.dart` 1040 lines, `event_details_controller.dart` 883, `main_calendar_screen.dart` 856, `details_view_body.dart` 810; `build()` over 60: `clients_list_header.dart:19` (73), `notice_listener.dart:147` (69), `details_view_body.dart:218` (64), `appointment_image_carousel.dart:33` (62), `duplicate_phone_notice.dart:21` (61).
- **Opportunity:** none grew materially; no split warranted.
- **Suggested improvement:** none now. Extract one sub-widget from `clients_list_header` the next time it is touched; re-check a file that passes ~950 lines.

## 🟡 Code-quality suggestions (optional)

- **Q1** — **DONE** (removed from both ARBs, `gen-l10n` rerun). `lib/l10n/app_en.arb:1744` `applock_signedOut` is orphaned: its only call site (`app_lock.dart`'s `selectMessage`) went in `b53c23e4`. Delete from both ARBs with its `@` block. en/fr parity is otherwise exact and this is the only orphan.
- **Q2** — **KEPT (owner default 2026-10-22: stays as the fixture mirror).** `lib/core/search/search_tokens.dart:8` `searchQueryTokens` / `kSearchTokenQueryLimit`, test-only (hand-mirrored fixture reader). See Decide first.
- **Q3** — **KEPT** (documents the row rule's ceiling; no change). `lib/features/calendar/domain/month_grid.dart:5` `monthGridMaxRows` is read only by `month_grid_test.dart:17`. Keep as documentation of the row rule's ceiling or inline the 6 into the test (low).
- **Q4** — **DONE** (now 4 lines). `lib/core/app/pending_photo_exit.dart:95-100`: the one comment block over 4 lines added in this range (`signOutAfterPhotoCheck`). Drop the first paragraph, which restates the signature; keep the WHY.
- **Q5** — **OPEN — owner decision (default 2026-10-22: no sweep).** 303 pre-existing comment blocks over 4 lines, mostly API dartdoc (worst: `address_field_filler.dart:5` 29 lines, `calendar_day_circle.dart:106` 21, `:69` 20, `assignee_availability_scope.dart:8` 20, `dashboard_period.dart:24` 20, `address_parser.dart:153` 20, `top_route_observer.dart:3` 19). See Decide first.

## Checked and sound

- **FID push targets (`21ee9644`):** `firestore.rules:267-284` adds `kind` to `hasOnly` and bounds it to `'token'`/`'fid'`, every other constraint unchanged; `messageTargetFor` sends to the row's own id under the recipient's own `fcmTokens`, so a planted FID reaches only the planter's pushes; `installation-id-not-registered` prunes only the failing row; tested in `notification_utils.test.js`. No extra reads or sends per device. Inert until client step 2 writes `kind: "fid"`.
- **FlutterFire 5 (`6b995636`):** App Check still activated in `main()` (App Attest release, debug provider only under `kDebugMode`); deprecated FCM calls carry `// ignore:` directives only.
- **Deploy preflight (`d3a28d8f`):** only `pageSize=1` dropped; body discarded, token never logged, project id and identity regex-checked, `redirect: "error"` kept. `ci.yml` and `deploy.yml` use `npm ci --ignore-scripts`; `deploy.yml` `permissions: {}`.
- **10-20 fixes:** B1 (permission settled before the write), B2 (both-landed first emission, retry rebuilds state), B3 (unchanged legacy status passes, `previous` read in-transaction), I9 (`CalendarViewPrefs` catches), I13 (app lock), `isPersonal is bool` rule matches the client write.
- **History:** `AppointmentHistoryScan` is a faithful move; the status chip's server filter maps Complete to `done` + `completed`, and `refresh()` + post-frame `fetchNextPage()` costs one page (the pager skips a concurrent fetch).
- **Other changes:** `DuplicatePhoneCheck` restore, `ClientsListView` cursor generation, `DeepCollectionEquality` swap, `fieldNoteDraftsProvider` uid keying (pinned `details_field_record_view_test.dart:316`), `delete_account_flow` rollback (pinned `:217`), `ImageStorageService.uploadImage` deletion (the surviving queued path keeps the magic-byte check).
- **Conventions:** 3 sanctioned SnackBar sites only; zero `throw Exception(`; `FirebaseFirestore.instance` only in the 3 allowed files; every raw `.listen(` has `onError`; the log-tag registry is exhaustive; credential fields all set `kCredentialImePersonalizedLearning`; no BOMs; import order clean; no stray colours or off-token spacing beyond ADR-0122 exemptions.
- **Secrets / PII:** no tracked config or key files; new log lines carry error objects only.
- **Performance:** nothing measurable in this range; the range-stream gate saves one partial rebuild per subscription.
- **Dependencies:** `functions/` `npm audit --omit=dev` 0 vulnerabilities.

## Notes / uncertainties

- **`tools/deploy` npm audit:** 3 high in one chain, `braces` (GHSA-vfj7-8cjw-p6xm) through `chokidar` through `firebase-tools` 15.34.0. Not reachable: the CLI only globs the repo's own `firebase.json` patterns, and the deploy runs `--ignore-scripts` from `main` behind a human approval. Pick up the fix with a normal firebase-tools bump; never `npm audit fix --force`, which downgrades to 6.8.0.
- **FID step 2:** when the client starts writing `kind: "fid"` rows, a device holding both a legacy token row and a FID row would get every push twice. `docs/plans/2026-10-21-fcm-fid-migration-plan.md:29` covers it (delete the legacy row after the FID write). Review step 2 against that.
- **Unused-dependency heuristic:** all five hits are false positives. `google_maps_flutter_ios_sdk9` is a documented native implementation pin (`pubspec.yaml:93-97`); `integration_test` backs `integration_test/performance_test.dart`; `build_runner`, `freezed` and `flutter_launcher_icons` are tooling.
- `app_lock.dart:226`'s `if (!mounted) return;` after a successful sign-out skips `_release()`. Harmless, because `AppLock` lives in `MaterialApp.builder` and never unmounts. Not filed.
