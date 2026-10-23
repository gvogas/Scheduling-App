# Codebase Audit — 2026-10-23

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`tools/deploy/`, `.github/workflows/`, `test/`). Baseline: `main` @ `957bd9e`
(clean tree). Emphasis on `14a5da02..957bd9e`: the 2026-10-22 audit
implementation, the forced-exit lock release (`c3c54d5`), release 1.66.1+99.

## Implementation status (2026-10-23)

`/audit-do` the same day:
- **Done:** 11, two of them deviated (I3, I4).
- **Not a defect:** B1.
- **Open:** I5, watch-only by design.
- Nothing needs a deploy or backfill.

Verified 2026-10-23 on Linux (Flutter 3.47.7):
- `flutter analyze`: **No issues found!**
- `dart run tool/test.dart`: **4488 passed, 0 failed**
- `tool/check_rules.dart`: 0 violations
- functions lint: clean
- jest: **116 suites, 2394/2394**
- no BOMs

## Summary

- Scanned: `lib/` (513 files), `test/`, `functions/` (54 modules + scripts),
  both rules files, deploy tooling and workflows; five parallel reviewers
  (security, bugs, dead code / conventions, performance, maintainability / tests).
- Auto-fixed (safe, in the diff): 2 spacing-token swaps. Static layer was
  already clean: `flutter analyze` No issues found!, `dart fix` Nothing to fix!,
  functions lint clean, no zero-import file, the five unused-dependency hits are
  the documented false positives (see Notes).
- Reported for your decision: 13 (⚠️ 0 pre-ship · 🔴 0 security · 🟠 2 bugs ·
  🔵 5 improvements · 🟡 6 code-quality).
- Prior audit (2026-10-22): I1–I5 confirmed closed with their tests; I6 still
  watch-only with identical line counts.

## Decide first

1. **Q3:** `isLastDay` on `AppointmentDaySlice` is test-only. Default for "do
   all": remove it and rewrite its one assertion as `dayIndex == dayCount`.
2. **R-keep:** `functions/appointment_image_ids.js` is test-only on the JS side,
   but it is the hand mirror of `appointmentImageDocId` pinned by
   `test/fixtures/shared/image_ids.json` (same pattern as the 10-22 Q2). Default:
   keep, no change.

Nothing needs a prod deploy or backfill; every item is local and test-backed.

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `lib/features/clients/widgets/sections/clients_list_header.dart:213` | `horizontal: 12` → `AppSpacing.sp12` | design token (next line already uses `sp8`) |
| `lib/features/calendar/widgets/views/details_view_leaf_widgets.dart:229` | `vertical: 4` → `AppSpacing.sp4` | design token (`horizontal: 11` kept — ADR-0122 nudge) |

> Full detail is in `git diff`. Nothing below this line was auto-changed.

## 🔴 Security findings

None. All 20 `onCall` callables enforce App Check; admin callables open with
`assertAdminCall`, self-service with `assertActiveCall`; credential fields set
`kCredentialImePersonalizedLearning`; nothing reads the role from
SharedPreferences. The diff since 10-22 touches no rules, guards or workflows.
The forced-exit lock release only fires from `exitAccount` after the login route
has covered the app and re-checks `currentUser == null`, never persists the flag.

## 🟠 Bug findings

### B1 — the caret jumps to the start of the crew-note field after a post · low · confidence medium

**NOT A DEFECT** — `EditableText._didChangeTextEditingValue` (Flutter 3.47) moves an invalid selection on a FOCUSED field to the end of the text on every platform. A widget test of the old code showed the caret at offset 14, the end. The composing range is cleared either way. Nothing changed.

- **Where:** `lib/features/calendar/widgets/views/details_field_record_view.dart:124`
- **Problem:** `_notes.text = …` resets the selection to `offset: -1` and drops
  the composing range. If the crew kept typing during the write (the case the
  10-22 B3 fix exists for), the still-focused field puts the caret at 0, so the
  next keystrokes land in front of the kept text and an in-progress accent
  composition is lost.
- **Fix:** assign the whole value with a collapsed selection at the end:
  `_notes.value = TextEditingValue(text: kept, selection: TextSelection.collapsed(offset: kept.length))`.
  Add a widget-test assertion on `selection` after a post.

