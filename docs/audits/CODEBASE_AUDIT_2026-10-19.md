# Codebase Audit — 2026-10-19

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`firestore.indexes.json`, `.github/workflows/`, `ios/` Swift, `test/`).
Baseline: `dev` @ `33cde361`, clean tree. Emphasis on the 4 commits since the
2026-10-14 baseline (`d6e19618..HEAD`): 134 non-test files, +5.4k/−0.9k, almost
all in `33cde361` "review and cleanup" (session fence, upload intents, the
`saveAppointmentEdits` callable + `editProtocol` rules, mirror ownership,
`searchClients`/conflict-batch rewrite, overdue cursor sweep). `33cde361` is on
`origin/dev` only; `main` (and so prod) is at `4e859ce0`.

## Implementation status (2026-10-19)

All 16 findings implemented (4 deviated); still OPEN only for the backend deploy (B1 index, B4, B5, B6, I6). Verified: `flutter analyze` No issues found! · `dart run tool/test.dart` 4213 passed · functions lint clean · jest 2323/2323 (113 suites). A shard leak surfaced by the new test files (`presence_remote_pause_test` overrides without `ref.onDispose`) was fixed in 3 test files and recorded in testing.md.

## Summary

- Scanned: ~490 Dart files in `lib/`, ~410 in `test/`, `functions/` (112 jest
  suites), both rules files, the index file, the workflows, the changed Swift.
- Auto-fixed (safe, in the diff): 6 edits across 8 files. Two of them unbreak
  the build: **`dev` HEAD did not compile** and CI run 39238044369 failed all
  three jobs (Flutter, functions lint, iOS).
- Reported for your decision: 17 (⚠️ 1 pre-deploy · 🔴 0 security · 🟠 6 bugs ·
  🔵 10 improvements).
- Verification (after the fixes): `flutter analyze` **No issues found!** ·
  functions lint clean · jest **2296/2296** (112 suites) · `dart run
  tool/test.dart` **4179 passed** (before the fixes: no compile; after the
  compile fix alone: 4178 passed, 1 failed).

## Decide first

1. **B1 (pre-deploy):** add an `appointments (status ASC, endTime ASC)` index,
   or flip `scanOverduePage` to DESC to reuse the existing one? Either way it
   must land before `33cde361` is deployed.
2. **B4 / I1:** bring `searchClients` back under the 200-read cap (the rule in
   `search.md`) at the cost of the exact `matchedCount`, or keep the full scan
   and amend the rule? This is a product call: "25+" vs an exact count.
3. **B5:** reopening through `saveAppointmentEdits` should clear
   `completedAt` like `restoreAppointmentStatus` does? (Recommended yes.)

Everything else is local and test-backed, so "do all" can cover it. B1, B4, B5
and B6 are functions changes and take effect only with the next backend deploy.

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `lib/features/presence/application/presence_sync_controller.dart:65` | `ref.mounted` → `ref.context.mounted` | **Compile error** (`undefined_getter`): `WidgetRef` has no `mounted` in flutter_riverpod 3.4.3; `context.mounted` is the intended "consumer still alive" check. Broke `flutter analyze`, every test shard, and the iOS build in CI. |
| `functions/scripts/deploy/verify_config.js:72` | wrapped an 83-char line | `max-len`, failed CI's functions job |
| `test/features/presence/screens/share_location_ask_screen_test.dart` | added `sessionFenceProvider` override | `33cde361` made `saveLocationSharing` read the fence; the test fell through to real Firebase (`[core/no-app]`), 2 failures |
| `test/features/settings/widgets/views/location_sharing_view_test.dart` | same override | same cause, 1 failure |
| `lib/features/home_widget/application/widget_sync_service.dart:25` | `'schedulePayload'` → `mirrorWidgetKey` | re-spelled key: logout clears `mirrorWidgetKey`, so a rename of one alone would stop logout clearing the widget |
| `lib/features/siri/application/schedule_snapshot_service.dart:16` | `'schedule_snapshot'` → `mirrorSnapshotKey` | same, for the Siri/CarPlay snapshot |
| `.claude/rules/error-handling.md:15`, `docs/ARCHITECTURE.md:839` | "7 sanitized causes" → 9, list updated | `error_cause.dart` added `editConflict` and `incompleteCheck` |

> Nothing below this line was auto-changed.

## ⚠️ Pre-ship checklist

No `TODO(pre-ship)`/TODO/FIXME/HACK/XXX markers in `lib/` or `functions/`.
One **pre-deploy** blocker: **B1** (missing composite index), which must ship
with or before the functions build from `33cde361`.

