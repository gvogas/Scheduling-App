# UX & Performance Review — 2026-10-20

Scope: whole app, read from the user's side — admin dispatching from a phone,
technician in the field. Not a security/dead-code audit (that was yesterday,
`CODEBASE_AUDIT_2026-10-19.md`). Baseline: `dev` @ `942dd21`, clean tree.
Static read only — Flutter is not installed in this container, so nothing was
run on a device. Every `file:line` below was checked against the source.

Ids are stable (`U` = user experience, `P` = performance, `A` = accessibility,
`C` = copy/consistency). Mark a row closed rather than deleting it.

## Implementation status (2026-10-20)

All 69 findings worked the same day (`/audit-do`): **65 DONE** (13 deviated as annotated; U11 run-scope half not-a-defect), **2 no-change by the report's own call** (P6, P7), **1 deliberate** (C26), **1 OPEN** needing index work (P5; P4's structural half likewise), and **P1 OPEN — needs the backend deploy before the next app build**. Verification: `flutter analyze` **No issues found!** · `dart run tool/test.dart` **4391 passed, 0 failed** · `tool/check_rules.dart` 0 violations · functions lint clean · jest **113 suites, 2336/2336**. Not touched: P5 and the structural half of P4 need `(isPersonal, …)` composite indexes plus a legacy backfill before the query change — your call. Follow-up noted by the P2 work, not changed: `retryStream` (`core/utils/retry.dart`) only unwinds at the next `yield`, so a disposed range listener stays open until its next snapshot.

## Summary

- 69 findings after de-duplicating five reviewers (26 UX · 10 performance · 7 accessibility · 26 copy/consistency): **7 high · 19 medium · 43 low**.
- Nothing here is a crash or data-corruption bug. The theme is *feedback*: the
  app does the right thing server-side but the person on the phone often can't
  tell (notices gone in 2.6 s, sheets that silently discard a form, a details
  sheet that shows yesterday's status, an offline banner that promises what the
  app refuses).
- Firestore cost is not a problem (≈10–20k reads/day per admin device). What a
  user feels is callable cold starts on Save and whole-snapshot re-parsing on
  the UI isolate when a colleague writes.

## Decide first

1. **U1 — notice duration.** 2.6 s is a design choice (`AppMotion.noticeCycle`).
   Raising it for errors and action-bearing notices changes the feel of every
   screen. Recommended: errors ≥ 5 s, action notices ≥ 6 s, success stays 2.6 s.
2. **U2 — form sheets.** Block scrim/drag dismiss while dirty, or keep dismiss
   and add a "Discard changes?" confirm? Recommended: confirm on dirty, no
   change when clean.
3. **P1 — `minInstances: 1`** on `saveAppointmentEdits`, `findAppointmentConflicts`,
   `searchClients` costs ≈ US$4–6/month each. Yes/no is a budget call.
4. **U7 — notification prompt.** ADR-0101 says an explicit in-context step; the
   step doesn't exist. Where: a one-time ask page after setup, or a calendar
   banner?
5. **C1 — vocabulary.** Job vs appointment vs visit; Done vs Complete. One pass
   over both ARBs; pick the words first.

Everything else is local, test-backed work. P1 and P4–P7 need a backend deploy.

---

## 🔴 High impact

### U1 — Every notice auto-dismisses in 2.6 s, including 170-char errors and the only Undo · confidence high