### B2 — lock-overlay Log out pushes login a second time after a forced exit wins · low · confidence medium

**DONE** — `_logOut` returns on `!signedOut` without releasing or navigating: the forced exit's login-shown listener owns the release, and a Stay keeps the lock. New `app_lock_test.dart` case; it failed `(false, 2)` before the fix.

- **Where:** `lib/core/security/app_lock.dart:243-251` (with `_release()` `:160`)
- **Problem:** Log out on the overlay with pending photos shows the inline
  choice. If an admin disables the account meanwhile, `exitAccount` signs out and
  pushes login; `forcedExitLoginShownProvider` then fires, and `_release()`
  answers the choice as Stay. `signOutAfterPhotoCheck` returns false, but
  `currentUser` is now null, so `!signedOut && auth.currentUser != null` is false
  and `_logOut` pushes `AppRoutes.login` again. That replaces the forced exit's
  freshly shown login (a second transition; anything typed is wiped).
- **Fix:** when `!signedOut`, never navigate. The forced exit (or nobody) owns
  navigation then. Pin it in `app_lock_test.dart`: the photo choice is pending,
  a forced exit's login is shown, and exactly one login push follows.

## 🔵 Areas to improve

### I1 — `retryPastBusyConflict` and the Double Booking dialog have no test · impact medium · confidence high

**DONE** — `test/features/calendar/widgets/dialogs/busy_conflict_dialog_test.dart`, 4 cases.

- **Where:** `lib/features/calendar/widgets/dialogs/busy_conflict_dialog.dart:24-42`.
  It has three callers: `add_appointment_sheet.dart:265`,
  `details_edit_body.dart:390` and `details_view_body.dart:439`.
- **Opportunity:** No test names the helper or the dialog. If it regresses, a
  declined double booking saves anyway, or a forced save is skipped, and every
  test stays green. Its own dartdoc says the three sites had already drifted on
  the mounted checks.
- **Suggested improvement:** Add one widget-test file with four cases:
  - not busy: no dialog;
  - busy, then decline: `attempt` runs once and the result is null;
  - busy, then confirm: the second call passes `forceBusy: true`;
  - unmounted mid-attempt: null and no dialog.

### I2 — every mounted `AppointmentCard` rebuilds once a minute · impact low · confidence high

**DONE** — the card watches `presentationTimeProvider.select(appointment.displayStatusAt)`, and `_CardModel.from` and `_DayOffStrip` take the status. New test: the minute tick past the end still turns the card overdue.

- **Where:** `lib/features/calendar/widgets/cards/appointment_card.dart:106`
- **Opportunity:** The card watches the whole `presentationTimeProvider`, but it
  only uses `now` for `displayStatusAt(now)`. Every mounted card, hidden
  `IndexedStack` tabs included, rebuilds and re-lays out under `IntrinsicHeight`
  each minute, and almost all of those rebuilds produce identical output.
- **Suggested improvement:** Watch only the derived status, then pass it to
  `_CardModel.from` and `_DayOffStrip`:
  `ref.watch(presentationTimeProvider.select((now) => appointment.displayStatusAt(now)))`.

### I3 — Job history re-reads ~61 docs on any local appointment write · impact low · confidence medium

**DONE (deviated)** — reuses `DashboardAggregator.writeTouchesHistory` directly instead of a near-copy, with a 1970→now range re-read per write. The held ids are all fetched visits (up to 60), not just the 50 shown. `clients.md` now states the gate. Five provider-test cases replace the old unconditional one.

- **Where:** `lib/features/clients/application/appointment_history_providers.dart:94-98`
- **Opportunity:** `onRecordWrite` invalidates every live
  `clientJobHistoryProvider(clientId)` whether or not the write touched that
  client. That costs about 61 reads per write, and it matters most on a tablet,
  where the client detail pane stays mounted.
- **Suggested improvement:** Copy the dashboard's `writeTouchesHistory` gate:
  invalidate only when a written id is already in the held list, or when its
  `startTime` is non-null and in the past. Verify the membership rule against
  `fetchClientHistory` first.

### I4 — `pageToCap` has no direct unit test · impact low · confidence high

