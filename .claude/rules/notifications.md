---
paths:
  - "functions/notification*.js"
  - "functions/travel*.js"
  - "functions/live_activity*.js"
  - "functions/widget_payload_utils.js"
  - "lib/features/notifications/**"
  - "lib/features/presence/**"
  - "lib/features/home_widget/**"
  - "lib/features/live_activity/**"
  - "lib/features/siri/**"
  - "ios/**"
  - "test/features/notifications/**"
---

# Push, presence, widget, Live Activities and Siri

Loaded when working on any off-app surface. Root context: `../../CLAUDE.md`; functions overview:
`../../functions/CLAUDE.md`. Each surface spans JS (the sweep), Dart (registration, payload builders) and
Swift (the extensions), so they are scoped as one rule.

## Permission and push registration

- Never request notification permission on a sync path: `PushRegistrationController` registers only when `service.authorizationStatus()` is already granted, and `requestPermission()` has exactly one caller, the Settings Notifications row — iOS shows that prompt ONCE, ever. A fresh install therefore receives nothing until that row is tapped; close the gap only with an explicit in-context step, never by moving the request onto `sync()`. (ADR-0101)
- Read `notificationAuthStatusProvider` without prompting: `notDetermined` shows the OS prompt, any other state opens system Settings; after the tap and on `resumed`, invalidate it and re-run `PushRegistrationController.sync()` so a just-enabled device stores its token. (ADR-0101)
- Register FCM tokens for active employees AND admins (`shouldRegisterPush`; admins get only the timed nudges) at `users/{docId}/fcmTokens/{token}`, per-device `locale` driving EN/FR; `AppSyncListeners` (`core/app/app_sync_listeners.dart`) re-runs `sync()` on every account-doc emission and language change.
- Route push taps, widget taps and app links through ONE opener, `AppointmentLinkOpener` (`core/app/appointment_link_opener.dart`, registered by `main.dart`); `DeepLinkDispatcher` calls its `openAppointment`. `AppointmentLinkOpener.handlePushTap` checks `kind: overdueReview` FIRST — that push has no `appointmentId`; a new id-less kind needs a branch above the id read. (ADR-0120)

## Server push pipeline (`notifications.js`, `notification_utils.js`, `notification_sweeps.js`)

- Keep `notifyAppointmentChanges` without `retry` (a duplicate push is worse than a missed one), so isolate EVERY per-recipient loop in a fan-out in its own try/catch — an escape drops recipients 2..N permanently. (ADR-0103)
- Ask reachability BEFORE the work: `_loadRecipient` + `_canReachRecipient` above the series claim and `fetchEmployeeWidgetWindow` in `handleAppointmentWrite`, above the window read in the digest, above the ledger `create()` in `_deliverRecipientOnce`; both share the per-sweep `cache`. (ADR-0103)
- Collapse repeat-series pushes to one per (employee, kind) with `claimSeriesNotice` (`appointmentSeriesNotices`, Admin-SDK-only), which FAILS OPEN on any claim error. Writes key on a fresh `seriesOpId` (`_newSeriesOpId()`, `firebase_appointments_repository.dart`; no window); a delete passes `""` (its `before.seriesOpId` is stale) and falls back to `SERIES_CLAIM_WINDOW_MS` (45 s — keep it seconds-wide, or separate deletes in one series collapse) with stale takeover. Build the claim's `.doc()` inside the `try` — it throws on a `/`. (ADR-0102)
- Keep `isCrewCompletion` reading a fresh `seriesOpId` as an admin write (the crew mark-done rule cannot stamp one), so a bulk Complete via `updateAppointmentStatuses` sends no `notifyAdminsOfCompletion` push. (ADR-0102, ADR-0118)
- Run `stampLifecycle` (server-owned `startedAt`/`completedAt`) in `handleAppointmentWrite` ABOVE its events early-return; its own rewrite is provably silent (`notification_lifecycle.test.js`).
- Guarantee at-most-once with per-recipient ledgers (`appointmentReminders/{id}_{startMs}_{employeeDocId}`, `appointmentOverduePrompts/{id}_{endMs}_{employeeDocId}`, `create()`-fails-if-exists, Admin-SDK-only), never cadence; release a claim that delivered zero pushes; write `expiresAt` +7 d for the console TTL. Send only to active accounts: change pushes to `CHANGE_RECIPIENT_ROLES` (employees), timed nudges to `TIMED_RECIPIENT_ROLES` (employees and admins). (ADR-0106)
- Keep three scheduled functions — a fourth costs money: the overdue sweep (`runOverduePromptSweep`) rides `sendUpcomingJobReminders`, Wave (`runWaveDaily()`) rides `sendDailyJobDigest` (18:00 Toronto), each rider in its own `try` below the digest. Keep the `sendOverdueJobPrompts failed` log label. (ADR-0106)
- Give `liveActivityDeps()` (reads `apnsAuth`) only to the two functions binding `APNS_SECRETS`; the digest and overdue sweep use `liveDeps()` — an unbound secret read logs a warning on every invocation. (ADR-0115)

