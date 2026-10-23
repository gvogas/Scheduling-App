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

---

# Second pass — 2026-10-23 (full-stack brief)

A narrower, deeper pass the same day, on top of `cb33d05`. It covered:
- adversarial security: rules, callables and push payloads;
- date/time and scheduling correctness, run under `TZ=America/Toronto`;
- a Firestore and API cost model;
- executed Firebase emulator checks.

Branch `claude/audit-2026-10-23`.

## Second-pass status

- **Done:** S1, S2, S3, B3, B4, B5, B6, I6, I7.
  - Each has a test that fails without its fix (B5 only under `TZ=America/Toronto`).
  - S1, S2, I6 and I7 were approved by the owner with the Decide-first defaults and implemented the same day.
- **Open:** I8–I11.
- **Deploy:**
  - S1, S2, B3, B4, B6 and I6 are in `functions/`, so they only take effect with the next `Deploy backend` run. No callable payload or allowlist changed.
  - B5 and I7 ship with the next app build. I7's query keeps the same fields and composite, so no index deploy is needed.
  - Nothing needs a backfill.

## Decide first (resolved 2026-10-23: owner approved all four defaults)

1. **S1 (Wave duplicate customer).** Choose one fix:
   - (a) Make the enqueue refuse to reset an `inflight` job: transactional, with a `requeue` flag and `attempts` kept.
   - (b) Always run `findCustomerByIdentity` before a create. This costs one Wave list call per new client.
   - Default: (a).
2. **S2 (restore window).** Bound non-admin `restoreAppointmentStatus` to a window after `completedAt`. Default: 10 minutes, with admins unbounded.
3. **I6 (Routes cost).** Widen the defer rule in `travel_policy.js` (ADR-0104 territory). It changes when a billed estimate is refreshed, never whether a push is sent.
4. **I7 (drawer badge reads).** Feeding the badge from a stable daily bound or a `count()` bends the "screen and badge share one provider" rule in `appointments.md`, so it needs an owner call.

## Measured baseline (this container, Linux, Flutter 3.47.7 / Dart 3.13.5)

| Check | Before | After |
|---|---|---|
| `flutter analyze` | No issues found! (71.8 s) | No issues found! |
| `dart run tool/test.dart` | 4488 passed, 0 failed (4 m 13 s wall) | 4492 passed, 0 failed |
| jest | 116 suites, 2394/2394 | 116 suites, 2399/2399 |
| functions lint | clean | clean |
| `tool/check_rules.dart` | 0 violations | 0 violations |
| emulator checks (auth, firestore, storage) | 12 storage + 6 trigger + safety suites, pass | the same, plus 21 role-isolation checks, pass |

Not measured: startup, frame times, memory, Firestore latency, real billing. These need a device, DevTools or the production console, and none was available here. The cost figures under I6–I8 are a model, not measurements.

## 🔴 Security findings

### S1 — DONE: re-enqueue during an in-flight Wave job could create a duplicate customer · medium · confidence high

- **Where:**
  - `functions/wave/enqueue.js:80-97`: a blind `set({status: "queued", attempts: 0}, {merge: true})`.
  - `functions/wave/customers.js:331-334`: the identity dedupe runs only when `priorAttempts > 0`.
  - `functions/wave/triggers.js` (`maxInstances: 2`).
- **Risk:** if an admin saves a new client twice within about 1 s with a mapped-field change, the second trigger re-queues the job while the first instance is still inside `customerCreate`. The second claim then sees no link and `attempts: 0`, so it creates a second Wave customer. One of the two ends up orphaned in the accounting system. Invoices are not affected: nothing creates them.
- **Fix:** see Decide-first item 1. Needs a functions deploy.
- **Done:**
  - `enqueueCustomerUpsert` is now transactional: an `inflight` job only gets `requeue: true`, keeping its status, attempts and claim.
  - The trigger's mark-pending rides the same transaction, which replaces the `WriteBatch`.
  - `commitOutcome` turns the flag into a fresh queued job due at once and reports the outcome superseded; `claimJob` clears it.
  - **Tests:** jest (`wave_enqueue`, `outbox_core`, `wave_triggers`), plus an emulator run of the real enqueue, claim and commit sequence: the second claim is refused and the job is re-queued afterwards.
  - **Trade-off:** the requeued edit reaches Wave at the next drain (next edit, Sync, or the 18:00 sweep) instead of immediately.