## 🔴 Security findings

None at ≥80 % confidence. The two integrity notes the security pass raised on
`saveAppointmentEdits` are admin-only and filed as bugs (B5, B6). See
"Checked and sound".

## 🟠 Bug findings (review required)

### B1 — overdue sweep query has no matching composite index · high · confidence 80 %

> **DONE** (2026-10-19) — `(status ASC, endTime ASC)` added beside the DESC one; `overdue_scan.test.js` pins both. **OPEN — needs deploy** (`firestore:indexes` with/before functions), then confirm the sweep in `functions_get_logs`.

- **Where:** `functions/overdue_scan.js:18-23` (via `notification_sweeps.js:54`), `firestore.indexes.json`
- **Problem:** the new cursor sweep runs `status in [...]` + two `endTime`
  bounds + `orderBy("endTime","asc")` + `orderBy("__name__","asc")`. The only
  `(status, endTime)` composite is `(status ASC, endTime DESC)`, which served
  the old DESC `scanAppointmentWindow`. Firestore composite indexes serve one
  direction. After a deploy, every 5-minute sweep would throw
  `FAILED_PRECONDITION` inside the rider's `try`: overdue prompts stop, and the
  only trace is a `sendOverdueJobPrompts failed` log. That's the same silent
  degradation as the 2026-08-28 travel-index incident. Mocked jest and the
  emulator (which doesn't enforce indexes) can't see it.
- **Fix:** add `{status ASC, endTime ASC}` to `firestore.indexes.json` and
  deploy `firestore:indexes` with the functions. Keep the DESC one: the app's
  `watchOverdueOpen` uses it. Then confirm the sweep in `functions_get_logs`
  after the deploy.

### B2 — one unstageable photo batch blocks every later batch in the offline queue · medium · confidence 85 %

> **DONE (deviated — a copy that throws while the source still exists keeps the entry and its originals (images.md: preserve partial staging) and reports a failure instead of settling; only a MISSING source is dropped and counted lost)**. Drain now catches per entry. images.md updated.

- **Where:** `lib/features/calendar/data/appointment_image_upload_service.dart:407-421` (rethrow) and `:553-559` (drain loop inside one `try`)
- **Problem:** staging now runs in the drain (`_finishStaging`). If copying a
  picker original throws (iOS tmp purged, unreadable file), `_attempt`
  rethrows and the throw leaves the `for` loop, so no later entry is tried.
  The entry keeps its `stagingSources` and is first again on every drain, so
  every photo queued later on that device stays stuck until the 7-day prune.
  `ImageUploadIntent.prepare` or `_store.checkpoint` throwing has the same
  effect.
- **Fix:** catch per entry inside the loop (warn `IMG-UPLOAD`, `continue`). For
  a missing source, settle the entry to cleanup-only and surface it through the
  existing failure/expiry path rather than retrying it forever. Add a test: a
  missing-source entry ahead of a good one, and the good one still uploads.

### B3 — Save stays disabled after a session-changed `Busy` return · low · confidence 85 %

> **DONE** — flags reset before every stale-lease `Busy` return; 3 controller tests. The `:652` path is defensive (unreachable in tests: the series fence fires first).

- **Where:** `lib/features/calendar/application/add_event_controller.dart:421,433,441`; `event_details_controller.dart:612-614,652-654`
- **Problem:** the new `ownsWrite`/`isCurrent` guards return `AddEventBusy` /
  `EventDetailsSaveBusy` without resetting `isSubmitting`/`isSaving`, which
  breaks the CLAUDE.md "reset on every early return" rule. This happens when an
  exit starts and then fails (`SessionFence.resume()` stales the lease): the
  next tap hits the `isSubmitting` guard, `Busy` shows nothing, and Save stays
  dead for the life of that sheet. On `:441`/`:652` the record is already
  written, but the new photos are silently not queued.
- **Fix:** `if (ref.mounted) state = state.copyWith(isSubmitting|isSaving: false);`
  before each of those returns, plus a controller test that stales the lease
  mid-save.

### B4 — `searchClients` reads every match (up to 5000) instead of ≤200 · medium · confidence 90 %

> **DONE** (owner: cap + "N+") — one 200-doc window + a parallel 5-doc exact `array-contains` probe; new additive `matchedCountIsLowerBound`; list shows `clients_searchTruncatedAtLeast`. Old app builds read the lower bound as exact (harmless). search.md updated. **OPEN — needs deploy.**

- **Where:** `functions/indexed_search.js:111-127`
- **Problem:** the rewrite pages through all `array-contains-any` matches, in
  sequential pages of 200, to give an exact `matchedCount` and rank exact hits
  first. `search.md` says "Keep the read cap (200 read …) … don't raise the cap
  without a real relevance order". Client tokens include address, city,
  province and country prefixes, and search starts at 1 character. So `m`,
  `mo`, `q` and `ca` match close to the whole roster, on every debounced prefix
  from the Clients list and the appointment form picker. Assuming 1,500
  clients, that is about 7.5× the reads and about 8 serial round trips. Past
  5000 matches, short-query search breaks outright (`resource-exhausted`) and
  the reads are still billed.
- **Fix:** see **Decide first** #2. Stop paging at `SEARCH_RESULT_LIMIT + 1`
  matches or one page, return `truncated: true` with a lower-bound count ("25+"
  in the UI), and get the exact-match boost from one narrow `array-contains`
  probe (`limit` ~5). Or amend the rule if the exact count is worth the cost.

### B5 — reopening via `saveAppointmentEdits` keeps `completedAt` · low · confidence 85 %

> **DONE** (owner: yes) — leaving done/completed (incl. → cancelled) deletes `completedAt`; jest cases. **OPEN — needs deploy.**

- **Where:** `functions/appointment_edits.js` (patch path), `functions/notification_policy.js:139-141`
- **Problem:** done → pending is allowed through the callable, which is now the
  only reopen path besides `restoreAppointmentStatus`, because the new
  `appointmentClosedStatusPreserved` blocks it on the direct write. Unlike the
  restore callable, it doesn't delete the server-owned `completedAt`, and
  `lifecycleStamps` skips stamping when `completedAt != null`. So a reopened job
  shows a finish time while open and keeps the old one when it's completed again.
- **Fix:** when the patch moves status out of `done`/`completed`, add
  `completedAt: FieldValue.delete()`. Add a jest case. Needs a deploy.

### B6 — callable accepts run labels the rules then refuse · low · confidence 85 %

> **DONE** — 1..`MAX_APPOINTMENT_SPAN_DAYS` integers, `dayIndex <= dayCount` on the merged record (skipped when an existing doc's labels are unchanged). **OPEN — needs deploy.**

- **Where:** `functions/appointment_edit_policy.js:64-66`
- **Problem:** `dayIndex`/`dayCount` are accepted as 0–120. `isValidAppointmentData`
  requires 1–14, and appointments.md warns that a `dayIndex: 0` makes every
  later client write fail. The Admin SDK skips the rules, so a doc written this
  way is then refused on the direct status write (cancel, overdue review).
  Only an admin payload can reach it, and the app sends the pair only under
  `hasRunLabels`.
- **Fix:** bound both to 1–14 (`MAX_APPOINTMENT_SPAN_DAYS`) and require
  `dayIndex <= dayCount`. Needs a deploy.

## 🔵 Areas to improve (review required)

### I1 — widget and Siri mirrors no longer skip unchanged payloads in production · medium · confidence 90 %

> **DONE (deviated — dedup also requires `AppGroupMirrorStore.stillHolds` to confirm the App Group still has the last write; a memory-only (uid, signature) key would skip the resume republish after an FCM background write)**. Clears never dedup. notifications.md updated. CarPlay ping still fires per emission (CarPlay ignores an unchanged `generatedAt`).

- **Where:** `widget_sync_service.dart:179`, `schedule_snapshot_service.dart:39`
- **Opportunity:** `if (_session == null && signature == _lastState) return;`
  only skips repeats when there is no fence, and production always injects one.
  So every mirror-stream emission (for an admin: any colleague's edit) costs
  about 8–10 App Group channel calls, a WidgetKit `updateWidget` and a CarPlay
  ping. The signature tests still pin a dedup that only the test path runs.
- **Suggested improvement:** keep the check on both paths, keyed on
  `(lease.uid, signature)`, and reset `_lastState` on `clear()` and on an
  owner/epoch change.

### I2 — the dashboard re-reads 7 weeks of history on every local appointment write · medium · confidence 85 %

> **DONE** — `onRecordWrite` now carries `{id: startTime}`; history refetches only when a write lands in its range, hits a held id, or races the in-flight read; 2 s `Debouncer` coalesce (`kDashboardHistoryRefreshDebounce`).

- **Where:** `lib/features/dashboard/application/dashboard_providers.dart:57-67`
- **Opportunity:** `_dashboardRecordWritesProvider` bumps on every
  `onRecordWrite`, which re-runs `fetchInRange(historyRange)` while the
  dashboard is alive or within its 3-minute grace. Most writes (mark-done, new
  bookings) fall in the live window, which the listener already covers. An
  overdue review triggers one refetch per 450-doc chunk. At about 15 jobs/day
  that is roughly 700 reads per write.
- **Suggested improvement:** bump only when a written record's `startTime`
  falls inside the history range (`_patchWindow` has the changes), and coalesce
  bursts.

### I3 — `PushRegistrationController` retry/rotation logic is untested · medium · confidence high

> **DONE** — 5 tests (backoff exhaustion, retry reset, rotation failure→recovery, refresh mid-upsert); each verified by mutating the controller.

- **Where:** `push_registration_controller.dart:89-131, 236-282, 338-367` (211 → 383 lines)
- **Opportunity:** none of these branches is tested: the 5-attempt backoff,
  `_rotationRequired` (a failed `deleteToken()` makes every later `sync()`, the
  next user's included, only re-rotate), and the `_tokenRevision` guard against
  a late refresh. No `fakeAsync` cases.
- **Suggested improvement:** `fakeAsync` tests for backoff exhaustion and
  resume reset, rotation failure then recovery, and a refresh landing mid-upsert.

### I4 — the new rules functions have only indirect emulator coverage · medium · confidence high

> **DONE (deviated — done→completed can't be "allowed": `completed` isn't a valid stored status; tested completed→done instead)** — 13 emulator asserts, run locally against a demo project.

- **Where:** `firestore.rules:385-401` (`appointmentClosedStatusPreserved`, `appointmentDirectEditAllowed`), `:272-275` (`sessionEpoch`); `functions/__tests__/emulator/appointment_edits_checks.js:45-50`
- **Opportunity:** only two denials are checked, and `DirectEditAllowed` alone
  explains both, so `ClosedStatusPreserved` is never exercised by itself.
- **Suggested improvement:** about 8 asserts in the same file:
  - legacy doc: cancelled → pending/done and done → pending refused, done ↔ completed allowed;
  - protocol-1: status-only forward moves allowed (with `seriesOpId`), in_progress → pending refused;
  - `sessionEpoch` that is not a string, or over 64 characters, refused.

### I5 — the production branch of the mirror services is untested · medium · confidence high

> **DONE** — legacy `write:` path retired; store/reload/platform injected; 15 + 7 fenced-branch tests over `test/support/fake_app_group.dart`.

- **Where:** `widget_sync_service.dart`, `schedule_snapshot_service.dart`
- **Opportunity:** the tests inject `write:` with no fence, so they cover only
  the legacy `_session == null` branch of each `sync`/`clear`. That leaves
  untested the lease checks, `updateWidget` after the save, and the stale-lease
  return.
- **Suggested improvement:** inject `AppGroupMirrorStore` (today it is the
  global `appGroupMirrorStore`) plus a fake fence, and test that branch. If
  nothing else needs the legacy `_write` path, retire it so the split goes away.
  Do this together with I1.

### I6 — `saveAppointmentEdits` guard tests and an App Check style deviation · low · confidence high

> **DONE** — new `appointment_edits_callable.test.js` (composer stub per ADR-0040); `enforceAppCheck: true` inline in `appointment_edits.js` and `findAppointmentConflicts`. **OPEN — needs deploy** (cosmetic).

- **Where:** `functions/appointment_edits.js:21-40,122-129`; `indexed_search.js:236`
- **Opportunity:** these are untested:
  - the 0-command and >400-command refusals;
  - `.`/`..` ids;
  - that the rate limiter runs only after validation;
  - the `assertAdminCall` composer stub (ADR-0040).

  Separately, both options objects spread `{...APP_CHECK, timeoutSeconds: …}`.
  security.md (ADR-0043) asks for `enforceAppCheck: true` written inline when
  the object also sets a timeout. Enforcement is on either way.
- **Suggested improvement:** add the four jest cases and write the flag inline
  in both spots.

### I7 — `AppointmentImageUploadService` grew to 778 lines, with a 118-line `_attempt` · low-medium · confidence high

> **DONE** — `_settle(...)` extracted; `PendingPhotoExit` moved to `lib/core/app/pending_photo_exit.dart`. The service is still ~820 lines (B2 added logic).

- **Where:** `appointment_image_upload_service.dart` (497 → 778); `_attempt` `:397-515`; `PendingPhotoExit` declared at `:32-46`
- **Suggested improvement:** split `_attempt`'s requeue-or-settle tail
  (`:463-514`) into `_settle(...)`. Move `PendingPhotoExit` into
  `lib/core/app/pending_photo_exit.dart` (one class per file). Do this together
  with B2.

### I8 — the same stale-check prologue in 3 registration controllers (10 sites) · low · confidence high

> **DONE** — `SessionFencedSync` mixin (`lib/core/utils/session_fenced_sync.dart`) replaces 13 checks. A disposed push controller's `unregisterCurrentDevice` now stops before `deleteToken` (matches presence/live activity; unreachable in practice).

- **Where:** push, presence and live-activity `_syncGuarded`s
- **Suggested improvement:** one `ReentrantSync` helper
  `isAttemptStale(generation, lease)` with `_disposed` in the mixin. At 3 files
  and 10 sites this is proportionate; don't add a base class.

### I9 — `AppointmentImageCarousel.build()` is 84 lines and has no test · low · confidence high

> **DONE** — `_LocalSlide` extracted; new carousel test pins the semantics strings. Status-picker trim skipped (optional).

- **Where:** `appointment_image_carousel.dart:33-116` (was 57). Borderline:
  `appointment_status_picker.dart:18` (61).
- **Suggested improvement:** extract `_LocalSlide` beside `_RemoteSlide` and add
  a carousel widget test. That test would also pin the three new
  `appointment_photo_semantics.dart` strings, which nothing asserts today.

### I10 — `confirmPendingPhotoExit` calls `prepareForExit()` outside its `try` · low · confidence medium

> **DONE** — `prepareForExit` returns null (and resumes) on a session change; callers already treat null as a quiet cancel. Other `StateError`s still surface.

- **Where:** `lib/core/app/pending_photo_exit.dart:15`
- **Opportunity:** a session change makes `prepareForExit` throw
  `StateError('photo exit session changed')`, which callers surface as a real
  "Couldn't sign out" notice instead of a quiet no-op.
- **Suggested improvement:** return null on that `StateError` (or capture it
  inside the guard). The 15-line exit sequence copied across
  `change_password_screen.dart` and `delete_account_flow.dart` (×2) can stay
  as it is until a fourth site appears.

## 🟡 Code-quality suggestions (optional)

> **All DONE** except: `session_fence.dart` two classes (left, acceptable). `account_*` keys → renamed to `auth_*` (owner call). Cause sentences one em-dash sentence each. ARB `@` blocks multi-line. Comments trimmed. Dead exports removed. `AppGroupMirrorStore.revision` private. `form_helpers.dart` → `onInverseSurface`. Refused-photo futures held in State.

- **`account_` l10n bucket.** 5 new keys use a bucket the CLAUDE.md list
  doesn't name (`app_en.arb:4448-4458`, e.g. `account_pendingPhotosTitle`).
  Either add `account_` to the list (doc-only) or rename the keys.
- **Cause wording.** `error_causeEditConflict` and `error_causeIncompleteCheck`
  are 2–3 sentences. The rule is one sentence: why, an em dash, then what to do.
  Fix in both ARBs.
- **ARB formatting.** The 12 new `@key` blocks are single-line JSON while the
  rest are multi-line. Cosmetic only.
- **Multi-line comments added in the diff** (code-quality.md allows one line).
  The phone-lift rationale is already in clients.md (ADR-0095).
  - `widget_sync_service.dart:250` (3 lines)
  - `client_name_phone_lift.dart:5-12` (8 lines) and `:41-42`
  - `current_day_provider.dart:13-14`
  - `appointment_photo_semantics.dart:4-5`
- **Dead exports and visibility:**
  - `AppGroupMirrorStore.revision` is public but only used in its own file.
  - `verify_config.js` exports `regionFor` with no consumer.
  - `backfill-client-name-with-phone.js` exports `splitName` with no consumer;
    the function itself must stay.
  - `backfill-client-phone-formatting.js` exports `explain` with no consumer.
- **`session_fence.dart`** holds two classes (`SessionFence` + its value type
  `SessionLease`). Acceptable as is.
- **`form_helpers.dart:69`** uses `Colors.white` on a `scrim` chip. It predates
  this diff. Either add it to the sanctioned white-chrome list or use
  `onInverseSurface`.
- **Refused photos refetch on every rebuild.**
  `FutureBuilder(future: loadBytes())` sits in `build` at
  `photo_picker_section.dart:228` and `appointment_image_carousel.dart:138`.
  Hold the future in State, or record the trade-off in images.md.

## Checked and sound

- **Security:**
  - **`saveAppointmentEdits`:** guard order is auth → `assertAdmin` →
    `assertPayloadShape` (explicit 4 MiB) → per-command validation (≤400, ids
    with no `/`, `.` or `..`, no duplicates) → durable limit (120/min) →
    transaction. App Check is enforced. A field allowlist with rules-matching
    caps means `pictureCount`/`startedAt`/`completedAt`/`searchTokens` can't be
    injected. Status is limited to the 4 allowed values. `historySearchScopes`
    is rebuilt on every write.
  - **Rules:** a protocol-1 doc admits only forward status-only direct writes.
    The `editProtocol`/`editRevision`/`clientSourceUpdatedAt` denylist stops a
    protocol switch. The three assignee disjuncts are unchanged.
    `notificationSweepCursors` is deny-by-default. `storage.rules` is unchanged.
  - **Search scoping:** `searchClients` is still `assertAdminCall`;
    `findAppointmentConflicts` still refuses (`scope-denied`) a non-admin any
    id but their own.
  - **Workflows and deploy scripts:** actions are SHA-pinned, CI runs on
    `pull_request`, inputs reach `run:` only via `env`, permissions default to
    `{}`, and `execFileSync` always takes arg arrays.
  - **Session fence:** gates push, Live Activity, widget, Siri and deep-link
    work. Both App Group copies are cleared ownerless-first on logout. The
    Swift readers reject wrong-owner or wrong-epoch data.
  - **Pending uploads:** each entry is owner-bound and leased, and upload
    intents never overwrite. Credential fields and logging are clean, and App
    Check plus `persistenceEnabled` remain in `main()`.
- **Bugs:**
  - **Direct writes after the migration:** with functions injected, every form,
    series and clash-swap write goes through the callable. What's left on the
    direct path (status writes, the photo `updatedAt` touch, CarPlay) satisfies
    `appointmentDirectEditAllowed`. Legacy docs without `editProtocol` pass.
  - **Undo** is still the `restoreAppointmentStatus` callable, so the new admin
    done→pending ban doesn't affect it. ADR-0014 holds: the client
    `runTransaction` exists only in the tests-only fallback.
  - **Exit sequence:** `deregisterThisDevice` runs before `signOut()` on every
    path, and the `_isHandlingAccountExit` release rules are intact.
  - **Other checks:**
    - Push, presence and Live Activity re-check staleness after every await.
    - Upload intents reuse their path on retry.
    - Recounts are transactional and never resurrect a parent.
    - The `sessionEpoch` cap matches the widget-payload binding.
    - The TTL index exemptions are safe: only `liveActivityTokens`/`liveActivityCards` query `expiresAt`, and their indexes are unchanged.
- **Performance:**
  - The minute-tick `presentationTimeProvider` rebuilds only visible cards, and
    the date ranges don't churn.
  - The registration controllers have fast paths, so a resume doesn't re-write.
  - Thumbnails decode at `cacheWidth`, with no sync I/O on render paths.
  - Conflict batches are ≤16 windows with an early exit; the overdue cursor
    adds 1 read and 1 write per run; Wave got a 20 s deadline.
- **Dead code and conventions:**
  - The only files with no importer are `main.dart`; no new symbol is
    unreferenced.
  - EN/FR ARB key sets are identical, all 12 new keys are used, and there are
    0 orphaned keys corpus-wide.
  - The log-tag registry matches both ways.
  - None of the following: BOMs (919 files checked), markers,
    `throw Exception(`, stray `FirebaseFirestore.instance`, unsanctioned
    SnackBars, raw widget `Timer`s, unchunked `arrayContainsAny`.
  - Unused-dep hits are the known false positives.

## Notes / uncertainties

- **How a non-compiling HEAD got pushed:** `33cde361` was pushed with a
  compile error, so neither its test suite nor its iOS build could have run
  before the push. The +10.7k test and code lines in that commit had never run
  green until this audit's fixes. After the fixes, the full suite surfaced
  exactly the three failures listed above, all the same missing test override.
- **B1 confidence (80 %)** rests on Firestore composite indexes serving a single
  direction. That matches how the 2026-08-28 index incident behaved, but it
  was not run against prod. Check it in `functions_get_logs` after the deploy,
  or rule it out first with a one-off `explain()`.
- **B4 cost** is estimated from the token design, not measured; the roster size
  wasn't queried.
- Rules are reviewed statically only. The emulator rules checks run in CI, and
  no live backend was queried.
