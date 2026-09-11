# Codebase Audit — 2026-09-07

Scope: whole repo (`lib/`, `functions/`, `firestore.rules`, `storage.rules`,
`firestore.indexes.json`, `test/`, `.claude/rules/`, `pubspec.yaml`).
Baseline: `051a6b6d` (branch `redesgin`), working tree clean at start.

The previous audit (2026-09-05, all 33 findings closed) is archived at
`docs/archive/CODEBASE_AUDIT_2026-09-05.md`. Its carryover items — the Maps
billing cap, the Crashlytics re-check that needs a shipped build, the Wave
"Retry failed" press, and the Xcode `InfoPlist.strings` confirmation — are
**not** repeated here and remain open.

## Summary

- Scanned: 429 Dart files in `lib/` (73,153 LOC), 81 JS modules in `functions/`,
  355 Dart test files, 86 Functions test suites, both rules files.
- Auto-fixed (safe, in the diff): **1**
- Reported for your decision: **41** (⚠️ 0 pre-ship · 🔴 3 security · 🟠 5 bugs ·
  🔵 28 improvements · 🟡 5 code-quality/dead-code)
- Verification (observed, at baseline): `flutter analyze` **No issues found!** ·
  `flutter test` **3413 passed** · `functions` jest **1838 passed / 86 suites** ·
  `dart fix --dry-run` **Nothing to fix!** · `functions` ESLint clean.

**The static layer is pristine.** Zero unused files, zero unused providers, zero
unused dependencies, zero `TODO`/`FIXME`/`HACK` markers, zero BOMs, zero tracked
`android/` paths, and 11 of 12 convention-drift greps empty. Everything of
substance below came from the deep review, and **almost all of it is in the code
landed since 2026-09-05.**

### The one thing to take away

Eight findings — **S1, S2, B1, B2, B3, B4, B5, I7** — are on the crew
notes/photo surface shipped in the last four days. They share one root cause:
**the write path was gated and tested; the read/render path was not.** The
server-side rules for crew notes are sound (append-only, assignee-scoped,
`createdAt` pinned — all verified). The client half then undoes parts of it: the
field the rules protect is not the field that is displayed (S1), the bounded
read drops the wrong end (S2), and four independent defects govern how upload
state is shown (B1–B4).

## Status — 36 of 41 worked, 2026-09-07

Verification after the pass (observed, not carried forward):
`flutter analyze` **No issues found!** · `flutter test` **3502 passed / 0 failed** ·
`functions` jest **1848 passed / 86 suites** · `functions` ESLint clean.
(Baselines were 3413 / 1838 / 86.) 82 files touched, 9 new test files.

**Implemented: 31.** S1 S2 S3 · B1 B2 B3 B4 B5 · I1-I3 I5-I23 I26 I28 · D1 D3.
**Resolved by another finding: 1.** D2 (`pendingFor` gained a caller via B3).
**Not a defect / accepted by design: 3.** I24 (the fix is the `pictureCount`
anti-pattern) · I27 (readability only) · I10's guard-order sub-claim.
**Note only, deliberately unchanged: 2.** D4 D5.
**Open by design: 1.** I25 — do not fix until observed in the wild.
**Still open, needs YOU: 4 carried over.** The Maps billing cap, the
Crashlytics re-check (needs a shipped build), the Wave "Retry failed" press and
the Xcode `InfoPlist.strings` confirmation. **B5 is CLOSED** — it rode the same
day's `firestore:rules` deploy (`462a1907`, `docs/DEPLOYMENT.md` log), and
`firestore.rules` has been byte-identical to that commit since.

### Twelve deviations, and three findings that were WRONG as written

Recorded because the report is the thing a later session trusts:

- **I6 — the stated mechanism did not reproduce.** Reversing
  `notice_listener`'s dismiss-then-run does NOT kill the Undo's own notice: an
  end-to-end test passes under both orders, because `_show` removes the
  standing entry either way. The ordering is pinned on the banner's exit
  animation status instead. The end-to-end test is kept as the contract but is
  honestly not the biter.
- **I19 — `isLast` was DEAD.** `SettingsTile.isLast` is never read in `build()`
  at any of its 10 call sites, and the dividers were always explicit widgets, so
  the cascade computed a value that went nowhere. Deleted rather than
  restructured. `notifications_settings_card.dart` 183 -> 149 lines.
- **I10 — the guard-order "drift" is NOT a defect.** `waveSetImportSchedule`
  validating the `schedule` VALUE before the limiter is exactly what
  `.claude/rules/security.md` mandates. The misleading comment was replaced.
- **I5** — the mutating set is **14**, not 13; `restoreAppointmentStatus` was
  missing from the table AND the predicate.
- **I9** — arming the memo as suggested leaks a stale owner past a throw, and
  `_matchesCurrentOwner` is what stops one user's queued photos uploading under
  another identity. Scoped with a `finally`.
- **I12** — extracting the retry hid the `context.mounted` check from the
  analyzer (8 new infos). Each call site keeps a visible one-line guard; the
  stateful sheet correctly uses `State.mounted`, which was the original drift.
- **S3** — the gate cannot live in `drawer_catalog.dart`: `drawerGroups(isAdmin:)`
  is a pure function of a bool. Resolved in `app_nav_drawer.dart`. `TourSteps`
  must keep the push-time argument (it force-unwraps `keys[id]!`, so a
  disagreeing host is a crash) — the same exception `DayRouteScreen` documents.
- **I15** — routed through the existing `_scan.js` rather than adding
  `patchCollection`; six scripts already use that shape and one caller could not
  be expressed as a patch callback.
- **I16** — `customer_queries.js` left alone: routing it through
  `readWaveConnection` closes the require cycle that module exists to prevent.
- **I18** — extracted the two pure predicates only, not four derivations; the
  callbacks need `context`/`ref` and the gate's coverage landed via I7.