**DONE (deviated)** — `test/core/data/paged_scan_test.dart`, 6 cases, built on `Fake` `Query`/`QuerySnapshot` subclasses because `fake_cloud_firestore` isn't a dependency.

- **Where:** `lib/core/data/paged_scan.dart` (41 lines, 6 production callers,
  required by `CLAUDE.md` for every bounded scan)
- **Opportunity:** It is covered only indirectly, by the cap-warning test.
- **Suggested improvement:** Add a plain `fake_cloud_firestore` test covering a
  short first page, a partial last page, cap+1 (warns and trims) and a custom
  `advance`.

### I5 — god files and long `build()` methods (watch only) · impact low · confidence high

**OPEN** — watch only, by design.

- Line counts are unchanged since 10-22:
  - `firebase_appointments_repository.dart` 1040
  - `event_details_controller.dart` 883
  - `main_calendar_screen.dart` 856
  - `details_view_body.dart` 810
- Marginal `build()`s, 61–65 lines: `details_view_body.dart:218`,
  `appointment_image_carousel.dart:33` and `duplicate_phone_notice.dart:21`.
- No action. Extract when a file is next touched.

## 🟡 Code-quality suggestions

- **Q1** — **DONE** — `functions/wave/customer_contract.js:325-339`: `isBlocked()` has had
  no production caller since it was added. Delete it and its export, and recast
  its `describe` block as `buildCustomerPayload(...).ok` assertions, because that
  block alone pins "advisory-only problems still read ok" (wave.md).
- **Q2** — **DONE** (both `loadAll` order tests went with it; the pool test now drives `load()`) — `lib/core/images/appointment_image_loader.dart:114`:
  `AppointmentImageLoader.loadAll` has been test-only since `33cde36`. Remove it.
  Then drive the pool-of-4 test through `load()`, and update
  `.claude/rules/error-handling.md`'s `loadAll` example and the "read path
  chunks at 4" comment in `appointment_image_upload_service.dart:263`.
- **Q3** — **DONE** (removed; the test already asserts `dayIndex == dayCount`) — `lib/features/calendar/domain/appointment_day_slice.dart:34`: the
  `isLastDay` getter is test-only (see Decide first).
- **Q4** — **DONE** (carve-out added to `frontend.md`) — `lib/routes/app_routes.dart:304`: `InvalidRouteScreen` uses a bare
  `AppBar()`, which `frontend.md` forbids. It is a deliberate framework surface
  (`docs/archive/2026-09-11-fresh-header-redesign.md:130`), so add the carve-out
  to the rule rather than change the code.
- **Q5** — **DONE** — `functions/CLAUDE.md` module map: it omits `job_naming.js` (live,
  required by `notification_messages.js` and `live_activity_utils.js`) and
  `client_sort_backfill_policy.js`.
- **Q6** — **DONE** — `CLAUDE.md` Conventions: the feature-folder list names 6 of the 17
  folders. Mark it as examples.

## Notes / uncertainties

- Flutter was installed fresh in the container (3.47.7 / Dart 3.13.5, which
  satisfies `>=3.44.0`).
- The unused-dependency hits are all false positives:
  - `google_maps_flutter_ios_sdk9`: a native plugin;
  - `integration_test`: used by `integration_test/`;
  - `build_runner`, `freezed`: codegen;
  - `flutter_launcher_icons`: tooling.
- B1's caret clamp on iOS is inferred from the plugin's handling of `offset: -1`
  and has not been checked on a device. The widget test pins the controller
  state.
- Deliberately not filed:
  - `calendar_header_block.dart:65` `fromLTRB(18, topInset + 10, 18, 12)`: a mixed
    nudge, borderline under ADR-0122;
  - test seams in `functions/` (`_resetForTest`, cache resets): intentional;
  - `TopRouteObserver`: kept by ADR-0070.
- ARB: the en/fr key sets are identical, every key has an `@key` block, and no
  key looks orphaned.
- The log-tag registry matches the code in both directions, and no file has a BOM.

---

**Next:** `/audit-do` implements everything above except the two Decide-first
defaults, which it applies as written. Pre-ship items and anything that needs a
prod deploy or backfill are never auto-implemented; this report has none.