### S2 — DONE: an assignee could reopen any completed job of theirs, of any age · low · confidence high

- **Where:** `functions/appointment_actions.js:35-44` (`mayRestore`), `:48-91`.
- **Risk:**
  - A technician can restore a weeks-old `done` job, then mark it done again. `lifecycleStamps` writes a fresh `completedAt`, so the finish time on the job record can be rewritten.
  - Each re-close also pushes admins (30/hour cap).
  - ADR-0045 chose a callable precisely to avoid "reopen anything at any age". The app only offers Undo right after mark-complete, and App Check plus App Attest means this needs a tampered client.
- **Fix:** refuse a non-admin when `completedAt` is older than the undo window. Needs a functions deploy.
- **Done:**
  - `withinRestoreWindow` allows 10 minutes for non-admins and refuses with `failed-precondition`/`undo-window-expired`.
  - It anchors on `completedAt`, else on the rules-pinned mark-done `updatedAt`, which covers the moment before the stamp lands. A photo-touch `updatedAt` cannot reopen an old completion, because `completedAt` wins.
  - Admins are unbounded.
  - The app's generic error notice covers the refusal, and Undo is only offered for seconds.
  - **Residual:** a legacy done job with no `completedAt` still anchors on the bumpable `updatedAt`.

### S3 — DONE: no executed test proved cross-role Firestore isolation · test gap

- **Where:** `functions/__tests__/emulator/`.
- **Before:** the Dart rules tests read `firestore.rules` as text. The emulator suite covered Storage, the assignee status transitions and crew notes, but not read isolation or self-escalation.
- **Done:** added `role_isolation_checks.js`, wired into the existing CI emulator step. Its 21 checks against the real rules cover:
  - outsider, disabled and anonymous reads of a job;
  - employee reads of client PII;
  - unconstrained `appointments`/`clients`/`users` list queries;
  - self-promotion and self-reactivation;
  - editing a peer;
  - a peer's emergency contact, location and FCM token;
  - writes to the bridge and the five server-owned ledgers.
- **Proof that it catches a regression:** widening the appointment read rule to `isActiveUser()` fails it with `outsider reads unassigned job: got 200`.

## 🟠 Bug findings

### B3 — DONE: server day windows were an hour off on both DST mornings, so a double booking could pass · medium · confidence high

- **Where:** `functions/day_slice_utils.js` (`businessWallInstantMs`).
- **Problem:**
  - The helper read the zone offset at a guess 4–5 h before the target. That made wall times 03:00–06:59 on spring-forward day and 02:00–05:59 on fall-back day resolve an hour off.
  - `readConflictWindow` (used by both `findAppointmentConflicts` and the `saveAppointmentEdits` transaction) collapsed an existing Mar 8 06:30–07:30 job to an empty window. A 07:00–07:15 booking for the same employee was therefore accepted.
  - The server widget payload showed those jobs an hour off.
  - Reproduced on a UTC host, the same as Cloud Functions.
- **Fix:** re-read the offset at the first answer. Three shared cases were added to `test/fixtures/shared/day_slice.json`: two DST windows and one DST clash. They fail without the fix and pass with it. The Dart twin was already correct, and its suite passes in UTC and in Toronto.

### B4 — DONE: the 18:00 digest called tonight's overnight shift "tomorrow" · medium · confidence high

- **Where:** `functions/notification_policy.js` (`groupTomorrowsJobsByEmployee`).
- **Problem:**
  - The test was a raw-instant overlap. A 22:00 → 06:00 shift tonight was listed as tomorrow's first job ("First: Alice at 10:00 p.m."), and so was a 22:00–00:00 job.
  - The widget payload in the same push correctly left both out.
  - A crew reading "tomorrow" could miss tonight.
- **Fix:** filter on `sliceForDay(r, tomorrowStart)`, the same work-day rule the widget uses. Added a test for an overnight shift and a midnight end; it fails before the fix.

### B5 — DONE: overdue-review provider rebuilt in a tight loop during the repeated 1 a.m. hour · low · confidence high