- **I14** — applied to 4 methods, not 3 (`delayAppointment` is the same shape).
- **B2** — `onRetry` is nulled for a crew viewer rather than rewired to
  `_addPhotos`; they re-add through the field record's own picker directly below.

### Two honest gaps left open

- `app_nav_drawer.dart:302-307` — the third copy of the employee-visibility
  ternary is still unpinned; the two screens are covered.
- `delete_account_dialog_test.dart`'s `'Cancel returns false'` still asserts
  only that the dialog closed. The coverage it implied now genuinely exists in
  `confirm_dialog_adaptive_test.dart`, on iOS. Worth a one-line rename.

## Decide first

These four are judgment calls, not mechanical fixes. Everything else in this
report has an unambiguous best answer.

1. **S1** — fixing attribution client-side (resolve the name from `authorId`) is
   one file; doing it properly server-side is a new trigger and a deploy. Pick.
2. **S2** — flipping the note order to descending is a one-line fix, but whether
   to also add a per-job note cap (a trigger) is a product call.
3. **B3** — what the crew photo cap should actually be. `maxImagesPerAppointment`
   is 10 per *form submission*; the crew path is per *job lifetime*. These may
   legitimately want different numbers.
4. **I24** — the +3 billed reads per detail sheet open. My recommendation is to
   **accept** it; the obvious fix is the `pictureCount` anti-pattern that has
   already bitten this repo once.

## ⚠️ Pre-ship checklist

**Empty.** Zero `TODO(pre-ship)` markers across `lib/`, `test/`, `functions/`,
`ios/` and both rules files; no App Check flip is pending
(`FirebaseAppCheck.instance.activate()` is intact and all 18 `onCall` sites
spread `APP_CHECK`). This confirms the 2026-08-14 note in `project-map.md` still
holds.

## Auto-applied cleanups (review the diff)

| File:line | Change | Why |
|---|---|---|
| `.claude/rules/error-handling.md:170` | Dropped the `CLI-RECENT` clause | The tag named `recent_clients_provider.dart`, deleted in `d3440af1`; zero code occurrences remain. That registry is declared exhaustive because notices no longer carry support codes, so a stale row misdirects Crashlytics triage. |

> Nothing else was auto-changed. No `.dart`, `.js` or rules file was touched.

## 🔴 Security findings

### S1 — Crew-note attribution is spoofable end to end · severity: medium · confidence: high  · **DONE**

- **Where:** `firestore.rules:521` (create rule) ·
  `lib/features/calendar/widgets/views/details_field_notes_view.dart:88,97`
  (render) · `lib/features/calendar/data/appointment_field_notes_store.dart:42-47`
- **Risk:** The rule pins `authorId == myDocId()`, but `authorId` is **written
  and never read** — its only non-generated reader is the line that writes it.
  The UI renders `authorName`, which is free-form and only length-bounded. An
  assignee can post `{text: "Customer refused the repair", authorId: <their own
  id>, authorName: "<a colleague>"}` and every reader, admin included, sees it
  under that colleague's name and avatar. On what the rules doc calls "the
  billable artifact", this is a false-attribution primitive.
  `field_notes_rules_test.dart:44` asserts this property in prose while the
  property does not hold in the app.
- **Fix:** Resolve the display name from `authorId` at render time against the
  roster map the detail surfaces already hold, falling back to the stored
  `authorName` only for an unknown id (removed staff). The server-side
  alternative is an `onDocumentCreated` trigger stamping `authorName` from
  `usersByUid`. Do not attempt this in rules alone. **Needs deploy:** no for the
  client fix; yes for the trigger route.

### S2 — The crew-note thread reads the OLDEST 200 notes · severity: medium · confidence: high  · **DONE**

- **Where:** `lib/features/calendar/data/appointment_field_notes_store.dart:50-63`
- **Risk:** `fetch` issues `.orderBy('createdAt').limit(200)` — **ascending** —
  with no paging and no server-side bound on how many notes a job may hold.
  Past 200 notes, nothing anyone writes on that job (the admin included) is
  visible in the app, and the only signal is a log-only warn. An assignee can
  reach that state deliberately with 200 trivial permitted writes, suppressing
  the field record. The same cap bites benignly on a genuinely busy job, with
  the same shape: the newest and most relevant notes are the ones dropped.
- **Fix:** Order `createdAt` **descending** under the same cap and reverse in
  Dart for display, so the cap drops the oldest; surface the truncation in the
  UI rather than only in Crashlytics. A per-job note bound would need a trigger.
  **Needs deploy:** no (client-only).

### S3 — Settings and the drawer still gate on the push-time role argument · severity: low · confidence: high  · **DONE (deviated — gate resolved in `app_nav_drawer.dart`, not `drawer_catalog.dart`)**

- **Where:** `lib/features/settings/screens/settings_screen.dart:125` ·
  `lib/features/navigation/domain/drawer_catalog.dart:14-30` ·
  `lib/routes/app_routes.dart:161-166`
- **Risk:** Rendering only. `isActiveAdminProvider` was introduced for exactly
  this staleness and has three consumers (`DayRouteScreen`, the `/history`
  `AdminOnly` gate, `_canRecordFieldWork`); Settings' admin sections and the
  drawer's admin rows still key on the route argument, which a stale back stack
  can carry falsely. Everything behind them is re-verified server-side (Wave
  callables open with `assertAdminCall`, `/clients` reads are `isAdmin()`-only,
  `watchAllUsers` is admin-gated), so the worst outcome is an admin-shaped UI
  that fails `permission-denied`. Flagged because a *future* admin-only Settings
  control that is not independently server-gated would inherit the hole silently.
- **Fix:** `widget.role == 'admin' && ref.watch(isActiveAdminProvider)`, the
  shape `DayRouteScreen:107` already uses; update the "three consumers" note in
  `.claude/rules/appointments.md`. **Needs deploy:** no.