## Sweeps and caps

- Order each capped sweep so the cap keeps the jobs it is for, via `scanAppointmentWindow`, warning at the cap: travel candidates `startTime` ASC, `TRAVEL_SWEEP_MAX` (500); overdue `endTime` DESC over `OVERDUE_LOOKBACK_MS` (2 h, sized to the 5-min cadence), bounds `> floor`/`<= now` mirroring `selectOverdueCandidates`, `OVERDUE_SWEEP_MAX` (500); digest `startTime` DESC then reversed before grouping, `DIGEST_SWEEP_MAX` (1000) — DESC, or the cap keeps the oldest. Deploy `firestore:indexes` with it; don't drop the `orderBy`. (ADR-0105)
- Keep the overdue nudge in step with the display-only `overdue` (`AppointmentRecord.displayStatus`). (ADR-0105)
- Degrade every travel-reminder failure (no origin, empty address, any Routes error) to the fixed 30-min `reminder` kind; `leaveNow` is `time-sensitive`. Keep `CONTEXT_QUERY_MAX` (50, `endTime` ASC) on the context read and its `endTime` bound at `TRAVEL_WINDOW_MS + MAX_BOOKING_MS` — the travel window alone drops a longer intervening job from `decideOrigin`; never widen it to the span cap (wrong origin, ADR-0104). A cached estimate (`ESTIMATE_TTL_MS`) may only DEFER a Routes call (`SKIP_MARGIN_MS`), never trigger a send. Constants live in `travel_policy.js`. (ADR-0104)
- Read absent `travelAlertsEnabled` as ON (`wantsTravelAlerts`, `EmployeeRecord.fromMap`'s `!= false`) — pre-field docs have no value, and a missing push is never reported. It gates only the `leaveNow` escalation, read BEFORE the Routes call: `resolveReminderForAssignee` skips `decideOrigin`/`computeTravelSeconds`, so `computeLeadMinutes(null)` gives the fixed 30-minute `reminder` rather than up to `MAX_LEAD_MINUTES` (90) early on a billed estimate (`travel_utils.test.js`, "an opted-out assignee"). It is a SERVER flag in Settings › NOTIFICATIONS, hidden until the own record loads. (ADR-0081)

## Month-end review (`runMonthEndOverdueReview`)

- Run it as a `sendDailyJobDigest` rider AFTER the TTL prune and BEFORE `runWaveDaily` (shared 540 s timeout; `notifications_riders.test.js`), only when `isLastDayOfBusinessMonth` (calendar-day arithmetic on `businessYmd`/`businessDayStartMs`, never `+ 86400000`). (ADR-0118)
- Keep its two caps separate: `MONTH_END_SCAN_MAX` (5000 raw rows, `endTime` DESC) and `MONTH_END_REVIEW_MAX` (reports `1000+`) — personal blocks and time off pile up in the window and would eat a single cap. `selectMonthEndOverdue` excludes personal, time off and unparseable `endTime`, with no 2 h floor. Send nothing at zero. (ADR-0118)
- Send via `sendToActiveAdmins` (resolves the admin count, 0 on a failed read) with `includeUser` → `monthEndReviewPush === true`, data `{kind: 'overdueReview', count}`, text `buildOverdueReviewMessage`, and log `monthEndReview: sent`. No ledger: the `onSchedule` host has no retry and `maxInstances: 1`. (ADR-0118)
- Name a person in a fan-out by index against the RAW `employeeIds`, never `toIdList`'s (it filters); don't restore `notifyAdminsOfCrewStatus` or the crew push kinds. (ADR-0119)

## Presence (`features/presence`)

- Never re-add `location` to `UIBackgroundModes` or request an Always upgrade (App Store 2.5.4): `PresenceSyncController` (`presence_sync_controller.dart`) runs a foreground-only `getPositionStream`, `LocationPermissionService.ensureLocation` issues exactly ONE prompt (`LocationPermissionService` counts `whileInUse`/`always` as granted), and the address/30-min fallback is the normal path. `NSLocationAlwaysAndWhenInUseUsageDescription` stays declared on purpose — see `ios/CLAUDE.md`. (ADR-0107)
- Gate tracking on `locationSharingEnabled`, absent = OFF; `shouldTrackPresence` DELEGATES to `shouldRegisterPush`, never a re-inlined body. `applyLocationSharing` is the ONE owner of the flip (field AND presence); both surfaces call `saveLocationSharing` (offline guard, `ME-SAVE` tag, notice). The screen's Clear also deletes `presence/location`. (ADR-0107)
- Write `users/{docId}/presence/location` (`updatedAt == request.time`, self-only) on 250 m of movement, at most one write per 2 min, plus a 10-min heartbeat, under `PRESENCE_STALE_MINUTES` (25, `travel_policy.js`), which `presenceStaleAfter` (`live_map_aggregator.dart`) mirrors. On `PresenceWriteResult.failed` roll the throttle clock back; on `denied` also `_stop()`. Classify expected stream deaths with `_isExpectedLocationLoss` (no error record). (ADR-0108)
- Take the resume fix only while the stream is running (`_positionSub != null`), and check the 2-min gap BEFORE `PresenceSyncController._freshFixOnResume`'s `getCurrentPosition`, not only after, then feed it through `_uploadThrottled` (`presence_resume_fix_test.dart`). (ADR-0108)
- Capture `syncGeneration` in `_syncGuarded` and re-check `isSyncStale` after EVERY await — teardown runs before `signOut()`, so a resumed body would re-create presence; `LiveActivityRegistrationController._syncGuarded` does the same. Breadcrumb `PRESENCE not tracking: <reason>`, never warn or nag — a declined permission is a choice, not a defect. `unregister()` must resolve the doc id even when `_start` never ran. Tear down and delete the presence doc on sign-out beside `unregisterCurrentDevice`. (ADR-0108)
- Show staleness as TEXT only (`LiveMapAggregator.isStale`/`freshnessOf`); never dim a marker or hide a pin by age while sharing is on. Keep `LiveMapAggregator.groupTeam` and the proximity helpers pure. The admin collection-group read (`/{path=**}/presence/{presenceId}`) reserves the subcollection name `presence`. (ADR-0109)
- Delete `presence/location` only via `PresenceSyncController.unregister()` and `fcmTokens` only via `unregisterCurrentDevice()`, reached from sign-out, self-service deletion and the `functions/bridge.js` disable/delete; losing the OS permission only runs `_stop()`. A stored fix pins at any age (`staff_marker_icon.dart` has no staleness branch), gated by its owner's `locationSharingEnabled` — keep that gate, the backstop for pre-opt-in presence docs and failed deletes; change `docs/legal/privacy-policy.html` §2, §6 and §8 with it. (ADR-0080)
- Show `ShareLocationAskScreen` (`LocationShareAskGate`) once per app build, marked BEFORE the push, and never push it from a sync path; `isLocationShareAskDue` ignores `locationSharingEnabled`; read permission through `LocationPermissionService.currentStatus`, never `ensureLocation`, which would spend the prompt; hold the calendar tour (`holdsTour`) until it is decided and while the person's own record loads. (ADR-0110)

## Home-screen widget (`features/home_widget`, `ios/ScheduleWidget`)

- Write every payload instant as a UTC instant (`toUtc().toIso8601String()`) — the Swift `ISO8601DateFormatter` can't parse a zone-less one. Change `buildWidgetPayload` (`widget_sync_service.dart`), `functions/widget_payload_utils.js` and the Swift decoder together. Toronto vs device-local day boundaries diverge, accepted for Quebec. (ADR-0111)
- Query `fetchEmployeeWidgetWindow` as an overlap (`endTime >= todayStart AND startTime < end`, exactly `WIDGET_LOOKAHEAD_DAYS` apart), capped at `WIDGET_WINDOW_MAX` (200) with a warn; don't re-widen the floor. (ADR-0112)
- Keep `firebaseMessagingBackgroundHandler` (`core/notifications/fcm_background_handler.dart`, registered via `FirebaseMessaging.onBackgroundMessage` in `main()`) a top-level `@pragma('vm:entry-point')`, iOS-gated, using only the `home_widget` channel after `WidgetsFlutterBinding.ensureInitialized()` — no `Firebase.initializeApp`, Firestore or Riverpod in that isolate. Change pushes carry `widgetPayload` + `content-available`.

## Live Activities (`features/live_activity`, `ios/ScheduleWidget/JobLiveActivity.swift`)

- Keep every Live Activity path additive and best-effort, degrading to the unchanged `leaveNow` push. Keep `sendLiveActivityPush`'s sandbox retry on `BadDeviceToken` (dev builds). Start only off `deliverRecipientOnce`'s return value (`leaveNow`, `delivered > 0`). (ADR-0113)
- Keep `liveActivityCards/{employeeDocId}` as the card-to-job association. Add no `markInProgress` write; the flip is clock-derived. Run `runOnSiteFlipPass` on EVERY sweep — a tech whose job already started is no longer a travel candidate; for a deleted/terminal job it calls `endLiveActivity` then `clearCardMarker` (`endLiveActivity` skips the marker clear when no token rows remain). End via `endCardOnTerminal` on `done`, `cancelled`, deleted and unassigned, unconditionally — never through the notification diff, which goes silent past the scheduled end while the card still counts the overrun. The client never ends cards. "Complete" is a deep link, never a write in the extension. (ADR-0113)
- Name the attributes type exactly `LiveActivitiesAppAttributes` in the struct, `ActivityConfiguration(for:)` and `ATTRIBUTES_TYPE`; keep `LiveActivitiesAppAttributes.swift` out of the Runner target. (ADR-0113)
- Build card text server-side (`live_activity_utils.js`, never `NSLocalizedString`), mirror `buildContentState`/`buildAttributes` in Swift, thread `endTime` through every dispatch `ctx`, and with no `leaveAt` render `startsAt`, never "Leave at" the start time. (ADR-0114)
- Refresh `marker.startTime` via the `setCardStart` merge on EVERY `updateLiveActivity`, never `setCardPhase`; run the reschedule refresh per occurrence ABOVE the series claim. (ADR-0114)
- Let only `LiveActivityRegistrationController` write push-to-start token rows (`liveActivityTokens`, kind `pushToStart`, `expiresAt` = now + `liveActivityPushToStartTtl`, 30 d, under the rules' 31 d cap). Prune a row only on a dead-token APNs reply (`result.gone`), the daily `pruneExpiredActivityTokens` TTL sweep, or the opt-out `unregister()` — never on a pause (`feature_live_activities` off returns before any send), since nothing re-emits push-to-start. (ADR-0115)
- Probe capability only in `LiveActivityRegistrationController.canHostCards()`. The opt-out (`liveActivityEnabledProvider`, default on) must call `unregister()`; a cold-start `sync()` must `await` `ready`. Deploy `firestore:indexes` with the functions, or the card silently never appears. (ADR-0115)

## Siri snapshot and CarPlay (`features/siri`, `ios/SiriIntents`, `ios/Runner/CarPlay`)

- Resolve every off-app mirror's identity through `activeUserIdentityProvider`, fetch `AppointmentDateRange.forMirrors(today)` (never narrow one mirror alone), and `ref.watch(currentDayProvider)`, not `DateTime.now()`. (ADR-0116)
- Skip emissions `AppSyncListeners.isUnsettled` flags — an error or loading value is null too, and clearing on it blanks the mirror. `ScheduleSnapshotService.apply` owns "null clears, otherwise write"; add no explicit sign-out clear. (ADR-0116)
- Keep `buildScheduleSnapshot` and `ScheduleSnapshot.swift` in lockstep and bump `version` on both; the Swift decoder accepts 3 OR 4 on purpose. Drop cancelled visits and null/empty `id`s. Ship only what the intents speak, never notes, phone or pictures — the App Group is readable while locked. Keep `SiriIntents` Firebase-free until Phase 4. (ADR-0116, ADR-0117)
- In an admin snapshot blank another person's personal `address` (empty `viewerDocId` withholds all); index `crew` names against RAW `employeeIds` with the stored ARGB; prefer the denormalized `viewer` name over `users.name`. (ADR-0117)
- Treat `CarPlayBridge` as freshness only. Never gate `setAppointmentStatus`/`dialableNumberFor` on `AppLockController`; fail the status write fast offline (`false`, `CARPLAY`). Fetch numbers on demand, never into the snapshot. Entitlement setup: `ios/CLAUDE.md` (CarPlay). (ADR-0117, ADR-0173)