- **Where:** `lib/features/calendar/application/overdue_review_providers.dart` (`overdueReviewBoundary`).
- **Problem:**
  - During the repeated hour on Nov 1, `DateTime(y, m, d, h, min)` resolves to the EDT occurrence, an hour behind `now`. The refresh `Timer` therefore gets a negative delay.
  - It fires immediately, rebuilds, and repeats for the whole hour. Each rebuild tears down and re-creates the `watchOverdueOpen` listener.
- **Fix:** floor on epoch milliseconds (Toronto's offset is a whole number of hours, so this matches the wall-clock quarter).
- **Test:** the new invariant test fails before the fix under `TZ=America/Toronto`. The CI suite runs in UTC, where it passes either way, so it is not pinned there (see `testing.md`).

### B6 — DONE: English digest ended in a double period · low · confidence high

- **Where:** `functions/notification_messages.js` (`buildDigestMessage`).
- **Problem:** the en-CA time already ends "a.m."/"p.m.", so the body read "…at 9:00 a.m..".
- **Fix:** skip the closing period when the lead already ends in one. Test added.

## 🔵 Areas to improve

### I6 — DONE: Routes recomputed on every sweep in the last 15 min before departure · impact medium (cost) · confidence medium

- **Where:** `functions/travel_policy.js:49-50, 92-97`, `functions/travel_utils.js:185-205`.
- **Opportunity:**
  - `SKIP_MARGIN_MS` (15 min) is longer than `ESTIMATE_TTL_MS` (10 min), so each (job, employee) pair costs about 7 traffic-aware Routes calls, 4 of them in the final 15 minutes.
  - Modelled at about 6.5k–8.8k calls/month for 40 jobs/day, which is the largest variable bill: roughly $15–40/month at list price, not checked against billing.
  - An instance recycle loses the in-memory cache and can push a pair to about 18 calls.
- **Suggested improvement:** let a fresh (≤ 5 min) estimate defer until `start − lead − 5 min`. Optionally persist the estimate on the reminder ledger. This stays within "a cached estimate may only DEFER, never trigger a send".
- **Done:**
  - `FRESH_ESTIMATE_MS`/`FRESH_SKIP_MARGIN_MS` (5/5 min) were added, and `ESTIMATE_TTL_MS` went from 10 to 30 min; an older estimate keeps the 15-min margin.
  - A sweep-timeline test pins 5 billed calls per 30-minute-lead pair. The same test gives 7 against the old constants, so this is about 29% fewer Routes calls.
  - The estimate is not persisted, so an instance recycle still loses the cache.

### I7 — DONE: drawer badge re-read the whole overdue backlog each new quarter hour · impact medium at a large backlog · confidence medium

- **Where:** `overdue_review_providers.dart`, `firebase_appointments_repository.dart` (`watchOverdueOpen`), `app_nav_drawer.dart:319`.
- **Opportunity:** the `endTime < boundary` constraint changes every 15 min, so each drawer open in a new quarter re-bills the full backlog (up to 5001 docs) just to show one number. That is about 1.5k reads/day at a backlog of 100, and about 15k/day at 1000.
- **Suggested improvement:** see Decide-first item 4.
- **Done (without bending the one-provider rule):**
  - `watchOverdueOpen` bounds the query at the next local midnight, and the Dart `overdueJobsAt(now)` makes the cut.
  - The query is therefore identical all day, so each quarter-hour re-issue resumes the cached target and bills only changed documents.
  - Same fields and composite.
  - A repository test pins both the bound and that a job ending later today is not listed.
  - The billing effect follows the SDK's resume-token behaviour and was not measured here.

### I8 — Wave import builds a full `clients` index on every delta sync · impact low now, high at scale · confidence high

- **Where:** `functions/wave/customers_import.js:354-366` (`buildWaveIdIndex`, unbounded).
- **Opportunity:** about 600 reads per manual Sync today. At 100k clients that becomes 100k reads plus a 100k-entry map inside a callable.
- **Suggested improvement:** for delta imports, look up only the page's `waveCustomerId`s (`in` chunks of 30). Keep a paged full index for the weekly resync.

### I9 — overdue sweep loads recipients before the ledger dedupe · impact low · confidence medium

- **Where:** `functions/notification_sweeps.js:51-90`, `notification_utils.js:439-466`.
- **Opportunity:** about 1–2k reads/day plus about 700 failed `create()`s. The cursor doc is also rewritten on every 5-min run even when unchanged (288 writes/day).
- **Suggested improvement:** `getAll` the pairs' ledger docs first, as the travel sweep does. Skip the cursor write when it is unchanged.

### I10 — buildings catalog re-paged on every filter-sheet open · impact low now · confidence medium

- **Where:** `firebase_clients_repository.dart:296-305`, `clients_filter_sheet.dart:46`.
- **Suggested improvement:** keep it warm (`keepWarmWithGrace`, invalidated on `clientsRefreshProvider`).

### I11 — emulator checks need proxy-free env in sandboxes · impact low · confidence high

- **Problem:** locally the Storage rules runtime denied everything until `JAVA_TOOL_OPTIONS`/`HTTP(S)_PROXY` were unset. CI is unaffected.
- **Status:** documented in `functions/__tests__/emulator/README.md`. A `.claude/skills/session-start-hook` setup could export these for cloud sessions.

## Cost model (derived from code plus stated assumptions; not billed data)

**Workload assumed:** 1 admin and 8 employees, about 600 clients, 40 jobs per workday, 10 cold opens/day per user.

| Item | Estimate |
|---|---|
| Firestore reads | about 62k/day (about 1.4M/month); free tier 50k/day, so about $0.10–0.25/month |
| Firestore writes | about 1k/day (free tier 20k/day) |
| Largest read paths | admin calendar month listener (about 15k/day, overlaps the mirrors listener); employee calendars (about 23k/day); travel sweep (about 10.6k/day) |
| Places | session-token pricing, about $0 |
| Routes | about $15–40/month (I6) |
| Always-on instances | `minInstances: 1` on three callables, about $12–15/month; deliberate (cold-start fix) |

**At 100k clients:**
- Client paging and search stay flat: 50 per page; search reads at most 200 + 5.
- Token index storage is about 8–11 GB, about $1–2/month.
- `countClients` is about 100 reads per call.
- Only I8 and I10 scale badly.
- The first real ceiling is appointment volume, not clients: the 3000-doc calendar range cap is reached at about 97 jobs per workday.

## Security posture verified (no finding)

- **Rules:** signed-out callers get nothing. Invited and disabled users can only read their own doc. Self-update is limited to an allowlist, and `role`/`status`/`uid`/`email`/consent fields are refused.
- **Per-person subcollections:** emergency contact, tokens and presence are owner-only.
- **Employees and appointments:** an employee reads only `employeeIds` jobs, through three narrow `hasOnly` disjuncts. Images and notes require the parent assignment.
- **Admin-only and server-only data:** clients and buildings are admin-only, and every ledger, `wave` and `waveSyncQueue` deny all access.
- **Storage:** assignee create only, at most 10 MB, jpeg/png only, with a magic-byte trigger.
- **Callables:**
  - All 20 enforce App Check.
  - Admin callables use `assertAdminCall`.
  - `findAppointmentConflicts` refuses a non-admin any `employeeIds` but their own.
  - `changeEmployeeEmail`, `completeEmployeeSetup`, `completePasswordReset` and `deleteAccount` act only on the caller.
- **Push:** recipients come only from `employeeIds`, through `_canReachRecipient`. Disable purges tokens and the Live Activity card.
- **Wave:** the token lives only in Secret Manager.

## Verification (after this pass)

- `flutter analyze`: No issues found!
- `dart run tool/test.dart`: 4492 passed, 0 failed. That is 4 new: 3 shared day-slice cases and the boundary invariant.
- Under `TZ=America/Toronto`, the day-slice and overdue-review files pass.
- functions: lint clean; jest 116 suites, 2399/2399. That is 5 new: 3 shared day-slice cases, the overnight digest and the double period.
- `tool/check_rules.dart`: 0 violations.
- Emulator suite (auth, firestore, storage): pass, including the 21 role-isolation checks.
- No BOMs.

## Verification (after S1, S2, I6, I7)

- `flutter analyze`: No issues found!
- `dart run tool/test.dart`: 4493 passed, 0 failed.
- functions: lint clean; jest 116 suites, 2409/2409.
- `tool/check_rules.dart`: 0 violations.
- Emulator suite: every check passes, including the 21 role-isolation checks.
- S1 also has an ad hoc emulator run of the real enqueue → claim → second enqueue → commit sequence.
- No BOMs.