## 🟠 Bug findings

### B1 — A permanently-failed crew photo batch erases its own error tile · severity: medium · confidence: high  · **DONE**

- **Where:** `lib/features/calendar/widgets/views/details_view_leaf_widgets.dart:290-315`
- **Problem:** `failure`/`failedCount` are captured in `build()` **outside** the
  `ValueListenableBuilder` added by `916e27ab`. `PhotoUploadNotifier._failures`
  is a plain `Map` with no listenable and `photoUploadNotifierProvider` returns a
  stable singleton, so nothing rebuilds on `reportFailure`. When every file in a
  batch fails permanently, `_publishPending()` drops the pending count to 0, the
  builder re-runs with a stale `failedCount` of 0, `hasPhotos` is false, and the
  section, the error tile and Retry all vanish for the life of that sheet. The
  partial-success case is masked because a successful upload forces a real
  rebuild — only an all-fail batch reproduces it.
- **Fix:** Read the failure inside the builder and make it reactive — listen
  `latestFailure` (already a `ValueNotifier`) alongside `pending`, or give
  `_failures` its own notifier.

### B2 — Retry on a failed crew photo is a dead button that destroys the failure record · severity: medium · confidence: high  · **DONE (deviated — `onRetry` nulled for crew rather than rewired to `_addPhotos`)**

- **Where:** `lib/features/calendar/widgets/views/details_view_body.dart:171-175`
  with `details_view_leaf_widgets.dart:333-340`
- **Problem:** `onRetry` is `notifier.enterEditing`, and the handler calls
  `notifier.clearFailure(appointmentId)` first. But
  `event_details_view.dart:115` computes `showEdit = state.isEditing &&
  widget.showActions`, and `showActions` is false for a non-admin assignee — so
  `enterEditing` renders the identical read view. Since `c17fda1f`/`916e27ab`
  the crew are the people who start these uploads, so they are the ones who meet
  the tile: tapping Retry deletes their only in-app trace of the loss and offers
  no way to re-add the photos.
- **Fix:** For a crew viewer wire `onRetry` to `DetailsFieldRecordView._addPhotos`
  (re-pick); or pass `null` when `!showActions` so no dead Retry renders. Do not
  `clearFailure` ahead of an action that cannot succeed.

### B3 — The crew photo path has no image cap at all · severity: medium · confidence: high  · **DONE**

- **Where:** `lib/features/calendar/widgets/views/details_field_record_view.dart:116-132`
- **Problem:** `_addPhotos` calls `pickAppointmentImages` and hands the whole
  result to `uploadInBackground`. The 10-image bound lives only in
  `AppointmentFormConcerns.addImages:259-266`, which this path never touches.
  Two consequences: (a) `.claude/rules/images.md` justifies the two hundreds
  (`AppointmentImagesStore.scanLimit` 100, `PICTURE_COUNT_WARN_CAP`) on the
  premise that "the picker's own `maxImagesPerAppointment` (10) means only a
  modified client gets near either" — that premise no longer holds, and past 100
  the sheet caps while Storage bytes keep accruing; (b) it corrupts the admin's
  form, because `addImages` early-returns on `remaining <= 0` **with no notice**,
  so a job the crew put 12 photos on makes the admin's Add-photos button a
  silent no-op.
- **Fix:** Clamp in `_addPhotos` against the job's current count using the same
  `maxImagesPerAppointment` owner, and surface a notice when a pick is trimmed —
  on both paths.

### B4 — The photos section blinks out on every successful crew upload · severity: low · confidence: medium  · **DONE**

- **Where:** `lib/features/calendar/widgets/views/details_view_leaf_widgets.dart:304-315`
- **Problem:** On a job with no prior photos, `_appendLinks` starts an **async**
  `_loadStoredPictures`, then `_publishPending()` drops the pending count
  synchronously ahead of that read landing. In the gap `existingImages`,
  `newImages`, `failedCount` and `pendingCount` are all empty/zero, so the
  section collapses to `SizedBox.shrink()` and reappears a Firestore round trip
  later — the crew watch their photos disappear at the moment the upload
  succeeds. Same root cause as B1, on the happy path. (Confidence is medium on
  the window's duration, which I could not time without running the app; the
  ordering is verified in code.)
- **Fix:** Keep the section mounted while a load is in flight, or hold
  `pendingCount` until the refreshed list is adopted.

### B5 — `fieldNotes.authorName` is capped tighter than the write path can produce · severity: low · confidence: high  · **DONE — deployed 2026-09-07 (`462a1907`)**

- **Where:** `firestore.rules:520` (cap 200) written from
  `details_field_record_view.dart:56` (`currentUserNameProvider`)
- **Problem:** `displayEmployeeName` → `composeEmployeeName` joins two halves
  each capped at `TextLimits.employeeNameHalf` (100) with a space, so the value
  legitimately reaches **201**; the `users.name` fallback is capped at **250** in
  rules (`firestore.rules:176`) and the email fallback higher still. All three
  exceed the 200 the create rule enforces, and `isBoundedString` is a hard
  `size() <= maxLen`. A user in that range cannot post a crew note at all —
  every attempt is `permission-denied`, surfaced as a generic cause with no field
  to correct. This is the exact inversion `.claude/rules/employees.md` warns
  against, and the `users.name` cap of 250 was set for this reason.
- **Fix:** Raise the `authorName` cap to 250 to match `users.name`, and add the
  pair to `test/core/validators/text_limits_test.dart`, which already reads
  `firestore.rules` back for this class of drift. **Needs deploy:** yes (rules).

## 🔵 Areas to improve

Ordered by payoff. The dominant shape is the one this project already has a name
for: **a dependency that is mocked and never asserted greps as covered.** Six of
the eight high-impact findings are that.