> **DONE (deviated — hold is a cancellable `Timer` in `notice_listener.dart`, not `Future.delayed`: finger-pause needs cancellation and a pre-empted banner's pending future tripped flutter_test; it is a hold, not a debounce, `check_rules` clean). `noticeHoldFor` (`notice_hold.dart`): success/info 2.6 s, error 5 s + 40 ms/char ≤ 10 s, action ≥ 6 s; a later non-error notice parks behind an action notice.**
- **Where:** `lib/core/theme/design_tokens.dart:215`, `lib/core/notices/notice_listener.dart:68-73`; Undo at `details_view_body.dart:338-362`
- **What the user sees:** "Couldn't save the appointment. Someone else edited it — …" needs 6–8 s to read and is gone in 2.6 s (6 s only under `accessibleNavigation`). "Marked as complete · Undo" appears after the sheet has already closed, so a technician looking back at the agenda has ~2 s to hit Undo. Any later notice (`info`, photo cap, stream warn) `remove()`s the current one instead of queuing (`notice_listener.dart:98-101`), so the Undo can vanish instantly.
- **Fix:** duration by kind and length (errors ≥ 5 s + ~40 ms/char, cap 10 s; action notices ≥ 6 s); pause the timer while touched; let a non-error notice wait behind one carrying an action. The whole `restoreAppointmentStatus` callable exists to serve this Undo.

### U2 — Every add/edit sheet is dismissed by a scrim tap or drag with no unsaved-changes guard · confidence high

> **DONE (deviated — the modal's own drag pops past `PopScope`, so `FormSheetFrame` claims the header-bar drag and dismisses on a ≥700 px/s fling through the same guard; the sheet no longer follows the finger). Crew-note draft kept in a session `fieldNoteDraftsProvider`, not `EventDetailsState` (autoDispose dies with the sheet).**
- **Where:** `lib/shared/widgets/sheets/app_bottom_sheet.dart:9-21`, `form_sheet_frame.dart:11-14` ("The scrim still dismisses on tap"); only two `PopScope`s in `lib/` (`hub_shell.dart:239`, `invite_person_sheet.dart:132`, which notes drag bypasses it)
- **What the user sees:** an admin who typed a title, picked a client and crew and attached photos loses all of it on a stray tap beside a 0.88–0.92-height sheet. Same for client add/edit (12 fields), edit person, change email, and the crew note draft (`details_field_record_view.dart:38`, local controller, unmounted with the sheet).
- **Fix:** track dirtiness (as `my_identity_section.dart:76` already does); when dirty set `isDismissible: false, enableDrag: false` or intercept with `showConfirmDialog` ("Discard changes?"). The `auth_unsavedChanges`-style string at `my_identity_section.dart:310` can be reused.

### U3 — Details sheet shows the status it was opened with; "Start job" leaves the Start button visible · confidence high

> **DONE — `EventDetailsState.liveStatus/liveStartedAt/liveCompletedAt` recorded on the success branch; chip, Start button, time row and `previousStatus` read the overlay.**
- **Where:** `event_details_view.dart:133-162` (`widget.appointment` passed once, never re-read), `details_view_body.dart:224-228` (`_DetailsViewData.from(appointment…)`), `:311` (`previousStatus` from snapshot), `:379` (`closeOnSuccess: false`)
- **What the user sees:** tap Start → "Job started" notice, but the chip still says Scheduled, Start job is still there, "Started 9:12" doesn't appear. A second tap is refused by the rules (in_progress→in_progress) and shows "Couldn't update appointment status". Start → Mark complete → Undo restores `pending`, not `in_progress`.
- **Fix:** derive status from a live source — the calendar's range stream already holds the doc; or have `_setStatusOnRepo` record `currentStatus` in `EventDetailsState` and feed the chip, `isInProgress` and `previousStatus` from it.

### U4 — Offline banner promises "changes will sync"; every write is refused offline · confidence high

> **DONE**
- **Where:** `lib/core/connectivity/offline_banner.dart:10`, `app_en.arb:1353`; vs the controller guards (`add_event_controller.dart:326`, `event_details_controller.dart:391/446/489/545/831`, `client_form_controller.dart:97/123`) and `error_cause.dart:122-138`
- **What the user sees:** banner says changes will sync; Save says "You appear to be offline — check your connection and try again." Only photos actually queue — and that queueing is itself never announced (U14).
- **Fix:** reword EN+FR to reality: "Offline — you can view your schedule; saving needs a connection", or make it conditional on pending photo uploads.

### U5 — History chip filters stop pagination; the Year chip only lists loaded years · confidence high

> **DONE (deviated — pager kept alive under chip filters with a 20-page empty-fetch cap and a newest-first year stop; Year chips span oldest-loaded…current. Server-side `where`s would need calendar-repository queries, left out.)**
- **Where:** `appointment_history_view.dart:358-378` (`_buildFiltered` → `_countedList` with no `footer`/`onRowBuilt`), `:284` (`_yearsOf(loaded)`), `history_sliver_list.dart:52-58`
- **What the user sees:** with Complete / Cancelled / Year / Staff on, the user only ever sees matches among the ≤25 rows already loaded. Picking a year on a fresh screen shows "No appointments match your filters" though the jobs exist two pages down.
- **Fix:** keep the pager alive under chip filters (pass `footer`/`onRowBuilt` through, filter pages as they arrive), or make chip filters server-side `where`s like the clients list does.

### U6 — Every client write resets the list to page 1 · confidence high

> **DONE — typed `ClientsWrite` on `clientsRefreshProvider`; `Updated`/`Archived` patch in place, add/delete refresh. Fixed a latent `getNextPageKey` bug the patch exposed (`_lastPageFull`).**
- **Where:** `client_form_controller.dart:103,128,158,184` bump `clientsRefreshProvider`; `clients_list_view.dart:486` → `_pagingController.refresh()`
- **What the user sees:** fixing a typo on client #180 (or a swipe-archive) drops the admin to the top of the roster with the skeleton showing. Also ≈60–260 reads per save (first page + count + active search re-run).
- **Fix:** patch the edited/archived record into the current `PagingState` in place (the repository already `_patchWindow`s its cache); keep the full refresh for add/delete only.

### U7 — A new employee is never shown the iOS notification prompt · confidence high

> **DONE (owner: ask page) — `NotificationAskGate`/`NotificationAskScreen`, once per uid when `notDetermined`, hosted ahead of the location ask; `sync()` untouched.**
- **Where:** `push_registration_controller.dart:160-163` (`sync()` returns when not granted); `requestPermission()` has one caller: `settings_screen.dart:336`
- **What the user sees:** job assignments, "time to leave" and the digest are all silent until the employee discovers Settings › Notifications — which an employee has no reason to open. ADR-0101 already says to close this with an explicit in-context step; the step doesn't exist.
- **Fix:** a one-time ask page on the `LocationShareAskGate` pattern after first setup when status is `notDetermined`, or a dismissible calendar banner. Leave `sync()` alone.

---

## 🟠 Medium impact

### U8 — Location sharing shows "On" after the OS prompt was denied · confidence high

> **DONE (deviated — `applyLocationSharing` returns `LocationSharingOutcome`; on a refused prompt the flag is written back OFF and the page stays open in the Open Settings variant. Open Settings no longer saves sharing on before leaving the app.)**
- **Where:** `share_location_ask_screen.dart:39-41` pops on `saved`; `presence_sync_controller.dart:225-231` breadcrumbs and returns silently on non-granted
- **What the user sees:** taps Turn on → Don't Allow → page closes. Settings reads "Staff map location: On · Last uploaded: None" and nothing ever reaches the map; the Open Settings variant only appears next build.
- **Fix:** surface the permission result from `applyLocationSharing`; on denied keep the page open in the Open Settings variant (or notice with that action); consider reverting the flag.

### U9 — Setup asks for location consent, then the first calendar frame asks again · confidence high

> **DONE (deviated — fresh `locationConsentAt` (≤1 h) switches the ask page to a "finish setting up the team map" variant instead of auto-enabling: the iOS prompt must come from a tap, ADR-0107/0110.)**
- **Where:** `consent_row.dart` (`auth_termsAndLocationConsent`, `app_en.arb:3602`) then `location_share_ask_gate.dart:48-60`, then the tour
- **What the user sees:** long setup form → full-screen "Be on the team map" → 6–7-step tour, before seeing the app once; the location question is asked twice in different words.
- **Fix:** treat a just-stamped `locationConsentAt` as the answer (enable + `alreadyOn` variant, or skip for this build), or drop the location clause from the consent sentence so the ask page is the single moment of choice.

### U10 — Password changed, then signed out to Login with no explanation · confidence high (path), medium (frequency)

> **DONE (deviated — `retryWhen` composes `isAuthPropagationDenied` with a private stale-profile marker, since the sole-owner predicate cannot express "doc still invited"; delays stay `kAuthPropagationDelays`.) Login shows `LoginArgs(notice: accountReady)`.**
- **Where:** `account_setup_screen.dart:247-250,264-275`, `change_password_screen.dart:161-162,185-221` (`SignInProfilePending` → sign out)
- **What the user sees:** a slow/failed `resumeAfterSignUp()` after the password HAS landed drops them on Login with no banner; the remembered password is the old one.
- **Fix:** retry `resumeAfterSignUp` with backoff before giving up; pass an info message to Login ("Your account is ready. Sign in with your new password.").

### U11 — Cancel dialog has two buttons that both start with "Cancel" · confidence high

> **DONE (one-off confirm) / NOT A DEFECT (run-scope — `showSeriesScopeDialog` already dismisses with "Back").**
- **Where:** `cancel_appointment_dialog.dart:27-32`; `confirm_dialog.dart:34,56` default dismiss = `common_cancel`
- **Fix:** pass `cancelLabel` ("Keep appointment" / "Go back") as `overdue_review_screen.dart:99` already does; same for the run-scope variant.

### U12 — Save with a validation error below the fold looks like a dead tap · confidence high

> **DONE — `FormErrorFocus.focusFirstError` + haptic in all sheets.**
- **Where:** `add_appointment_sheet.dart:284` (`AddEventInvalid` → nothing), `appointment_form_fields.dart:226`; `add_client_sheet.dart:182-203`, `edit_client_sheet.dart:228-255`; only focus-driven `ensureVisible` (`sheet_widgets.dart:69-86`)
- **What the user sees:** Save sits in the fixed header; required time rows / the address grid are off-screen under the keyboard; the shake happens out of view.
- **Fix:** `requestFocus()` the first errored field's node (the existing focus listener scrolls it in) + `HapticFeedback.mediumImpact()`; same in `DetailsEditBody._announce`.

### U13 — Add client from the FAB has no duplicate-phone check · confidence high

> **DONE — `DuplicatePhoneCheck` + "Already on file: … — Open / Use anyway"; fails open.**
- **Where:** `client_form_controller.dart:89-116` → `firebase_clients_repository.dart:247-256`; only the booking picker searches first
- **What the user sees:** typing a phone already on file creates a second client (and a second Wave customer) silently — the costliest data error here.
- **Fix:** after the phone lift / on phone blur, `searchClients(digits)` and show "Already on file: Jane Doe — Open / Use anyway" before Add commits.

### U14 — Photos queue offline, and reconnect drains, with no feedback either way · confidence high

> **DONE**
- **Where:** `details_field_record_view.dart:124-160` (deliberately unguarded, good), only cue is the strip badge `details_view_leaf_widgets.dart:307-327`; drain at `app_sync_listeners.dart:180-188`
- **Fix:** `notices.info(calendar_nPhotosWaitingToUpload(n))` when enqueued offline; one info notice on the offline→online flip with a non-empty queue.

### U15 — `OfflineFormNotice` only on the two CREATE sheets · confidence high

> **DONE (My details handled under C17).**
- **Where:** mounted at `add_client_sheet.dart:258`, `add_appointment_sheet.dart:397`; absent from `edit_client_sheet.dart:292-303`, `edit_person_sheet.dart`, `details_edit_body.dart`, invite person, My details
- **Fix:** `const OfflineFormNotice()` as first child of each edit sheet.

### U16 — Full-swipe archive has no Undo · confidence high

> **DONE — Undo reverses the in-place removal.**
- **Where:** `client_actions_host.dart:50-56` (`notices.success`, not `successWithAction`), `clients_list_view.dart:216-219`
- **What the user sees:** the one destructive gesture without a second chance; recovery is Filter → Archived → find → unarchive, after the list has reset (U6).
- **Fix:** `successWithAction(…, actionLabel: Undo, onAction: () => setArchived(id, archived: false))` — archive/unarchive is a symmetric toggle, the one case the rules allow an action on a notice.

### U17 — Agenda shows "No appointments found" on a cold stream error · confidence high

> **DONE**
- **Where:** `main_calendar_screen.dart:362-367,389` (`appointmentsAsync.value ?? []`), `agenda_sliver_list.dart:67-72`
- **Fix:** error branch (`CenteredErrorText` + retry) when `hasError && !hasValue`; keep the notice for data→error transitions.

### U18 — Month swipe / Today / day↔week blanks the grid dots and shows "0 JOBS" while the new range loads · confidence high

> **DONE — held list/range rendered while the new range loads; skeleton only when the selected day is outside the held range.**
- **Where:** `main_calendar_screen.dart:340-346,362-367`, `calendar_month_pager.dart:88-97` (`_refreshDayIndex([])` on the new family instance)
- **Fix:** keep the last non-empty list / day index rendered while loading; consider pre-warming adjacent months (`keepWarmWithGrace` already keeps old ranges alive).

### U19 — Day route always opens on today, dropping the calendar's selected day · confidence high

> **DONE**
- **Where:** `day_route_screen.dart:68`, `app_routes.dart:355-359` (`DayRouteArgs` has no day), `main_calendar_screen.dart:543-549`
- **Fix:** add `initialDay` to `DayRouteArgs`; pass `_selectedDay ?? _focusedDay`.

### U20 — Clock format: wheel honours 24-h, cards don't · confidence high

> **DONE — flag captured in `_buildAppShell` (the only place the MediaQuery is in scope).**
- **Where:** `date_utils_helper.dart:15-21` (`DateFormat.jm`, never reads `alwaysUse24HourFormat`) vs `cupertino_time_picker.dart:48`
- **What the user sees:** picks 14:30 on the wheel, reads "2:30 p.m." on the card (6 `formatTime` call sites).
- **Fix:** capture the flag once beside `Intl.defaultLocale` (`app_language.dart:15`); choose `Hm` vs `jm`.

### U21 — Admin edit of an employee's work email changes their sign-in with no confirm or helper text · confidence high

> **DONE**
- **Where:** `edit_person_sheet.dart:456-469,226-255` vs the self-service dialog (`change_email_dialog.dart:72-84`) which demands the address twice + password
- **Fix:** helper text ("This is what they sign in with") + confirm when the normalized email differs.

### U22 — "Close" on the new-account dialog discards an uncopied temporary password · confidence high

> **DONE**
- **Where:** `new_account_dialog.dart:118-121,136-138`; password never persisted (`pending_invite_tile.dart:286-290`)
- **Fix:** if `!_copied`, confirm "You haven't copied these — close anyway?", or make Copy primary.

### U23 — Forgot password never mentions the real recovery path · confidence high

> **DONE**
- **Where:** `forgot_password_screen.dart:181-184,206-234`; `employees.md:45` says employee emails aren't real inboxes
- **Fix:** reword the `WarningNote`: "If your work email isn't a real inbox, ask your admin to reset your password from the Team screen."

### U24 — Splash bounces to Login silently on an offline cold start with a cold cache · confidence medium-high

> **DONE — `isSplashAuthFailure`; non-auth errors keep the session and show "You're offline — retrying…" + Retry, auto-retry on reconnect.**
- **Where:** `splash_screen.dart:117-131,139-156`, `splash_controller.dart:72-80` (`retryAsync` only on `permission-denied`)
- **Fix:** on a non-auth error keep the session, show "You're offline — retrying…" with Retry; fall to Login only for auth errors.

### U25 — Inline add-client from the booking form still offers "Add and book a job" · confidence high

> **DONE**
- **Where:** `inline_add_client_host.dart:16-24` (discards `result.next`; its own comment calls the button meaningless there), `add_client_sheet.dart:420-430`
- **Fix:** a `mode`/`showBookAction` param; hide caption + button for the inline source.

### U26 — Search results reorder on debounce commit · confidence medium-high

> **DONE**
- **Where:** `clients_list_view.dart:352-373` (local `_localFilter` in page order → server relevance order ~250 ms + RTT later; header count jumps)
- **Fix:** rank the local fallback with `ClientSearchPolicy.scoreRecord`; keep the local list until server results are non-empty.

---

## ⚡ Performance

### P1 — Admin Save = two serial callables, each possibly cold · confidence 85 % · HIGH

> **DONE — OPEN — needs backend deploy BEFORE the next app build (ADR-0030): `saveAppointmentEdits` takes `checkConflicts` and refuses `failed-precondition`/`appointment-employee-busy` with `{busyEmployeeIds, startMillis, endMillis}`; client sends one call and maps it to the busy outcome; `minInstances: 1` + 512 MiB on `saveAppointmentEdits`, `findAppointmentConflicts`, `searchClients`. Deviations: `addAppointments` now also goes through the callable; `details` keeps the ids vocabulary. Dead client pre-check (`findFirstAppointmentConflict`, `findBusyEmployeeIdsForBookings`, 253 lines) removed. Deploy via the `Deploy backend` workflow.**
- **Where:** `event_details_controller.dart:409-420,703-763`, `add_event_controller.dart:416-437` (`findAppointmentConflicts` then `saveAppointmentEdits`); `functions/index.js:4` (`setGlobalOptions({maxInstances: 10})`, no `minInstances`, default 256 MiB; all 17 modules + `wave/*` + `apns_client` loaded per instance)
- **Felt as:** 3–6 s on the Save spinner after a quiet spell — the most-used admin action, worst exactly when the dispatcher picks the phone back up. `searchClients` and `placesAutocomplete` pay the same on the first keystroke.
- **Fix:** `minInstances: 1` on the three callables (≈ US$4–6/month each); fold the overlap check into `saveAppointmentEdits` (return `busyEmployees`) so Save is one round trip; raise memory to 512 MiB–1 GiB for faster module load. Needs a deploy.

### P2 — Every snapshot emission re-parses the whole window on the UI isolate · confidence 80 % · MEDIUM

> **DONE (deviated on the mirror half — `(id, updatedAt)` tuples always differ across emissions, so the services deep-compare the last LANDED payload before `jsonEncode`). Range streams apply `docChanges` per subscription.**
- **Where:** `firebase_appointments_repository.dart:520-532` (`snapshot.docs.map(fromMap)`, no `docChanges`), then `main_calendar_screen.dart:275-290` (`_refreshDayIndex`), and for admins the permanent mirrors listener: `widget_sync_service.dart:216-219,256-272`, `schedule_snapshot_provider.dart:38-62`, `app_sync_listeners.dart:121-173`
- **Felt as:** ≈1,750 + 660 docs re-parsed per remote write ≈ 30–60 ms → 2–4 dropped frames (4–7 at 120 Hz) whenever any colleague writes while the admin scrolls. Server rewrites (`stampLifecycle`, `recountAppointmentPictures`, photo `updatedAt`) make one crew action ≈ 2–3 emissions.
- **Fix:** keep a `Map<String, AppointmentRecord>` per stream and apply `docChanges`; compare a cheap `(id, updatedAt)` hash before `jsonEncode` in the mirror signature.

### P3 — Dashboard history (~1,900 docs) is evicted 3 min after leaving, though it self-invalidates on write · confidence 85 % · MEDIUM

> **DONE — `kDashboardReadKeepAlive` 1 h.**
- **Where:** `dashboard_providers.dart:58-89` (`keepWarmWithGrace(ref)` default), already invalidated by `onRecordWrite` + `writeTouchesHistory`
- **Felt as:** a 1–2 s skeleton and ≈2k reads every re-open after > 3 min.
- **Fix:** long grace (1 h) or `keepAlive()` for the session; same for `newClientsProvider:92-106`.

### P4 — Overdue query grows forever with personal blocks and re-issues fresh every 15 min · confidence 80 % · MEDIUM

> **DONE (cheap fix — `overdueReviewBoundary` floors `now` to the quarter hour; refresh aligned to the next boundary). DONE (structural) — `where('isPersonal', isEqualTo: false)` + `(isPersonal ASC, status ASC, endTime DESC)`; release prerequisite: indexes READY, then `backfill-appointment-is-personal.js` (ADR-0189, `docs/DEPLOYMENT.md` §4d).**
- **Where:** `overdue_review_providers.dart:19-30`, `firebase_appointments_repository.dart:561-600` (`status in open AND endTime < now`, personal/time-off excluded only in Dart)
- **Fix (cheap):** round `now` down to the 15-min boundary so re-opens are the same query and resume from cache. **Fix (structural):** `where('isPersonal', isEqualTo: false)` + `(isPersonal, status, endTime DESC)` composite + backfill for legacy docs.

### P5 — 14-day `fetchStart` lookback on every range query mostly serves personal blocks now · confidence 80 % · LOW-MEDIUM

> **DONE — main query starts at `range.start`; a second `isPersonal == true` tail query over `[fetchStart, start)` merges in Dart (`_watchRange(main, tail)`); composites `(isPersonal ASC, startTime ASC)` and `(employeeIds CONTAINS, isPersonal ASC, startTime ASC)`. The backfill script's wide-client-job report is the legacy-run check (ADR-0189).**
- **Where:** `appointment_record.dart:215-216`; since ADR-0050 jobs are one doc per day
- **Felt as:** calendar window 44 → 58 days (+30 %), mirrors 8 → 22 (+175 %, permanent for admins, feeds P2).
- **Fix:** second tiny `where('isPersonal', isEqualTo: true)` query over the tail, merged in Dart (needs `(isPersonal, startTime)` composite); mind legacy runs.

### P6 — Widget window fetched per recipient per change event · confidence 85 % · LOW (server bill only)

> **NO CHANGE — report's own call ("only if the bill matters").**
- **Where:** `functions/notification_utils.js:247-260` via `handleAppointmentWrite:366-410`
- **Fix only if the bill matters:** skip when no token has a widget-capable `sessionEpoch`; cap the push lookahead to today+tomorrow.

### P7 — Triggers fire on the server's own rewrites (2–4 invocations per user action) · confidence 85 % · LOW

> **NO CHANGE — report's own call.**
- **Where:** `functions/notifications.js:88-104`, `client_job_count.js:181`; early returns are pure.
- **Fix:** none now; gate on `before.updatedAt == after.updatedAt` for the `pictureCount`-only rewrite if invocation count shows up.

### P8 — Disk-cache reads wait behind the write chain; first write `statSync`s every cached file · confidence 75 % · LOW

> **DONE (deviated — `read` awaits only an in-flight `clear()`; the UI-isolate cost was `statSync` per file in the sweep, now `await stat()`; `_trim` not deferred.)**
- **Where:** `appointment_image_disk_cache.dart:53-57,139-150`
- **Fix:** don't await `_mutations` in `read`; defer the first `_trim` until the strip's loads settle.

### P9 — `FadeInItem` stagger re-runs on every day tap · confidence high · LOW

> **DONE (deviated — `FadeInItem` already animates once per State; the real cause was `SliverList.builder` lacking `findChildIndexCallback`, so index shifts re-inflated keyed children. Fixed there; `fade_in_item.dart` untouched.)**
- **Where:** `agenda_sliver_list.dart:153-155`, `fade_in_item.dart:33-44` (30 ms × index, ~240 ms to the 8th card)
- **Fix:** animate only on first data arrival or an actual day change.

### P10 — `DateFormat.MMMd().add_jm()` built on every rebuild of the notes view · confidence medium · LOW

> **DONE**
- **Where:** `details_field_notes_view.dart:59-61`
- **Fix:** memoize per locale like `longDateFormatFor`.

---

## ♿ Accessibility

### A1 — Error banners and the lock overlay aren't live regions · confidence high · MEDIUM

> **DONE**
- **Where:** `auth_banner.dart:24-60`, `auth_fields.dart:23-54`, `app_lock.dart:217-220`
- **Fix:** `Semantics(liveRegion: true)`; optionally move focus to the first errored field.

### A2 — Notice kind is colour-only (9 px dot) · confidence high · MEDIUM

> **DONE — icon per kind + "Error:/Success:/Info:" live-region prefix.**
- **Where:** `notice_listener.dart:76-80,200-206`
- **Fix:** leading icon per kind and/or `Semantics(label: 'Error: $message')`.

### A3 — Card `excludeSemantics` hides the per-stop Navigate pill · confidence high · MEDIUM

> **DONE**
- **Where:** `appointment_card.dart:133-135,241-244` (footer inside the excluded subtree), `day_route_screen.dart:510-518`
- **Fix:** render `footer` outside the excluded subtree.

### A4 — Sub-48 px targets: `DetailsEditChip`, photo Retry · confidence high · MEDIUM

> **DONE**
- **Where:** `details_view_leaf_widgets.dart:28-58` (≈24–28 px), `photo_picker_section.dart:539-547` (`shrinkWrap`, `minimumSize: Size.zero`)
- **Fix:** `ConstrainedBox(minHeight: kGhostTapTarget)` like `GhostControl`; drop the shrink-wrap on Retry.

### A5 — Row `InkWell`s with no `button`/`selected` semantics · confidence high · MEDIUM

> **DONE**
- **Where:** `client_tile.dart:50-53`, `text_size_view.dart:205-209`, `live_map_team_sheet.dart:376`, `settings_tile.dart:49` (the two 2026-10-18 repro cases ARE fixed)
- **Fix:** `Semantics(button: true, selected: selected)` or `MergeSemantics`.

### A6 — Empty-state animation ignores reduced motion; fixed 160 px button clips at 2× · confidence high · LOW

> **DONE**
- **Where:** `app_empty_state.dart:23-33,64-70`
- **Fix:** `Duration.zero` under `disableAnimations`; `ConstrainedBox(minWidth: 160)`.

### A7 — Disabled "Complete" button shown to technicians on done jobs · confidence high · LOW-MEDIUM

> **DONE**
- **Where:** `details_action_bar.dart:166-182` (when `onEdit` is null)
- **Fix:** render nothing (the chip already says Complete) or plain text.

---

## 📝 Copy, consistency, polish

### C1 — Three nouns for one thing; two words for one status · confidence high · LOW-MEDIUM

> **DONE (conservative, owner to widen if wanted) — EN `calendar_closedCount` "Complete · N", `calendar_jobsDoneCount` "N COMPLETE", dashboard "visit(s)" → "job(s)" (FR "tâche(s)"; FR "Terminé(e)s" already matched). "Visit" kept in the repeat-series dialogs where it means an occurrence; "appointment" kept as the entity name.**
- JOBS/DONE in header, counts and rule; "appointment" in empty state, notices, cancel dialog; "visits" on the dashboard; `status_done` = "Complete" while the rule reads "Done · 3". One ARB pass (EN+FR lockstep).

### C2 — Weak-password error says "6 characters"; the checklist says 8 + mixed case + digit · confidence high · MEDIUM

> **DONE**
- **Where:** `auth_failure.dart:137-142` → `app_en.arb:1449` vs `:1461-1473`
- **Fix:** map to `validation_passwordDoesNotMeetAllRequirements`; delete the 6-char string.

### C3 — Sign-in refuses passwords under 8 chars with a format message · confidence medium · LOW (legacy accounts only)

> **DONE**
- **Where:** `auth_validators.dart:24-32` (`login_screen.dart:73-76`); its own comment says sign-in should be looser
- **Fix:** non-empty only at sign-in.

### C4 — Forced change-password screen doesn't say whose account, and hides the "must differ" rule until failure · confidence high · LOW-MEDIUM

> **DONE**
- **Where:** `change_password_screen.dart:240-250,126-135`; `LockedEmailPanel` exists on setup
- **Fix:** show the email; add "Not the temporary password you were given" to the checklist on both screens.

### C5 — "No user profile found for this account" where an actionable string exists · confidence high · LOW

> **DONE**
- **Where:** `login_screen.dart:124-127` → `app_en.arb:1513`; reuse `error_noAccountRecordContactAdmin`.

### C6 — Load-error state: "Something went wrong" title over a body that already names the failure · confidence high · LOW

> **DONE — `errorCauseFor(l10n, error)` extracted in `error_cause.dart`.**
- **Where:** `clients_list_view.dart:426-437`, `appointment_history_view.dart:419` (`error-handling.md`: never `error_somethingWentWrong` at a new site)
- **Fix:** title = intro, body = cause.

### C7 — Archived client isn't marked in the detail profile card · confidence high · MEDIUM

> **DONE**
- **Where:** `client_detail_view.dart:144-207`; only the footer button flips
- **Fix:** render `_ArchivedPill` / "Archived" subtitle when `client.archived`.

### C8 — Admin can't reach done-job Edit from a client's Job history · confidence high · MEDIUM

> **DONE**
- **Where:** `client_job_history_section.dart:112-117` (`showActions: false` unconditionally) vs `history_sliver_list.dart:172-177`
- **Fix:** thread `isActiveAdminProvider` through as `showActions`.

### C9 — Building (shared-address) empty state reuses the type-filter hint · confidence high · LOW

> **DONE**
- **Where:** `clients_list_view.dart:439-447` ("No clients at this address." + "A client's type is set on their edit sheet.")
- **Fix:** a `clients_buildingFilterHint` key.

### C10 — "Tap + to add your first client" shown to technicians who have no + · confidence high · LOW

> **DONE**
- **Where:** `clients_list_view.dart:251-266` vs `clients_screen.dart:213-227`; branch on `isAdmin`.

### C11 — Filtered search empty state never says a filter is narrowing it · confidence high · LOW

> **DONE**
- **Where:** `clients_list_view.dart:355-373,396-417`; add "within <filter>" + Clear filter.

### C12 — `'${l10n.clients_noClientsMatch} "$query"'` concatenation forces ASCII quotes on French · confidence high · LOW

> **DONE**
- **Where:** `clients_list_view.dart:256,403,413,443`, `appointment_history_view.dart:466`; one `{query}` placeholder key.

### C13 — FR "téléchargement" for upload reads as download in fr-CA · confidence medium-high · LOW

> **DONE**
- **Where:** `app_fr.arb:404,424,425`; "téléversement/téléversé".

### C14 — `failed-precondition` from a callable falls to "Please try again in a moment" · confidence medium · LOW

> **DONE**
- **Where:** `error_cause.dart:28-55`; retrying never fixes a precondition. Add a cause: "This can't be done in its current state — refresh and check the record."

### C15 — Log out and Delete account styled identically, one row apart · confidence high · LOW

> **DONE**
- **Where:** `account_settings_card.dart:26-42`; neutral Log out, Delete account last.

### C16 — Emergency-contact fields look editable but swallow input until loaded · confidence high · LOW

> **DONE (deviated — "Loading emergency contact…" hint while `readOnly`; `LabeledTextField` has no `enabled`).**
- **Where:** `edit_person_sheet.dart:551-575` (`readOnly: !_emergencyLoaded`, no placeholder).

### C17 — Three sequential full-screen spinners on My details · confidence high · LOW

> **DONE**
- **Where:** `my_details_screen.dart:345,370,377`; one gate or a skeleton, shown after ~300 ms.

### C18 — Address field: spinner replaces the clear button for up to 10 s; lookup error offers no retry · confidence high · LOW

> **DONE**
- **Where:** `address_autocomplete_field.dart:330-356`, `google_places_repository.dart:14`.

### C19 — Phone caret jumps to the end when fixing a mid-number digit · confidence high · LOW

> **DONE**
- **Where:** `phone_format.dart:105-119` (documented); map the caret through mask chars.

### C20 — Three generic onboarding slides, admin-centric copy, before Login · confidence high · LOW

> **DONE**
- **Where:** `onboarding_screen.dart:69-85`, `app_en.arb:1657-1677`; collapse to one or none — the per-role tours already exist.

### C21 — Lock overlay has no Log out escape; "sensor unavailable" is a toast · confidence medium · LOW

> **DONE (deviated — sensor-unavailable now keeps the overlay with the message inline and a "Continue" button that is the same session-only release; "Log out" routes through `AccountExitController`).**
- **Where:** `app_lock.dart:186-233,144`.

### C22 — Calendar collapse / agenda mode not persisted · confidence high · LOW

> **DONE**
- **Where:** `main_calendar_screen.dart:86,91`, `collapse_state.dart`; SharedPreferences, try/catch.

### C23 — Dashboard skeleton is eight list rows under a hero layout; overdue review uses a bare spinner; no pull-to-refresh on dashboard · confidence high · LOW

> **DONE**
- **Where:** `dashboard_screen.dart:250-259,118,190`, `overdue_review_screen.dart:179`.

### C24 — Two-pane: new client isn't selected into the detail pane after Add · confidence medium · LOW

> **DONE**
- **Where:** `client_detail_view.dart:92-97`, `clients_screen.dart:117-124`.

### C25 — Settings sub-screens push bare `MaterialPageRoute` · confidence high · LOW

> **DONE**
- **Where:** `settings_screen.dart:199-204,214-221`; CLAUDE.md says route via `onGenerateRoute` (and this skips `AppPageRoute`'s reduced-motion handling).

### C26 — Location ask re-interrupts every "Not now" user on each release · noted, deliberate (ADR-0110)

> **DELIBERATE — ADR-0110, not changed.**
- Worth revisiting if release cadence stays weekly.

---

## What's already good (so the list above is read in proportion)

- Mark complete is the best-built action in the app: haptic, busy icon, disabled while saving, offline fail-fast with a cause sentence, server-owned Undo.
- Error UX is consistent: 25 `composeErrorNotice` sites, typed failures first, no raw Firebase code or exception text ever reaches a user; every offline-sensitive write is guarded before the in-flight flag; no double-writes or stuck spinners found.
- Startup is already parallel (prefs, Firebase, date symbols) with a cached splash fast path; listener topology is genuinely shared (one `forMirrors` listener feeds widget, Siri, badge, Team tab); every stream/scan has a named cap and warn; image caches are byte-budgeted; presence is foreground-only at 250 m / 2 min.
- Forms: capitalization, `textInputAction.next`, autofill hints, phone masking, 48 px clear buttons, `TextLimits`; the Cupertino wheel honours 24-h; `boldText` and reduced motion are honoured in routes, tabs, notices, skeletons and the field shake.
- No hard-coded user-facing strings in widgets, 67 ICU plurals, `untranslated.json` empty.
- Search is staged well (debounce, local fallback, skeleton, truncation banner, phone-picker tally); day route re-validates crew against who has work and announces truncation before Maps opens.

## Notes

- Static read only — frame-time and cold-start numbers are estimates with stated assumptions (≈30 jobs/day, 5–10 crew). Measure P1/P2 on a device before and after.
- Overlaps between reviewers were merged: notice duration (3 reports), sheet dismiss (3), scroll-to-error (3), archive Undo (2), offline notice on edit sheets (2), clients refresh (2), error-title duplication (2).