### I1 — `showConfirmDialog`'s iOS branch never has its return value asserted · impact: high · confidence: high  · **DONE**

- **Where:** `lib/shared/widgets/dialogs/confirm_dialog.dart:32,38,74`
- **Opportunity:** Swap the two `Navigator.pop(ctx, false/true)` calls, or change
  `result ?? false` to `?? true`, and **Cancel deletes** — an appointment, a
  client, or the account. iOS is the only shipping platform, so this is the
  branch that always runs. The only iOS-forcing test
  (`confirm_dialog_adaptive_test.dart:21`) **discards the future**, asserting
  only that the dialog appears. `delete_account_dialog_test.dart` has a case
  titled `'Cancel returns false'` whose helper returns before the unawaited
  handler assigns, so the value is always `null` — and it runs Material anyway.
- **Improvement:** In the existing adaptive file, pump under
  `ThemeData(platform: TargetPlatform.iOS)`, await the future, tap Cancel then
  Confirm, assert `false` then `true`.

### I2 — The crew-notes write contract is pinned on both sides, never against each other · impact: high · confidence: high  · **DONE**

- **Where:** `lib/features/calendar/data/appointment_field_notes_store.dart` (64
  lines, zero test references)
- **Opportunity:** The rules demand exactly
  `hasOnly(['text','authorId','authorName','createdAt'])` with `createdAt ==
  request.time`, and `field_notes_rules_test.dart` pins that by reading the rules
  *text*. The map the client actually sends is asserted nowhere — the only
  exercise stubs `fieldNotes.add(any())` with no `captureAny` and no `verify`.
  Rename a key, add a fifth, or swap `serverTimestamp()` for a client `DateTime`
  and every crew note fails `permission-denied` in production while both suites
  stay green. The read path is untested too, and the "a note write never touches
  the parent" contract is unpinned — though its twin **is** pinned for images.
  The asymmetry with `AppointmentImagesStore` is the tell.
- **Improvement:** Capture the map passed to `add()`, assert its exact key set
  and that the parent was not written; one test for `fetch()`'s ordering and cap
  warn.

### I3 — `ImagePickerService`'s compression arguments are stubbed and never verified · impact: high · confidence: high  · **DONE**

- **Where:** `lib/core/images/image_picker_service.dart:11-13,21-24,38-40`
- **Opportunity:** `maxWidth/maxHeight: 1600` + `imageQuality: 70` is the **only**
  downscale in the app. Lose them and full-res camera JPEGs exceed
  `maxUploadBytes` → `ImageUploadFailureTooLarge` → the staged file is **deleted**
  and the technician's photo is gone behind a "too large" badge. The test file
  contains zero `verify(` and zero `captureAny`; `maxImageDimension` appears
  nowhere in `test/`.
- **Improvement:** One `verify(() => picker.pickImage(..., maxWidth: 1600,
  maxHeight: 1600, imageQuality: 70)).called(1)`.

### I4 — No test keeps colleagues' jobs off an admin's home-screen widget · impact: high · confidence: high  · **DONE**

- **Where:** `lib/features/home_widget/application/widget_sync_service.dart:253-261`
- **Opportunity:** The admin branch reads the business-wide
  `appointmentsInRangeProvider`, and `a.employeeIds.contains(identity.docId)` is
  the only thing keeping every colleague's client name and address off an admin's
  iOS home/lock screen. `grep employeeIds test/features/home_widget/` → 0 hits.
  The Siri twin's equivalent guard **is** covered, which is what makes this a gap
  rather than a choice.
- **Improvement:** Read `widgetPayloadProvider` as admin with a range containing
  one job assigned to someone else; assert it is absent.

### I5 — The repository's static write-path guard is blind to 4 of its 13 public writes · impact: high · confidence: high  · **DONE (deviated — the set is 14, not 13)**

- **Where:** `test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart:346-351`
- **Opportunity:** Root `CLAUDE.md` leans on this test to make a missed
  `_patchWindow`/`_notifyLocalWrite` "a test failure rather than a silent one".
  Its `mutates()` predicate scans for `.set(`/`.update(`/`.delete(`/
  `batch.commit`/`runTransaction`. Four public writes contain none of those
  tokens — `appendAppointmentPictures`, `removeAppointmentPictures`,
  `appendFieldNote` (all delegating to a store) and **`restoreAppointmentStatus`**
  (via `httpsCallable`, and in neither the table nor the static set). So the
  guard whose purpose is catching the *next* forgotten method no longer covers
  the two newest shapes in the file — exactly what the last three commits added.
  Separately, deleting `_notifyLocalWrite()` from `appendFieldNote` fails no test.
- **Improvement:** Redefine `mutates()` as "public member returning
  `Future<void>`" — that set is exactly the 13 writes and cannot be evaded by a
  new delegation — then add `restoreAppointmentStatus` to `_writeCases`.

### I6 — The mark-complete Undo, the app's only undo, is untested end to end · impact: high · confidence: high  · **DONE (deviated — the dismiss-then-run claim did NOT reproduce; pinned differently)**

- **Where:** `details_view_body.dart:252-274` ·
  `firebase_appointments_repository.dart:678-702` · `notice_listener.dart:266-277`
- **Opportunity:** `restoreAppointmentStatus`, `successWithAction` and
  `NoticeAction` each have **0** hits in `test/`. Three unpinned behaviours: the
  client-side `ArgumentError` rejecting a terminal or off-allowlist
  `previousStatus`; the `_patchWindow` call; and `notice_listener`'s load-bearing
  **dismiss-then-run** ordering — reverse it and the Undo's own success notice is
  killed by the outgoing one, so the user taps Undo and sees nothing happen. The
  server callable is well tested; this is the client half alone.
- **Improvement:** Two repository unit tests plus one notice test that the action
  runs after dismissal.

### I7 — The crew's only write surface has no test, and its gate's admin clause is unpinned · impact: high · confidence: high  · **DONE**

- **Where:** `lib/features/calendar/widgets/views/details_field_record_view.dart:43-113`
  · `details_view_body.dart:210-218`
- **Opportunity:** `DetailsFieldRecordView`, `error_introSaveFieldNotes` and
  `APPT-FIELDNOTE` have **0 hits** in `test/`. Untested: the `_isSaving`
  reentrancy guard, the `identity == null` branch, the `guardedOffline` bail and
  the success `ref.invalidate`. A double-tap posts the note **twice into an
  append-only collection the crew cannot edit or delete**. The gate is partly
  covered under a caller's name, but its first line —
  `if (ref.watch(isActiveAdminProvider)) return false;` — is not: no test sets up
  an admin who is also an assignee, so deleting it fails nothing.
  `.claude/rules/appointments.md` already flags this as the risky clause.
- **Improvement:** Hold `appendFieldNote` on a `Completer`, tap Post twice,
  assert one call; add two gate cases to the existing actions-test harness.

### I8 — `applyLocationSharing`, the documented "one owner" of write-plus-teardown, has no test · impact: high · confidence: high  · **DONE**

- **Where:** `presence_sync_controller.dart:49` · `location_sharing_view.dart:88-90`
- **Opportunity:** `applyLocationSharing`, `LocationSharingView` and
  `error_introSaveLocationSharing` all have 0 hits in `test/`. If the
  `presence.unregister()` half is dropped, the phone keeps uploading fixes after
  the technician turns sharing off. The view's `cleared ? locationCleared :
  locationPaused` branch is what stops the app claiming location history was
  erased when `unregister()` returned false. Compounds with I13.
- **Improvement:** Assert `unregister()` ran on disable; pump the view with
  `unregister()` stubbed false and assert the "paused" notice.

### I9 — Photo staging pays 3 `users` reads per batch · impact: medium · confidence: high  · **DONE (deviated — memo scoped with a `finally`; arming it as suggested leaks a stale owner)**

- **Where:** `lib/features/calendar/data/appointment_image_upload_service.dart:81,99,300`
  (fix site `:458`)
- **Opportunity:** `_stageAndRun` resolves the queue owner three times before the
  memo is armed — `_currentOwner()` at `:82`, `_publishPending()` at `:99`
  (outside the drain, so `_drainOwnerResolved` is still false), and
  `drainPending()` at `:300`. Each is a real `users where uid == … limit 1`
  query. So every staged photo batch costs **3 billed reads where 1 would do**,
  plus 1 per `clearPending()` and per drain. The module's own comment at `:350`
  states the rule it is violating. Pre-existing, but the diff made it hot:
  `DetailsFieldRecordView._addPhotos` now uploads directly from the crew's sheet.
- **Improvement:** In the provider at `:458`, try the warm cache first — the exact
  idiom `activeUserIdentityProvider:32` already uses:
  `repo.cachedUserDocId(uid) ?? (await repo.findUserByUid(uid))?.id`.
  `watchUserDoc` populates that cache on the same singleton, so this takes the
  normal path to zero reads.

### I10 — Five Wave callables hand-spell `assertAdminCall` · impact: medium · confidence: high  · **DONE (the order "drift" sub-claim: NOT A DEFECT)**

- **Where:** `functions/wave/callables.js:109-113,190-194,273-277,336-340,384-388`
- **Opportunity:** Each is the byte-identical body of `assertAdminCall`
  (`functions/security.js:242-249`). Every other admin callable module imports
  the composer; `wave/callables.js` is the only one that does not. `security.js`
  exists because three `assertAdmin` gates once proved deletable with all tests
  green — so a future tightening reaches everything except the accounting
  integration. Drift has already started: `waveSetImportSchedule:342-345`
  validates between the payload check and the limiter, contradicting the order
  `waveGetConnection:195` documents in a comment.
- **Improvement:** `const uid = await assertAdminCall(req, new Set([...]));` per
  callable. `assert_admin.test.js` already pins the composer.

### I11 — The employee-visibility ternary has both arms stubbed identically · impact: medium · confidence: high  · **DONE (drawer copy still unpinned)**

- **Where:** `main_calendar_screen.dart:286-292` · `day_route_screen.dart:107,113-115`
  · `app_nav_drawer.dart:302-307`
- **Opportunity:** `isAdmin ? appointmentsInRangeProvider : myAppointmentsProvider`
  is the client half of a documented critical invariant, and the tests override
  **both** providers with the same stream — so flipping the ternary breaks
  nothing.
- **Improvement:** One test overriding the two with *different* lists, asserting
  an employee-scoped screen renders only `myAppointments`.

### I12 — Busy-conflict force-through retry: 3 copies, already drifted · impact: medium · confidence: high  · **DONE (deviated — each call site keeps a visible mounted check)**

- **Where:** `add_appointment_sheet.dart:222-234` · `details_edit_body.dart:347-359`
  · `details_view_body.dart:317-336`
- **Opportunity:** An identical 13-line flow whose invariant — a mounted check
  after *both* awaits — is re-derived three times, and the copies already
  disagree: the first uses `!mounted`, the other two `!context.mounted`.
- **Improvement:** Hoist `retryPastBusyConflict<T>` into
  `widgets/dialogs/busy_conflict_dialog.dart`, beside the dialog all three call.

### I13 — The location-sharing toggle is duplicated across two shipped surfaces · impact: medium · confidence: high  · **DONE**

- **Where:** `settings_screen.dart:305-325` and `location_sharing_view.dart:35-58`
- **Opportunity:** Not a pattern but the same operation — same
  `applyLocationSharing` call, same `'ME-SAVE location sharing failed'` tag, same
  intro key. `settings_screen.dart:393` renders `LocationSharingView`, so both
  ship. Since notices stopped carrying support codes that tag is the only way
  Crashlytics finds this operation, and neither copy has a test (I8).
- **Improvement:** Put the guard/log/notice shell beside `applyLocationSharing`;
  each call site keeps only its `setState` bracketing.

### I14 — `isSaving: false` spelled twice per method instead of once in a `finally` · impact: medium · confidence: high  · **DONE (4 methods, not 3)**

- **Where:** `event_details_controller.dart` — `cancelAppointment:417`,
  `_setStatusOnRepo:458`, `deleteAppointment:772`
- **Opportunity:** Six spellings of one invariant. As written, an early `return`
  added to any `try` body leaks the flag and permanently disables that sheet's
  actions.
- **Improvement:** A `finally` — three methods, two lines each become one. Not an
  extraction.

### I15 — Six backfill scripts read the whole `clients` collection unpaged · impact: medium · confidence: high  · **DONE (deviated — routed through the existing `_scan.js`, no new `patchCollection`)**

- **Where:** `backfill-client-address-street.js:180` ·
  `backfill-client-name-digits.js:154` · `backfill-client-name-with-phone.js:271`
  · `backfill-client-phone-formatting.js:127` · `backfill-clients-archived.js:78`
  · `restore-client-name-halves.js:281` — all `await db.collection("clients").get()`.
  Separately `backfill-search-tokens.js:82-98` hand-writes the loop
  `functions/scripts/_scan.js` owns and six other scripts import — that file's own
  header says it "was hand-written SIX times across five scripts"; this is the
  seventh.
- **Opportunity:** `backfill-search-tokens.js:74-77` states the hazard the six
  ignore: a full-collection `.get()` is "the run most likely to exceed the gRPC
  deadline or the heap part-way through", leaving a half-patched collection
  indistinguishable from an unpatched one. These scripts produce the migration
  numbers this project makes irreversible calls on.
- **Improvement:** Point `backfill-search-tokens.js` at `scanByName`; add one
  `patchCollection(...)` beside `commitInBatches` in `_batch.js`. Each script
  keeps its own `patchFor` and report prose.

### I16 — Wave connection read + `businessId` coercion: 7 reads, 6 coercions, two partial owners · impact: medium · confidence: high  · **DONE (deviated — `customer_queries.js` left alone to avoid a require cycle)**

- **Where:** `wave/callables.js:116,204-213,353-358,397-405` ·
  `wave/triggers.js:250-266` · `wave/sync_run.js:37-39` · `wave/customer_queries.js:19-21`
- **Opportunity:** `data && typeof data.businessId === "string" ? … : ""` verbatim
  in six places; `importSchedule` coerced twice with only one applying the
  `IMPORT_SCHEDULE_SET` fallback. `waveRetryFailedJobs:282-288` already carries a
  comment about being repaired for this exact drift class — that fix landed on
  one copy of four.
- **Improvement:** Widen `sync_run.js`'s `readWaveBusinessId` into
  `readWaveConnection()` returning `{ref, data, businessId, importSchedule}`,
  keeping the old name as a one-line wrapper.

### I17 — `AccountSetupScreen`'s two special-cased failure branches never run · impact: medium · confidence: high  · **DONE**

- **Where:** `account_setup_screen.dart:223,231-240`
- **Opportunity:** If `AuthFailureSetupAlreadyComplete → _routeIntoApp()`
  collapses into the generic banner, an invited employee whose password change
  *did* land is stuck on a dead-end screen holding a session they cannot escape —
  precisely what the `invited` carve-out exists to prevent. Both variants grep as
  covered because the *service* test asserts the throw; the screen that branches
  on them covers only offline, consent, sign-out and `AuthFailureUnknown`.
- **Improvement:** Stub `completeAccountSetup` to throw each variant; assert
  route-into-app vs. field error.

### I18 — Over-long methods (measured) · impact: medium · confidence: high  · **DONE (deviated — extracted the two pure predicates only)**

| method | lines | file lines |
|---|---|---|
| `add_event_controller.dart:299` `submit` | 153 | 457 |
| `details_view_body.dart:68` `build` | 140 | 662 |
| `event_details_controller.dart:514` `save` | 134 | 820 |
| `notifications_settings_card.dart:53` `build` | 130 | **183** |
| `notice_listener.dart:195` `build` | 124 | 319 |
| `employee_picker.dart:58` `build` | 116 | 407 |

- **Opportunity:** Best value is `details_view_body.build`: its first ~55 lines
  are pure permission/availability derivation (`onPushBack`, `bookAgain`,
  `onStart`, `canRecordFieldWork`) reachable only through a widget pump.
  `_canRecordFieldWork` is already a `static bool` in that file; the same
  treatment for the other three makes them unit-testable — which is I7's fix —
  and leaves `build()` as the widget tree.
- **Improvement:** Extract those four derivations only. I do **not** propose a
  pipeline for `submit`/`save`; one instance is not three and a rewrite is the
  wrong trade. The numbers are for the record.

### I19 — Settings switch tile: 4 instances, already drifted on a touch-target property · impact: medium · confidence: high  · **DONE (deviated — `isLast` was DEAD, deleted rather than restructured)**

- **Where:** `security_settings_card.dart:36-41` ·
  `notifications_settings_card.dart:141,161,~80`
- **Opportunity:** The security card adds `materialTapTargetSize: shrinkWrap`,
  the three notifications tiles do not — so two halves of one Settings screen
  render switch rows at different heights, and that card's own comment explains
  why it matters. Second cost in the same file: `isLast` is a hand-computed
  cascade, so a fifth toggle means editing every earlier one.
- **Improvement:** A `SettingsSwitchTile` beside `SettingsTile`; build the tiles
  into a `List<Widget>` and let the last carry `isLast`.

### I20 — `streamForUid`'s error branch is untested · impact: medium · confidence: high  · **DONE**

- **Where:** `lib/core/providers/firebase_providers.dart:48-53`
- **Opportunity:** The loading branch is covered three times; the error branch —
  "an errored uid must propagate, or a `.value` read reports *signed out* for a
  broken auth stream" — is not. Regressed, a broken auth stream reads as
  signed-out at five call sites including `account_status_provider`, which feeds
  `isAccountDeletionSignal`.
- **Improvement:** One `addError` case.

### I21 — `clearPending()`'s body never executes in any test · impact: medium · confidence: high  · **DONE**

- **Where:** `appointment_image_upload_service.dart:329-338`
- **Opportunity:** The per-file `_deleteQuietly` loop is what stops one user's
  staged job photos surviving sign-out on a shared handset. Drop it and
  `_store.clearAll()` still empties the index, so nothing looks wrong. The sole
  `test/` reference is a fake that records a label string — which is exactly why
  the ordering assertion in `device_deregistration_test.dart:95` makes it grep as
  covered.
- **Improvement:** One test asserting the staged files are gone.

### I22 — A documented data-integrity rule with a comment, no test, and in the wrong layer · impact: medium · confidence: high  · **DONE**

- **Where:** `personal_block_clash_dialog.dart:530-554` (`_replaceAssignee`)
- **Opportunity:** The comment says a legacy `confirmed` status "would be written
  back verbatim and rejected by the rules as an opaque permission-denied on an
  ordinary-looking swap", and the code calls `AppointmentStatus.storedRaw`. The
  480-line test file never mentions `confirmed` or `storedRaw`, so deleting that
  line fails nothing — the "a long comment is a spec" shape. It is also a *pure*
  function sitting private in an 804-line widget file, while its three siblings
  that must agree with it all live in the tested `calendar/domain/assignee_resolver.dart`.
- **Improvement:** Move it there (the file already imports from it) and add one
  unit test seeding `status: 'confirmed'`.

### I23 — Two more small permission/role gates with no test · impact: medium · confidence: high  · **DONE**

- **Where:** `sign_in_controller.dart:228` · `splash_screen.dart:74-80`
- **Opportunity:** `resumeAfterSignUp`'s `!employee.isActive` gate — every test in
  that group returns `_activeDoc`, so deleting the gate walks a still-`invited`
  person into the hub where every rules gate denies them. And the warm-`AuthCache`
  fast path hard-codes `isAdmin: false`; "fixing" it to `cached.isAdmin` would
  source role from device storage, which both `CLAUDE.md` and `security.md`
  forbid, with nothing failing.
- **Improvement:** One case each.

### I24 — Each detail-sheet open costs ~3 extra billed reads · impact: low · confidence: high (cost), low (that it matters)  · **NOT A DEFECT — accepted by design (the fix is the `pictureCount` anti-pattern)**

- **Where:** `firestore.rules:512` + `details_view_body.dart:178`
- **Opportunity:** `DetailsFieldNotesView` renders unconditionally, so opening any
  job fires a `fieldNotes` query. Firestore bills a minimum of 1 read even for
  zero docs, and the read rule evaluates `isAdmin()` (a `usersByUid` get) plus,
  for a non-admin, `parentAppointment()` — rules `get()`s are billed reads. So a
  technician's sheet open goes from ~1 query + 2 rule gets to ~2 + 4. At 30
  opens/day that is ~90 extra reads/day/user.
- **Improvement:** **None — accept it.** The obvious gate, a denormalized
  `noteCount` on the parent, is the exact `pictureCount` anti-pattern
  `.claude/rules/images.md` records as having already bitten this codebase (a
  debounced counter gating a read made a just-added photo invisible). Log it as
  an accepted per-open cost, as the images read already is.

### I25 — A cold-start Day Route can open and immediately discard one listener · impact: low · confidence: medium  · **OPEN by design — do not fix until it is observed**

- **Where:** `day_route_screen.dart:105`
- **Opportunity:** The gate fails closed while the user doc is unsettled, so an
  admin arriving before `currentUserDocProvider` settles subscribes to
  `myAppointmentsProvider` and then flips, tearing down one week-bucket query.
  Reachable only on a cold start landing straight on this screen (push/widget/Siri
  tap) — `AccountExitListeners` and `AppSyncListeners` keep the provider warm
  otherwise. The screen's own new test overrides `myAppointmentsProvider`
  specifically "to cover the one-frame window", which is the tell that it exists.
- **Improvement:** Only if it ever shows up: gate on the settled `AsyncValue`
  rather than the collapsed bool. Do **not** relax the fail-closed default.

### I26 — A swallowed cause makes an upload-queue log misdiagnose · impact: low · confidence: high  · **DONE**

- **Where:** `appointment_image_upload_service.dart:357-364`
- **Opportunity:** `_currentOwnerOrNull` catches everything and returns `null`
  with no log; `_attempt:229-234` then logs "owner mismatch". When the real cause
  was "signed out", "no users doc" or a transient Firestore failure, the operator
  is told another *account* staged those photos.
- **Improvement:** One `_logger.warn` inside that catch.

### I27 — `travel_utils.js` is the one large server module with no policy sibling · impact: low · confidence: high  · **NOT IMPLEMENTED — noted precedent only, payoff is readability**

- **Where:** `functions/travel_utils.js` (887 lines)
- **Opportunity:** It mixes pure decisions, the Routes HTTP client and
  orchestration, where the pattern is followed everywhere else
  (`notification_policy` ↔ `notification_utils`, `maintenance_policy` ↔
  `maintenance`).
- **Improvement:** Noting the precedent, **not** urging the split — the pure half
  is already exported and well tested, so the payoff is readability only.

### I28 — Verified-untested, one line each · impact: low · confidence: high  · **DONE (5 of 5)**

`DetailsEditBody:455-460,514-517` Busy branches (0 hits for `DetailsEditBody` in
`test/`) · `settings_screen.dart:265-328` toggle `guardedOffline`
(`notifications_settings_card_test.dart:52` asserts its own injected closure,
never the real handler) · `personal_block_clash_dialog.dart:505-515`
revert-on-failure (zero `thenThrow` in that file) · `wave_settings_section.dart:65-71`
`_blockedOffline`, one of the two documented carve-outs (that test file has no
`isOfflineProvider` at all) · `account_exit_controller.dart:70-72` guard release
(the test named "…releases the guard" never re-invokes to prove it) ·
`appointment_images_store.dart:55` `remove`'s empty-`docId` guard (its `append`
twin is tested) · `ClientArchiveBusy`, the only unexercised member of its family.

## 🟡 Code-quality / dead code

### D1 — Five orphaned l10n ARB keys · impact: low · confidence: high  · **DONE**

Zero real callers each (the only hits are the gitignored generated getters in
`lib/l10n/.gen/`). EN and FR are both 865 keys with no drift and full `@key`
coverage.

| ARB line (EN / FR) | Key | Orphaned by |
|---|---|---|
| `app_en.arb:1267` / `app_fr.arb:265` | `clients_noHistoryYetForYou` | `c9e5812e` (History admin-only) |
| `app_en.arb:3972` / `:847` | `clients_exactMatch` | `7159fd26` (dropdown, no section headers) |
| `app_en.arb:3976` / `:848` | `clients_searchResults` | `7159fd26` |
| `app_en.arb:3980` / `:849` | `clients_closestNumbers` | `7159fd26` |
| `app_en.arb:3988` / `:851` | `clients_matchCount` | `7159fd26` |

Four of the five were added and orphaned within one release. Remove EN + FR + the
`@key` block in lockstep and run `flutter gen-l10n`.

### D2 — `PhotoUploadNotifier.pendingFor` has never had a caller · impact: low · confidence: high  · **RESOLVED — `pendingFor` gained a real caller via B3**

`lib/features/calendar/application/photo_upload_notifier.dart:51`. `git log -S`
returns only the commit that introduced it. **Do not delete it blindly** — B3's
suggested fix would use exactly this method to read the job's current pending
count. Resolve B3 first, then delete it only if unused.

### D3 — `HistoryPager.fetchPage`'s `employeeId` has no non-null caller · impact: low · confidence: medium  · **DONE (documented in `.claude/rules/clients.md`, parameter kept)**

`appointment_history_providers.dart:25` · `appointment_history_view.dart:132,430`
(`employeeId: null` hard-coded). `c9e5812e` removed per-employee scoping from the
view. The **repository**-level `employeeId` is confirmed-intentional — it mirrors
the deployed `historyScope` guard in `functions/indexed_search.js` and must stay.
What is not covered by that note is the intermediate `HistoryPager`/
`HistorySearchKey` facade. Either drop the parameter there, or add a one-line
note to `.claude/rules/clients.md`. Do **not** touch
`AppointmentsRepository.fetchHistoryPage`/`searchHistory`.

### D4 — The `isAdmin: false` path into `HistoryScreen` is unreachable · impact: low · confidence: medium  · **NOTE ONLY — defence in depth is deliberate**

`lib/routes/app_routes.dart:131-135`. `/history` is wrapped in `AdminOnly` and the
drawer only offers the row to admins, so the non-admin branches inside
`HistoryScreen` and `AppointmentHistoryView` are dead in practice. The
defence-in-depth is deliberate — `AdminOnly` exists precisely for a forged
argument or stale back stack — so this is a **note, not a cleanup**: nobody should
"simplify" `AdminOnly` away later.

### D5 — `main.dart:158-160` passes an Android App Check provider · impact: low · confidence: high  · **NOTE ONLY — on a "Do not touch" line**

`providerAndroid: kDebugMode ? AndroidDebugProvider() : AndroidPlayIntegrityProvider()`.
Android was deleted 2026-08-05, so this argument can never take effect. It sits on
a **"Do not touch"** line (App Check activation) — reported as dead weight,
**not** proposed for edit.

## Notes / uncertainties

- **Verified intentional, not reported as findings:** the `Color`/`EdgeInsets`
  exemptions in `.claude/rules/frontend.md:28`; the Material fall-through branches
  in `lib/core/adaptive/*` (test-covered, since `isCupertino` reads
  `Theme.of(context).platform` so tests can force either look); the three
  sanctioned `ScaffoldMessenger` sites; the `_canRecordFieldWork` negative-gate
  asymmetry.
- **Confirmed sound and worth recording:** `mayReadHistoryDoc`
  (`functions/indexed_search.js:156-162`) now re-verifies a non-admin against the
  doc's real `employeeIds` rather than trusting client-written
  `historySearchScopes` — that closed a genuine gap in this window.
  `assertActiveCall`'s `{...data, uid: req.auth.uid}` spread order puts the
  platform-verified uid last, so a writable `usersByUid.uid` cannot shadow it.
- **Net read cost went DOWN** this window: deleting the Recents section removed a
  60-doc read on every add-appointment sheet open, outweighing I9 and I24
  combined.
- **No exact-clone duplication exists.** An 8-line fingerprint scan over all 426
  Dart + 81 JS source files found one 3+-file group, and it was an import block.
  Every duplication finding above is a *semantic* copy that survived that scan.
- **Not re-verified here:** the four carryover prod-state items from the archived
  rolling audit (Maps billing cap, the Crashlytics re-check needing a shipped
  build, the Wave "Retry failed" press, the Xcode `InfoPlist.strings`
  confirmation). They need production or a Mac, not the tree.
- B4's confidence is medium on the *duration* of the blink window; the ordering
  that causes it is verified in code.

---

Findings are worked by id. Pre-ship items and anything needing a prod deploy or
backfill are never auto-implemented — here that is **B5** (rules cap, needs a
rules deploy to take effect) and the trigger routes optionally chosen for S1/S2.
