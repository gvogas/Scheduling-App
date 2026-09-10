---
paths:
  - "lib/features/calendar/**"
  - "functions/**"
  - "test/features/calendar/**"
  - "test/core/security/appointment*"
  - "firestore.rules"
  - "storage.rules"
---

# Appointments

Loaded when working on appointments. Root context: `../../CLAUDE.md`.
Calendar *rendering* rules live in `lib/features/calendar/CLAUDE.md`.

- **Appointment status allowlist:** The lifecycle is `pending` →
  `in_progress` → `done`, plus `cancelled` (set by the separate Cancel action).
  These four are the ONLY valid *stored* values — enforced by
  `isValidAppointmentStatus` in `firestore.rules` and `_allowedStatuses` in
  `firebase_appointments_repository.dart`. New appointments must be created
  with `status: 'pending'`. **`AppointmentStatus.overdue` is a display-only,
  time-derived state — NEVER stored, NEVER in the picker.** `displayStatus`
  (`appointment_record.dart`) maps a non-terminal visit to `in_progress` while
  now is within [start, end] and to `overdue` once `endTime` has passed.
  **That ladder has exactly ONE owner: `AppointmentRecord.displayStatusAt(now)`;
  `displayStatus` is `displayStatusAt(DateTime.now())` and
  `DashboardAggregator.displayStatusAt` delegates to it.** The dashboard used to
  carry a hand-copied "mirror" of it and had already drifted — it was missing
  the `isPersonal` carve-out, so a personal block past its end read "Scheduled"
  on its card and sat under the dashboard's Attention list as *overdue* —
  nagging an admin to close something "job finished?" is the wrong question
  for. (A personal block CAN be marked complete: `DetailsActionBar`
  gates that button on `!isDone && !isCancelled` with no
  `isPersonal` branch — and, since 2026-08-17, no clock gate either. An earlier note here justified the carve-out by claiming
  personal jobs have no mark-done flow — they do; the carve-out stands on the
  wrongness of the prompt, not on the absence of a way out.)
  Never re-copy the ladder; add clock-derived rules to
  `displayStatusAt` only. The
  card/tile and the read-only detail header render `displayStatus`, but the edit
  picker and all writes seed from the real stored `status` (so `overdue` can't
  leak into a write). Don't add `overdue` to `appointmentValues` or the
  allowlist; reading `AppointmentStatus.overdue.raw` **throws** on purpose so a
  stray write path fails loudly at the source instead of emitting an
  off-allowlist value that the rules reject with an opaque `permission-denied`.
  **"Terminal" as a set of RAW STRINGS has one owner:
  `terminalStatusRawValues` in `calendar/domain/appointment_status_values.dart`**
  (2026-08-08) — `{done, completed, cancelled}`, deliberately Material-free so
  `AppointmentRecord.isClosed` and the History query's `whereIn` can share it.
  It had four definitions and the History one had dropped the legacy
  `completed` alias, so such a doc rendered as Done on its card and was
  **invisible in History and history search**, with no error anywhere.
  `AppointmentStatus.isTerminal` is the enum-level mirror and
  `appointment_status_values_test.dart` pins the two together. (`confirmed` was retired 2026-07-09 when the picker
  collapsed to three states; `done` is labeled "Complete" in the UI. Account
  statuses `active`/`invited`/`disabled` live in the separate `UserStatus` enum
  — `shared/widgets/feedback/user_status_chip.dart` — not `AppointmentStatus`.)
  **Any edit that re-serializes a stored record must normalize its status
  through `AppointmentStatus.storedRaw(status)` before writing** — legacy
  `confirmed`/unknown docs exist, an unchanged status is re-written verbatim,
  and the rules reject anything off the allowlist (a raw write would fail the
  whole save/series-update with `permission-denied`). Use `storedRaw`, never
  `fromRaw(x).raw`: it maps legacy/unknown AND the display-only `overdue` onto
  `pending`, so it can't throw the way a bare `.raw` does. Done at the seed in
  `event_details_controller`, per-sibling in `appointment_series_editor`'s
  `propagate`, and in the Siri snapshot builder. `UserStatus.fromRaw` is the
  matching mapper for account statuses (unknown/empty → `invited`).
- **"Mark as complete" carries NO clock gate at all** (owner call, 2026-08-17,
  which widened the 2026-07 `hasStarted` rule). `DetailsActionBar` offers it on
  every open job — the only conditions are `!isDone && !isCancelled` — so the
  bar reads nothing from the clock and `details_view_body.dart` derives no
  `now`. The old `!appointment.startTime.isAfter(now)` gate already existed
  because the edit form's status picker is admin-only, so an employee who
  misses the button before midnight (or is on day 2+ of a multi-day visit) has
  no other way to close a job the server keeps nudging them about; the same
  reasoning applies before the start time, to a crew that finishes early or a
  job booked for later today. The rules have always allowed an assignee to
  write `status:'done'` with no date restriction (pinned by
  `appointment_employee_update_rules_test.dart`), so nothing server-side
  changed. Don't reintroduce a start-time or "is today" test here.
  **That branch now also pins `updatedAt == request.time`** (2026-08-28).
  `updatedAt` has to be in the `hasOnly(['status', 'updatedAt'])` diff, and
  admitting it unpinned let a modified client stamp an arbitrary — future,
  past or non-timestamp — value while closing a job it is assigned to. Nothing
  server-side branches on an appointment's `updatedAt`, so this is audit-trail
  integrity rather than a closed exploit. Safe to pin because BOTH client write
  paths (`updateAppointmentStatus`, `updateAppointmentStatuses`) send
  `FieldValue.serverTimestamp()` unconditionally — a new status-write path that
  omits it will be refused here.
- **Admin-only appointment actions are gated by an explicit `showActions`.**
  `showEventDetails(..., showActions:)` is a REQUIRED param, and
  `EventDetailsSheet` / `EventDetailsView` both default it
  **CLOSED** (`false`). A default of `true` silently showed employees the
  Edit/Cancel/Delete affordances, which the rules then reject with an opaque
  `permission-denied`. Pass the caller's resolved role; never re-add a `true`
  default. (Rules remain the real gate — this is defense-in-depth plus UX.)
  **A DONE job's edit affordance is the action bar's bottom button, not the
  top chip** (owner call, 2026-08-08): `DetailsViewBody` suppresses
  `DetailsEditChip` when the stored status is done and hands
  `DetailsActionBar.onEdit` instead, which takes over the slot the inert
  "Complete" indicator held — that job has no mark-done or cancel action left,
  so the slot was dead. `onEdit` is null-gated on the same `showActions`, so a
  read-only surface (client job history) still renders the indicator and offers
  nothing. Cancelled and open jobs keep the top chip. The two move together:
  don't restore the chip on a completed job without removing the button, and
  don't drop the button without bringing the chip back, or a finished job
  becomes uneditable again.
  **`AppointmentHistoryView` takes an `isAdmin` and passes it straight through
  as `showActions`** (restored 2026-08-08 after a revert dropped it). It used to
  hardcode `false` on the grounds that History is a read-only surface, but
  History is where `done` and `cancelled` jobs actually LIVE, so that made the
  completed-job edit button above unreachable from the one screen an admin would
  look for it on. It still DEFAULTS closed like every other appointment surface;
  `HistoryScreen` passes `widget.isAdmin`.
- **A route argument's `isAdmin` is a push-time SNAPSHOT — a live gate reads
  `isActiveAdminProvider` instead** (`features/auth/application/`, 2026-09-06).
  It is `role == 'admin' && status == 'active'` off the already-live
  `currentUserDocProvider`, and **fails CLOSED whenever the doc is unsettled,
  errored or EMPTY**, matching the least-privilege default every appointment
  surface already takes. **The empty case is not hypothetical and is an
  ACCEPTED limitation** (reviewed 2026-09-07): a settled empty doc is the
  bootstrap window a fresh sign-in and a cold cache both pass through, so for
  its duration a real admin reads as not-admin — `AdminOnly` shows
  `InvalidRouteScreen`, the drawer drops its admin rows. It fails in the SAFE
  direction and self-heals when the doc settles, it is the same answer
  `readAccountGateInputs` gives in the same window, and a genuinely empty doc
  is `SplashScreen`'s and `AccountExitListeners`' business, not this
  provider's. Holding the last settled answer instead was considered and NOT
  taken: it needs a uid to hold against (or one session's answer carries into
  the next person's), which makes this depend on `authUidProvider` and drags
  Firebase auth into every widget test that only overrides the doc provider.
  Don't file the flicker as a new bug — reopen this decision, with that cost
  named. A stale back stack, an argless push or a deep link can all carry an
  `isAdmin: true` argument that no longer describes the signed-in person; this
  asks Firestore instead. **Five consumers, and they gate differently.**
  `DayRouteScreen` resolves `widget.isAdmin && ref.watch(isActiveAdminProvider)`
  **once** and feeds that value to the crew picker, the
  `appointmentsInRangeProvider`/`myAppointmentsProvider` choice, `buildDayRoute`
  and `showEventDetails(showActions:)` — and, load-bearing, into
  `_prepareBuild`'s memo key, or the first cached `DayRoute` wins forever. The
  `/history` route (`app_routes.dart`) wraps `HistoryScreen` in the `AdminOnly`
  gate widget, which watches it directly and degrades to `InvalidRouteScreen`
  for anyone else. `DetailsViewBody._canRecordFieldWork` reads it too (below).
  `SettingsScreen._isAdmin` (2026-09-07) resolves the same pair for its
  admin-only sections — today the Wave integration card — over
  `_isAdminArg`, the raw argument its tour wiring keeps. `AppNavDrawer`
  resolves it ONCE in `build` and feeds the admin groups, the header's role
  label and the calendar row's count query from that one value; the rows
  themselves come from `drawerGroups(isAdmin:)`, a pure function, so the gate
  belongs at the widget that feeds the catalog and not in the catalog.
  **The fail-closed guarantee does NOT transfer to `_canRecordFieldWork`**,
  which reads it as a NEGATIVE gate — `if (isActiveAdminProvider) return
  false;`, so `false` is a step toward GRANTING the compose box rather than
  refusing it. That is safe today only because `activeUserIdentityProvider.value`
  is also null in the same unsettled window, which is a SECOND guard and not a
  property of this provider's own contract — a refactor that removes or
  reorders that second check would open the compose box to a not-yet-resolved
  viewer with nothing here to stop it.
  **The deliberate exception:** the `_tour` and `FeatureTourHost` of both
  `DayRouteScreen` and `SettingsScreen` stay on the route argument, never the
  live gate — `TourSteps` owns GlobalKeys
  that must stay stable across rebuilds, and the one admin-only step is a
  `stepIf` on a widget that no longer renders once the crew picker is gone.
- **Personal jobs (`isPersonal`, added 2026-07-31) carry no client, and their
  address is OPTIONAL** (owner call, 2026-08-11, which reversed the original
  "no address"). The switch at the top of the form's WHO section is on BOTH the
  add and edit flows (unlike the template chips), because the flag is stored and
  has to be reversible. Turning it on hides the client picker, clears its
  controller and drops `clientRequired` from `AppointmentFormValidator` —
  **the assignees stay required**, they are who the block is for and who can
  see it. Both save paths write `clientId`/`clientName`/`clientPhone` as
  **empty strings**, including when an existing client visit is converted, so a
  hidden field can never keep a stale value the UI no longer shows.
  **`address` is deliberately NOT in that set**: a dentist appointment or a
  supply run still happens somewhere, and the crew wants directions to it. The
  field stays on screen for a personal job, marked "(Optional)"
  (`AppointmentAddressField.optional`, forwarded to `AddressAutocompleteField`),
  and both save paths write `address.trim()` unconditionally — so the
  "hidden field can't keep a stale value" reasoning doesn't apply to it: what
  saves is what the user can see and edit. The switch therefore must NOT clear
  `controllers.address`, which is the one clear that was removed here; the
  validator never required an address on any job, so nothing was relaxed there.
  Every read surface already gated on `address.isNotEmpty` (the detail row, the
  Directions quick action), so a personal job with one renders it and a
  personal job without one is unchanged — and a *timed* one with an address is
  now a genuinely routable travel candidate rather than one that always
  degraded to the fixed 30-minute reminder for want of a destination.
  Everything that speaks a client name falls back
  to the **title**: the card and the detail row say "Personal"
  (`calendar_personal`), the widget and Siri decoders already fell back to
  `title`, and `_who` in `functions/notification_messages.js` now does too
  (`_contextFor` therefore has to keep passing `title` through).
  **`live_activity_utils.js` carries its OWN `_who` with the same fallback, and
  it is not optional:** a *timed* personal job is still a travel candidate, so
  the `leaveNow` push and the Lock Screen card describe the same trip at the
  same moment — the card read "Client"/"un client" while the push read
  "Dentist" until `title` was threaded through. Every `ctx` passed to
  `startLiveActivity`/`updateLiveActivity`/`endLiveActivity` (the sweep, the
  on-site flip, the terminal end, the reschedule hook) must carry `title`, and
  `_stateFor` must forward it into `buildContentState` — the state builder
  field-picks its `ctx`, so a dropped field fails silently back to "Client".
  **Build that `ctx` with `liveActivityCtx(record, opts)`
  (`live_activity_utils.js`) — never a hand-written object literal.** There were
  four copies and they had already drifted again (two normalized `address`, two
  passed it raw), which is exactly the silent-failure shape above.
  `propagateClientEdits` can't touch these — it
  queries by `clientId`, which is empty. Also dropped from a personal job: the
  template chips, the repeat picker, materials and photos. The **title is
  optional** there and an unnamed one saves as "Personal" — substituted in the
  widget layer (both sheets), which is where `l10n` lives. The edit form shows
  the switch **only when the job is already personal** (`onPersonalChanged: null`
  otherwise), so an ordinary client visit can't be converted mid-life. Turning
  it on clears the hidden text controllers and, in the ADD flow only, resets
  `repeat` — the edit flow keeps its repeat, where clearing it would rewrite a
  live series.
- **A personal block can be marked TIME OFF (`isDayOff`, 2026-08-24), and time
  off is NEVER COUNTED AS A JOB but is ALWAYS STILL SHOWN AS A CARD.** That
  sentence is the whole rule, and both halves are load-bearing. The stored flag
  is written by the "Day off" chip under the personal switch on both forms; the
  question every consumer asks is the derived `AppointmentRecord.isTimeOff`
  (`isPersonal && isDayOff`), **never the raw flag** — a client visit carrying a
  stray `isDayOff` from a console edit or an import must not be able to vanish
  from every tally with nothing on screen explaining why. Both controllers clear
  it when the personal switch goes OFF (the chip goes with the switch, so a
  surviving flag would be unreachable), and `AppointmentSeriesEditor` copies it
  onto every sibling for the same reason it copies `isAllDay` — a week of
  holiday booked as a series would otherwise go back to counting as work from
  the second occurrence on.
  The COUNT side: `dottedJobsOn` (month grid dots + the cell's semantics
  count), `_jobLabel` (the agenda header's `N JOBS`), `countsAsLoadOn`
  (`appointment_day_slice.dart` — the shared "is this that day's load"
  predicate behind BOTH the drawer badge and the roster's `jobs today`, which
  had been kept in step by a prose "matching employeeJobsTodayProvider" comment
  and had already drifted on how each spelled the cancelled half; since
  2026-08-25 it is **`countsAsWork` plus `runsOn`**, and `countsAsWork` — "not
  cancelled, not time off" — is the one owner every count filters through,
  the agenda header and the month grid's dots included) and
  `dashboardRecordsProvider` — the dashboard filters ONCE at the records
  provider rather than in each reducer, so the KPI numbers, the workload bars,
  the daily-load capacity and the availability flags all agree that a booked
  absence is neither work done nor capacity used. The CARD side: the agenda,
  the detail sheet and the employee detail's TODAY panel all still render it,
  wearing a `DayOffChip` in place of the status (time off is not a point in the
  pending → done lifecycle, which is also why it is not an `AppointmentStatus`
  member — one would force a branch into `storedRaw`, the picker and the rules
  allowlist for a value nothing stores). (A short-lived
  `appointmentChip`/`appointmentChipLabel` resolver and a `DayOffChip` existed
  between those two steps, for a day off that still rendered AS a card; the
  strip made both unreachable and they were deleted. Don't reintroduce one from
  an older diff.) The roster is the one place the two
  sides meet and the asymmetry is DELIBERATE: the row reads "0 jobs today"
  above a panel listing a "Day off" card, because a count answers *how much
  work* and a card list answers *what is on this person's day*.
  **A day off is NOT a card and NOT a lifecycle** (owner call, 2026-08-24,
  designed in `docs/archive/2026-08-24-day-off-card.md`). `AppointmentCard`
  returns `_DayOffStrip` for one — a low tinted strip, no fill and no shadow.
  Rendering it inside the card rather than at the call sites is what gives
  every appointment surface the same treatment for free. The detail sheet has
  its own `_DayOffBody` — when-line, length, note — with no client section,
  address, materials, photos or action bar.
  **The strip's own layout rules — the typed reason leading it, the localized
  "Personal" placeholder trap on the title, and the dashed crew rail — live in
  `lib/features/calendar/CLAUDE.md`**, which is their one home; they are pure
  Flutter with no `functions/` twin. Two clauses of this bullet were REVERSED
  there on 2026-08-25 and are noted here only so an older copy isn't trusted:
  the strip no longer "names the PERSON, never the title" (the typed reason is
  the headline now, with the person beneath it), and it is no longer true that
  it has "no crew colour BAR" (it has a dashed one). Don't restore either from
  this file.
  **It COMPLETES ITSELF at the end of its last day**, and that branch lives in
  `displayStatusAt` ABOVE the `isPersonal` early return (a day off is personal,
  so it would otherwise never be reached). Derived, never stored: no sweep, no
  write, and it cannot be late — the same contract `overdue` has. Consequences
  worth keeping straight: there is no **Mark as complete** and no **Cancel** on
  a day off (delete it instead), so nothing can put it into a STORED terminal
  status; `_agendaOrder` and `isClosed` read the stored status and are
  deliberately clock-free, so a finished day off stays in date order rather than
  sinking into the day's closed block; and the agenda's closed rule counts only
  the JOBS below it (`closedJobCount`) so a legacy stored-done one cannot make
  the header and the rule disagree. The stored status stays `pending` forever,
  so `purgeExpiredHistory` never purges a day off — accepted, at a handful per
  person per year.
  **`findBusyEmployees` is deliberately NOT filtered** — booking time off is
  exactly how someone is made to read as unavailable, which was the most
  valuable thing the P6 stopgap bought. **It is now the PERMANENT answer, not a
  stopgap: P6 was CANCELLED by owner call 2026-09-06** (see
  `docs/archive/2026-07-29-redesign-program.md`), so there will never be a
  `timeOff` collection, a request/approve flow or an allowance. This flag closes
  the old stopgap's "counts as a job in the dashboard" limitation. No rules change was needed: the appointment validator is a per-key
  bounded check, not a `hasOnly` allowlist, and it type-checks neither
  `isPersonal` nor `isAllDay`. The off-screen mirrors (push text, widget, Siri,
  Live Activities) are UNCHANGED and still treat a day off as any other
  personal block.
- **An all-day block (`isAllDay`) stores real instants**, midnight → 23:59, so
  every range query, `orderBy('startTime')` and sweep keeps working unchanged —
  the flag only changes how it is SHOWN (`allDaySpan` builds the pair).
  **Neither save path may re-derive that pair itself** — both the add and edit
  controllers resolve their instants through the one `appointmentSpan(...)`
  helper beside `allDaySpan` (`calendar/domain/policies/appointment_form_validator.dart`),
  which picks the all-day span or the picked times. Hand-writing the ternary in
  a controller gives the convention three owners, and a change to it (23:59 →
  23:59:59, a DST-safe end) then lands on one save path and not the other.
  **`setPersonal(value: false)` MUST NOT clear `isAllDay`** (2026-08-03).
  It used to — the switch was personal-only, so a surviving flag saved a
  midnight–23:59 *client* visit with neither the switch nor the time rows on
  screen to repair it. **All-day is now offered on EVERY job**, so that state is
  reachable, repairable and legitimate: a client visit can genuinely run whole
  days. Clearing the flag now discards a deliberate choice, and both controllers
  pin the new behaviour with a test. **The two controllers are NOT symmetric
  here, and this is the part that is easy to get wrong.** `AddEventController`
  keeps the ON-direction default: `setPersonal(value: true)` sets `isAllDay`
  when neither a start nor an end time has been picked, and leaves it alone on
  the way OFF (pinned by "turning Personal on with no times picked still
  defaults to all-day" / "turning Personal off KEEPS an explicitly set all-day",
  `add_event_controller_test.dart`). `EventDetailsController` does **not** touch
  `isAllDay` in EITHER direction — the flag is whatever the saved record and the
  user's own switch made it, and turning Personal on does not resurrect all-day
  (pinned by "turning Personal on again does not resurrect all-day",
  `event_details_controller_test.dart`). The asymmetry is deliberate: on the add
  form there is no stored value to protect and an untimed personal block almost
  always means all-day, while on an edit any default would overwrite a choice
  already made. The travel sweep still skips all-day
  records (no departure time to compute), and the overdue sweep still gates on
  `isPersonal`, so an all-day *client* job does go overdue after its 23:59 end —
  which is correct. **There is no longer an end-after-start check to gate**: an
  end time at or before the start time now means the window crosses midnight
  (see the multi-day bullet below). Now offered
  on every job, ON by default for a personal block when no time has been picked,
  and it hides the start/end rows. The switch is the schedule `SheetPanel`'s first
  row — **that panel holds the whole of "when": all-day, date, start/end and
  the repeat rule**, which is a `SheetFieldRow` + `showAdaptiveActionSheet`
  rather than the standalone dropdown it used to be (owner call, 2026-07-31). `AppointmentCard` and the detail when-line render
  "All day" instead of "12:00 AM – 11:59 PM". A personal job also **never
  derives `in_progress`/`overdue`**: `displayStatus` returns its stored status
  (which reads "Scheduled"), and `selectOverdueCandidates` in
  `functions/notification_utils.js` skips `isPersonal` records for the same
  reason — "job finished?" is the wrong question for a dentist appointment.
  Keep those two in sync. **`isAllDay` is threaded through all four off-screen
  mirrors** (2026-07-31), and each one needs it for a different reason:
  - **Reminder sweep** — `selectTravelCandidates` (`functions/travel_utils.js`)
    skips all-day records. Without it the midnight start put the block inside
    the 90-min window at ~23:30 the night before and fired a "time to leave"
    push for something that has no departure time. A *timed* personal job keeps
    its reminder; only the all-day skip is new.
  - **Push/digest text** — `_contextFor` carries `isAllDay`, and
    `notification_messages.js` renders the date alone ("Wed, Jul 8") instead of
    "Wed, Jul 8, 12:00 a.m."; `_whoAt` joins with "·" rather than "at"/"à",
    since there is no clock time to sit after the preposition.
  - **Home-screen widget** — `isAllDay` is in the job JSON in BOTH hand-mirrored
    builders (`widget_sync_service.dart`, `widget_payload_utils.js`) and the
    Swift `Job` decodes it as `Bool?` so a pre-existing payload still parses.
    `timeLabel` says "All day". **The "today" filter is `endTime`-based for an
    all-day block** — the old `startTime.isAfter(now)` test dropped it from
    today from 00:00 onward, so it appeared only under *tomorrow* and then
    vanished. `DaySchedule.nextJob` prefers a timed job, falling back to the
    all-day one, or a midnight block owns "up next" all day.
  - **Siri snapshot** — **v2 of the schema** (`scheduleSnapshotVersion`, matched
    by `supportedVersion` in `ScheduleSnapshot.swift`; the CURRENT value is
    **3** — see the multi-day mirrors bullet below, which bumped it): adds
    `isAllDay` AND
    `title`, since a personal job has no client and the snapshot previously had
    no title to fall back to, so Siri said "unnamed client". `SiriStrings.who`
    is now the single client→title→placeholder resolver and `timePhrase` speaks
    "all day"; `nextAppointment` applies the same prefer-timed rule as the
    widget, and treats an all-day block as upcoming until its 23:59 end.
    **That prefer-timed test must be scoped to the block's OWN span**
    (`$0.start < earliest.end`), not to every timed visit in the 7-day window:
    the widget's `nextJob` runs against a single day's bucket, but the Siri
    snapshot is flattened across 8 days, so a window-wide comparison skipped
    today's all-day block whenever *any* later day held a timed job — Siri
    answered with Thursday's visit and never mentioned today's.
- **An appointment may span up to `maxAppointmentSpanDays` (14) days, and its
  two times are a DAILY WINDOW** (2026-08-03) — 9:00 AM–5:00 PM means 9–5 on
  *each* of those days, not one unbroken stretch through the nights. **No schema
  change**: `startTime`/`endTime` already carry the span, `isMultiDay` is
  derived and never stored (same discipline as display-only `overdue`).
  **`firestore.rules` bounds the span too, as of 2026-08-11** —
  `isValidAppointmentSpan`, on `allow create` and the admin `allow update` —
  but rules reach CLIENT writes only, so the app's clamp is still what contains
  a console or Admin-SDK write. The bound is **14 days inclusive PLUS a two-hour
  DST allowance**: a run booked at one clock time (09:00 → +14d 09:00) is a
  legitimate chain of 24-hour windows, so a `<` would reject the widest thing the
  form can save. The `+2h` is the unit mismatch, not slack — the app counts
  CALENDAR days and `combineDateAndTime` composes LOCAL wall-clock instants,
  while CEL's `duration.value` is absolute, so a window containing the autumn
  fall-back stores an hour MORE than its calendar length (that widest run
  becomes 14d 1h; a 14-day all-day block 14d 0h59m). A flat `duration.value(14,
  'd')` therefore refused, for about two weeks each autumn, a booking the form
  had already accepted — as an opaque `permission-denied`. Pinned by
  `appointment_span_rules_test.dart`; don't "simplify" the term away.
  **An UPDATE whose span is out of range but not WIDENED still passes**
  (`appointmentSpanNotWidened`) — the same asymmetry as `emergencyFieldNotSet`,
  and for the same reason: a doc that already exceeds the cap must stay
  updatable, or the admin trying to CANCEL it is refused too. Don't
  "simplify" that branch into a flat bound. An assignee's status flip never
  reaches either guard (that branch restricts the diff to `status`/`updatedAt`).
  Consequences that must stay in sync:
  **`AppointmentDaySlice` (`calendar/domain/appointment_day_slice.dart`) is the
  ONE owner of day-scoping** — `sliceFor` / `expandToDays` / `lastWorkDayOf`
  (plus `lastWorkDayOfWindow`, its raw start/end form, for the one caller that
  holds a resolved pair and no record yet: the booking-conflict dialog).
  Never re-derive a day index or a run length at a call site, the way the
  `displayStatusAt` ladder and `_who` were re-derived and drifted.
  **The per-work-day window fan-out has ONE loop, `expandRunWindows`**, and
  the private `_windowsOf` behind `dailyWindowsOverlap` delegates to it
  (2026-08-28). They were the same body twice in this one file, differing only
  in the incoherent-pair answer — `const []` for "nothing to check" versus one
  window for "still something to book". That split matters: the windows a run
  is WRITTEN with and the windows it is CHECKED against for clashes have to be
  the same arithmetic, or a DST or overnight change lands on the booking path
  and not the conflict path and surfaces as phantom or missed clashes on
  multi-day jobs alone. Keep the delegation; don't re-inline the loop.
  **The end date names the last day the crew STARTS work**, never the morning an
  overnight run finishes, so the length is `end − start + 1` for day jobs and
  night shifts alike. A window whose end time is at or before its start time
  crosses midnight and counts **nights** — which is why **there is deliberately
  no end-time-after-start-time validation**: that ordering IS a night shift.
  (Consequence, accepted: picking 9:00–9:00 on a one-day job books 24 hours
  rather than erroring, because it is structurally identical to a legitimate
  one-night shift.)
  **Slices are generated per WORK day** — each day the window *begins* — not per
  calendar day the stored instant span touches; that is what keeps a night shift
  off the morning it ends.
  **`AppointmentDateRange.fetchStart` widens the query 14 days back and MUST
  stay a derived getter**, never a constructor field: `==` is keyed on
  `start`/`end`, so two surfaces asking for the same day still produce equal
  ranges and share one listener. Widening at a call site instead forks a second
  Firestore query for the same day.
  **"All day" is reserved for `isAllDay`** and is never borrowed to describe a
  timed job's middle day — the card reads `9:00 AM – 5:00 PM · Day 3 of 5`.
  A continuing *timed* job has a real start time that day and sorts in clock
  order; only all-day blocks pin above the day.
  **A RANGE STREAM IS A SUPERSET OF ITS RANGE — every consumer must re-scope**
  (2026-08-04 audit). Because the query starts at `fetchStart`, the emitted list
  holds every job that STARTED in the previous 14 days. Only the calendar
  clipped it; the day route, the roster's "jobs today", the employee detail's
  TODAY panel and the drawer's calendar badge all read it raw and silently
  reported a fortnight of past jobs as today's. Re-scope through
  **`runsOn(appointment, day)`** (beside `sliceFor` in the same owner file) —
  never by comparing `startTime` at the call site. A reducer over
  `appointmentsInRangeProvider` without a day predicate is a bug.
  **And a "today's window" test on a MULTI-DAY run must use the SLICE's
  window, not the record's `startTime`** (2026-08-11): the dashboard's
  "Upcoming today" re-scoped through `runsOn` and then asked
  `startTime.isAfter(now)`, i.e. the run's first morning — so on day 3 of a
  14:00 job the status counts included it while the section rendered "No visits
  today", and sorting on the stored instant floated it above jobs genuinely
  earlier that day. `computeTodayOps` now carries `AppointmentDaySlice`s.
  **`appointmentsInRangeProvider` is ADMIN-ONLY, and every non-admin consumer
  must role-branch to `myAppointmentsProvider`**: its query constrains
  `startTime` alone, and for a LIST query the rules are evaluated against the
  CONSTRAINTS, so `isAssignedEmployee` rejects a technician's whole query.
  `MyDetailsScreen`'s availability-conflict warning read it raw, and the
  rejection was swallowed by a `?? const []` — the warning silently never fired
  for the only role that screen exists to serve, while a permanently-failing
  listener stayed open. The Siri snapshot and the drawer badge already branch;
  copy them.
  **A conflict check is a DAILY-window overlap, not an instant overlap.**
  `findBusyEmployees`' Firestore query is only a coarse prefilter; its results
  are filtered through **`dailyWindowsOverlap`** (same owner file). Testing the
  raw instants reported a 9-5 run across a week as clashing with a 7 pm job
  inside it — a phantom clash the admin had to force through on every evening
  job. That helper compares ALL window pairs rather than matching day indices,
  because an overnight window runs into the following calendar day.
- **A multi-day JOB is N appointments, one per day; a multi-day PERSONAL block
  is still ONE wide document.** (2026-08-27, designed in
  `docs/archive/2026-08-27-per-day-appointments.md`.) One document carries one
  `status`, so a wide job closed entirely the moment the crew marked day 1
  complete. The days of a run share `seriesId` — day 1's doc id, the SAME field
  a repeat uses — and each carries a stored `dayIndex`/`dayCount`. That overload
  is safe only because **the repeat picker is hidden on a multi-day form**; the
  two mechanics must never coexist, or "this and the following" means two
  things. Re-adding repeating multi-day work means a separate `runId`, never
  another meaning for `seriesId`.
  **The stored pair is the LABEL ONLY, and that is the whole trap.**
  `_dayIndexOn` answers both "does this run on this day" and "what does the card
  say"; feeding a stored `dayCount: 5` into the first makes day 3's document
  claim the five days after its own start, and `runsOn` is the mandated
  re-scoping call on the drawer badge, the roster's jobs-today and the
  dashboard's day reducer, so all three inherit it at once. `sliceFor`
  substitutes into the slice it RETURNS; `_dayIndexOn` stays purely derived. The
  substitution additionally requires the document's OWN window to be one day, so
  a stored pair on a legacy wide doc cannot print one day's label on all of
  them. Hand-mirrored by `storedRunLabel` in `functions/day_slice_utils.js`; the
  two suites share worked examples.
  **`toMap` emits the pair only when it is COHERENT** (`hasRunLabels` =
  `isRunMember && 1 <= dayIndex <= dayCount`), not on `isRunMember` alone.
  `dayIndex` parses to 0 when the source doc has none, and the rules bound
  it at `>= 1`, so a console-written doc carrying `dayCount: 5` with no
  `dayIndex` would re-serialize as `dayIndex: 0` and be refused on EVERY
  later edit — including the cancel that would clear it. Dropping the
  labels repairs such a doc where emitting a rejected value strands it;
  same asymmetry as `appointmentSpanNotWidened`.
  **`AppointmentDaySlice` is NOT legacy.** It stays the live representation for
  time off and personal blocks, which deliberately do not split — nothing marks
  a day off complete, and a fortnight of holiday fanned into 14
  independently-cancellable rows makes the clash alert and the availability
  reducer read 14 documents where they now read one span.
  **A run's SCOPE is selected by `dayIndex`, not `startTime`.**
  `futureSeriesRecords`/`futureSeriesIds` (`event_series_helpers.dart`) take an
  `anchor` and compare stored day positions when it carries a coherent run
  pair; a repeat series (and any legacy document) still compares `startTime`.
  Both axes live in one helper because a run member's START date stays
  editable: moving day 1 past its siblings made "cancel this and the following
  days" select NOTHING and report success, while the same action on day 4 swept
  the moved day up. Pass the anchor at every run-scoped call site — cancel and
  delete did; `planPropagate` did not, and it is reachable by a run member
  through the scope dialog, so "save this and following" reproduced BOTH
  failures the parameter was added to prevent.
  **The dialog's COUNT derives from the same selection it describes.**
  `seriesOutlook` lives beside `futureSeriesRecords` and is built FROM it, so
  the number the admin confirms cannot disagree with what is written. Its own
  earlier scan counted terminal siblings that are never written and used the
  wrong axis on a run — a count is a promise about a write, so derive it from
  the write's selection rather than re-deriving the selection.
  **Only the ADD path splits a span into per-day documents**, so the EDIT form
  must not be able to widen a client job: `AppointmentFormFields.canSpanDays`
  gates the end-date row and `details_edit_body` passes `isPersonal`. Without
  it an edit wrote the single WIDE document this design exists to eliminate —
  it renders "Day 3 of 5" through the derived branch, so it is
  indistinguishable from a real run, but marking one day complete closes every
  day of it. Personal blocks and time off KEEP the row; they legitimately stay
  one wide document.
  **A run is ONE job everywhere a job is COUNTED or LISTED.**
  `recountClientJobs` subtracts a second `count()` over `dayIndex > 1` (the
  inequality excludes a single-day job, which has no such field, and day 1,
  which stores 1 — so no backfill was needed), served by the
  `(clientId ASC, dayIndex ASC)` composite; `fetchClientHistory` filters
  `dayIndex <= 1` in DART, because a server-side inequality would drop every
  document written before the field existed. A document count made a
  Monday-to-Friday booking read as five jobs on a badge captioned "jobs".
  Known and accepted: nothing renumbers the pair after a this-day-only delete,
  so survivors keep reading "of 5" — the scope actions stay correct, only the
  label is stale.
  **A run's LENGTH is fixed at booking** (the end-date row is hidden on a run
  member, via `AppointmentFormFields.isRunMember` →
  `AppointmentDateRows.showEndDate`): shortening is cancelling the tail through
  the scope dialog, extending is a second booking. Letting a day reshape the run
  through `rewrite` would delete and recreate the trailing documents,
  destroying exactly the per-day statuses and photos the split exists to create.
  **Mark-complete never asks scope**; edit, cancel and delete all do, through
  the same `SeriesScopeDialog` with run-flavoured copy — and cancel is the one
  that needed a new write path, `updateAppointmentStatuses` (one batch, one
  shared `seriesOpId`, so a run cancels with ONE push).
  Photos are per day: `images` is a per-document subcollection, so photos
  taken on day 3 attach to day 3's own document. There is no day-1
  redirection.
  **The push fan-out needed NO work**: `diffAppointmentForNotifications`
  already suppresses the `assigned` push for any created document whose
  `seriesId` is not its own id, and day 1's doc id IS the `seriesId`, so a
  5-day run notifies the crew once. A consequence that DOES change: the overdue
  prompt and the tomorrow digest now speak per day, so a 5-day job produces
  five "job tomorrow" lines across five nights instead of one. That is correct
  and is the point, but it is a real increase in message volume.
  **Live Activities start working on long jobs** — `travel_utils.js` starts a
  card only at `dayCountOf(c) <= 1`, and every split day is one day, so each day of a run
  now gets its own Lock Screen card. The guard stays as-is for the wide
  documents time off still writes.
  No migration was needed: prod held ZERO open multi-day jobs on 2026-08-27
  (`functions/scripts/count-multi-day-appointments.js`, read-only — re-run it
  before shipping), and the three wide documents that exist keep rendering
  through the derived branch.
  **`MAX_APPOINTMENT_SPAN_DAYS`/`_MS` in `functions/time_utils.js` hand-mirrors
  `maxAppointmentSpanDays`** (each carries a pointer to the other). Every
  backend sweep that filters on `startTime` must reach at least that far back,
  or a job already under way is invisible to it — that single missing constant
  caused three separate bugs (no overdue prompt for multi-day runs, a digest
  that told an on-site crew "no jobs tomorrow", and a long job dropping out of
  its own travel context).
  **"Is this job still live?" gates on the run's END, not its start, and has
  ONE owner: `hasWorkLeft(record, nowMs)` in `functions/time_utils.js`.**
  Gating on `startTime` meant cancelling or deleting a job mid-run pushed
  NOTHING to the crew, who then turned up the next morning (the Live Activity
  card still ended, so the only signal was a card silently vanishing), and it
  meant `propagateClientEdits` never reached a crew already on site. It was a
  per-module closure in `notification_policy.js` and `client_propagation.js` —
  the same drift shape as `displayStatusAt` and `_who` — so route any new test
  through the shared helper rather than re-deriving `endTime ?? startTime`.
  **Admitting started jobs makes a status filter MANDATORY where it used to be
  free.** A `startTime >= now` query cannot match a job already marked done, so
  terminal jobs were excluded incidentally; any bound that reaches a run
  already under way admits them. `countFutureAssignments`
  (`firebase_appointments_repository.dart`) therefore tests
  `AppointmentStatus.fromRaw(status).isTerminal` explicitly, or a visit
  completed this morning still tells the admin to reassign it before disabling
  the person. Check every bound relaxed this way for the same gap.
  **That query asks `endTime >= now` and nothing else** (2026-08-13), served
  by the `(employeeIds CONTAINS, endTime ASC, startTime ASC)` index — "has
  work left" is a
  test on `endTime`, so the query states it rather than approximating it with
  `startTime >= now - maxAppointmentSpanDays` and re-testing in Dart. The old
  form had **no upper bound**: it read every job this person was assigned to
  from a fortnight ago to the end of time — and the repeat horizon pre-books
  five years out — to render one caption. Keep the status test in Dart: a
  `whereIn` over the open statuses would need a third index field and would
  silently drop any status the allowlist doesn't name, and this caption must
  err towards telling the admin to reassign.
  **The dedicated `(employeeIds CONTAINS, endTime ASC)` index is LIVE, and it
  must stay that way.** It was deleted on 2026-08-28 as a "redundant prefix" of
  the three-field composite above and RESTORED on 2026-08-31 (`3eebcc93`,
  literally *"restore the endTime composite the last audit deleted"*) after the
  deletion broke the travel sweep for two days, invisibly — that path is
  best-effort, so nothing surfaced but the Cloud Functions log. A Firestore
  index prefix is NOT redundant: `__name__` lands at the END of a composite, so
  the three-field index does not serve this two-field query. The three-field
  one is additionally `SPARSE_ALL`, so it omits any document with no
  `startTime`, where this one does not. Do not delete it as a prefix again.
  **It is also `.limit`ed** (`_futureAssignmentScanLimit`, 200, added
  2026-08-13) — `endTime >= now` still has no upper bound of its own, and a
  repeat series pre-books up to `RepeatInterval.maxOccurrences` (120)
  occurrences, so a tech on several series was several hundred documents read
  to render that caption. **Every query in every repository names a ceiling
  AND warns at it** — the invariant has now been broken twice: once by
  `deleteTokensOfKind` (`live_activity_token_repository.dart`) running an
  unbounded subcollection query, and again on 2026-08-19 when the cleanup
  commits replaced every named ceiling in the data layer with an unbounded
  `while (true)` paging loop. Both are restored: `_deviceTokenScanLimit` (50),
  and `_rangeStreamLimit` (3000) / `_userStreamLimit` (1000) /
  `_presenceStreamLimit` (1000) / `_historySearchScanLimit` (5000) /
  `_clientScanLimit` (5000) / `_clientHistoryScanLimit` (1000). Paging and a
  ceiling are not alternatives — page so one snapshot can't truncate the
  answer, cap so the loop can't walk the collection, warn so a truncation is
  visible in Crashlytics. A `.limit` rather than a horizon bound
  deliberately: with `endTime` the only inequality, Firestore returns these
  `endTime` ASC, so the cap keeps the SOONEST-ending jobs — the ones actually
  needing reassignment — and the number stays EXACT below the cap, so
  `employees_disableReassignCaption` needs no rewording. Bounding the horizon
  instead ("12 jobs in the next 90 days") would read less again but changes
  what the sentence claims; that is a product call, not a performance one. It
  warns at the cap for the same reason the range streams do: understating this
  caption tells an admin they have less to reassign than they do.
  **The mirrors are day-scoped too** (Plan 2, 2026-08-10): the widget payload
  (Dart `widget_sync_service.dart` + `functions/widget_payload_utils.js`), the
  Siri snapshot (**schema v3**) and the push date line all fan a run across the
  days it works. Each carries THAT day's window, never the run's first morning,
  and a multi-day run gets a `dayIndex`/`dayCount` counter that is **omitted**
  for a single-day job so an older decoder still parses.
  **`functions/day_slice_utils.js` is a HAND-MIRROR of
  `appointment_day_slice.dart`** — its jest cases deliberately reuse the Dart
  tests' worked examples (Aug 1–5 day job; Aug 1 22:00 → Aug 4 06:00 = 3 nights
  ending Aug 3), so a divergence fails a test instead of shipping. Change both
  together. Two things it does NOT copy: it re-exports
  `MAX_APPOINTMENT_SPAN_DAYS` from `time_utils.js` rather than restating a
  third copy, and it rebuilds a window as a **wall-clock** time rather than
  midnight-plus-elapsed-minutes, since the latter lands a 9:00 window at 10:00
  on the two DST shift days. It also treats a record with **no `endTime`** as a
  single-day job (the `hasWorkLeft` fallback) — the Dart model never emits one,
  so only the server meets legacy and console-written docs, and reading the
  absent end as "equal times" would make it overnight, count the run backwards
  to zero days, and drop the job out of every mirror silently.
  **The travel sweep and the overdue sweep need NO day-scoping**: the first
  gates on `startTime > now`, so it already fires on day 1 only (days 2+ have
  no separate departure time and the crew is already on site), and the second
  gates on the run's real `endTime`. **Live Activities deliberately skip
  multi-day jobs** — a four-day Lock Screen countdown is worse than no card.
  That skip is the `dayCountOf(c) <= 1` START condition in `resolveReminderForAssignee`
  (a card is begun only for a single-day window; there is no `> 1` predicate)
  (`functions/travel_utils.js`), and it was BUILT 2026-08-11: this bullet
  asserted it as fact from 2026-08-10 while no such gate existed anywhere, so
  the card really did carry the run's `endTime` into
  `Text(timerInterval:countsDown:)`. `docs/archive/2026-08-02-multi-day-appointments.md`
  §10 deferred it, and the doc was right. Only the CARD is withheld — the
  `leaveNow` push still goes out on day 1, which is the only day with a
  departure time.
  **The 14-day cap is applied by ONE clamp, `_clampedDayCount`, and every
  day-scoping answer routes through it** (2026-08-08): `sliceFor`/`runsOn`,
  `runsInRange`, `expandToDays` and `dailyWindowsOverlap`. The rules bound
  stops a CLIENT writing past the cap, but the console and the Admin SDK
  bypass rules entirely, so a doc CAN still exceed it, and
  when the owners disagreed the calendar rendered 14 slices while every
  `runsOn` consumer counted the full corrupt length: a drawer badge reading
  "1 job today" every day for a year, a card counter reading "Day 400 of 900".
  `AppointmentFormValidator` is the one deliberate exception — it reads the
  RAW count, because it is the caller that has to see an out-of-range value in
  order to refuse it.
  **A form's run length has one owner too, `runLengthDays`** (beside
  `appointmentSpan`): the `end − start + 1` rule was hand-copied into both form
  bodies, which even shared the same five-line comment.
- **A PERSONAL save skips the Save-time busy prompt entirely** (2026-08-24).
  Both controllers gate the check on `!isPersonal`, and the time-off clash
  alert handles that clash AFTER the write instead. This is a change to
  EXISTING behaviour, not just new surface: booking a day off over Marc's jobs
  used to pop "Schedule Conflict — Marc is already booked / Book anyway", and
  adding the alert on top gave two dialogs about the same clash back to back.
  The alert is strictly more useful — it names the jobs and offers a swap on
  each, where the old prompt only names the person. The prompt is UNCHANGED for
  ordinary client jobs. Pinned on both controllers by a test that a personal
  save no longer returns the busy outcome.
- **The time-off clash alert is ADVISORY and always AFTER the save**
  (`calendar/widgets/dialogs/personal_block_clash_dialog.dart`, designed in
  `docs/archive/2026-08-24-timeoff-clash-alert.md`). Closing it leaves the block
  saved and the jobs untouched — time off is a fact about a person and the
  schedule does not get to veto it — so its dismiss button is **"Leave them",
  never "Cancel"**, which would read as cancelling the time off. Each swap
  writes IMMEDIATELY, so it survives closing the dialog; Undo is per row and
  lives only as long as the dialog, after which the swap is an ordinary edit.
  Three rules that would be bugs the other way: a swap hits **that occurrence
  only**, never the series (a weekly job's Wednesday slot is what clashes; the
  person is not off every Wednesday, so this must not route through
  `appointment_series_editor.dart`); a swap **replaces, never removes**
  (`appointment_form_validator.dart` rejects an empty crew, so taking the only
  assignee off would write a state the form itself forbids); and each person's
  swap list excludes everyone **booked off alongside them**, who are no more
  available than they are. The candidate scan awaits the roster STREAM rather
  than reading a lazily-started provider's current value, and it fails CLOSED
  to the stuck row — offering a name the scan never checked is the failure this
  dialog exists to undo.
  **The dialog tracks each clashing job's LIVE record keyed by DOC ID, never
  per row and never the dialog-open snapshot.** One job appears under every
  blocked person on it (a team day off), and a swap rewrites the whole crew —
  so a second swap built from the opening snapshot dropped the first
  replacement AND put the person who is off back on the job, which is the
  exact outcome this dialog exists to undo. Keyed per ROW it has the same
  hole, since two rows are two keys over one document. Pinned by "a SECOND
  swap on the same job builds on the first".
  **A swap re-serializes the WHOLE record, so it must normalize the status
  through `AppointmentStatus.storedRaw`** like every other such write — a
  legacy `confirmed`/unknown value would otherwise be written back verbatim
  and rejected by the rules as an opaque `permission-denied` on an
  ordinary-looking swap. The swap itself is the pure `replaceAssignee`
  (`calendar/domain/assignee_resolver.dart`, moved out of the dialog
  2026-09-07): it has to agree with `mergeRetainedAssignees`,
  `assigneeNameAt` and `assigneeOfferState` about the positional pairing, so
  it lives beside them and is unit-tested there — the rule above was a comment
  on a private function no test could reach.
- **The conflict check runs SERVER-SIDE now** (2026-09-04), through the
  `findAppointmentConflicts` callable — the client query was capped at 1000 docs
  per 30-id chunk and silently reported no clash past it. The server applies the
  SAME rule, and that is not free: `dailyWindowsOverlap` in
  `functions/day_slice_utils.js` is a hand-mirror of the Dart original, added
  because the callable shipped with a raw instant test and immediately
  reproduced the phantom clash below — a 9-5 run across a week blocking a 7 pm
  job inside it. Pinned by `functions/__tests__/indexed_search_conflicts.test.js`
  with the same worked examples; change either side and the other in one commit.
  The server also keeps the fail-closed half (a doc whose stored times don't
  parse clashes unconditionally) and narrows a non-admin caller's `employeeIds`
  to their own doc id, so a technician cannot probe the roster's calendar.
  The Dart path below is now the injected-`FirebaseFunctions`-absent fallback,
  which in practice is tests only — it still describes the rule, and both sides
  must move together.
- **Mark-complete is UNDOABLE, through the `restoreAppointmentStatus`
  callable** (2026-09-04). The success notice carries an Undo for as long as it
  is on screen; it restores the status the job held before, captured at the
  call site through `AppointmentStatus.storedRaw` like every other such write.
  **It is a callable rather than a rules grant on purpose**: reopening a closed
  job is the one status move the employee `allow update` disjuncts deliberately
  exclude (they all require the current status NOT be terminal), and widening
  them would let an assignee reopen anything they are on, at any age. The
  callable re-checks that the doc is currently COMPLETED, that the caller is an
  admin or assigned, and that the target is `pending`/`in_progress` — never a
  terminal status — and clears `completedAt`, which is server-owned, so an undo
  cannot leave a finish time on an open job.
- **`findClashingAppointments` is the ONE owner of "what stands in the way",
  and the clash rule under it is the pure `clashingAppointments`**
  (`calendar/domain/assignee_availability.dart`). It answers with the clashing
  RECORDS rather than the busy people, and **`findBusyEmployees` is now
  expressed in terms of it** — same query, same rule, the busy people being
  just the union of the results' `employeeIds`. It briefly was not: the query
  was shared (`_conflictSnapshots`) while the RULE stayed hand-spelled in
  `findBusyEmployees`' own doc loop, which is the two-owner shape this bullet
  exists to forbid. The picker reduces a live stream through the same pure
  rule; if the surfaces ever disagree, the bug is that the rule lives in two
  places.
  **A record whose stored times DON'T PARSE clashes unconditionally, and that
  fail-closed rule survives the collapse only because it is passed IN.**
  `AppointmentRecord` substitutes a placeholder instant for an unparseable
  `startTime`/`endTime`, so by the time the pure rule runs, "no usable times"
  and "a real window that happens not to overlap" are indistinguishable — and
  the placeholder silently fails the overlap, dropping the row. Only the
  repository sees the raw map, so it collects those doc ids and hands them to
  `clashingAppointments` as `windowUnknownIds`; every other test still applies
  to them. A legacy or console-written row with no usable times must never
  quietly disappear from a booking check. Pinned by "a doc with unparseable
  times is kept, not silently dropped".
  **`clientJobsOnly` is the alert's flag and the picker must never pass it.**
  It drops personal blocks, because "swap Marc for Nadia" on Marc's own dentist
  appointment is nonsense — that block belongs to him. The consequence to
  accept: a personal block overlapping only ANOTHER personal block raises no
  alert at all, which is correct. The picker leaves it off, since booking time
  off is exactly how a person is made to read as unavailable.
- **`findBusyEmployees` must exclude the appointment under edit.** Pass
  `excludeAppointmentId` from any edit-flow conflict check or the job collides
  with itself and reports every one of its own assignees as busy. The exclusion
  is by **doc id, not by series**, so a genuine clash with a sibling occurrence
  still surfaces. A clash returns the sealed `EventDetailsBusyEmployees` (not an
  error) and **must clear `isSaving`** before returning, or Save stays stuck
  once the dialog is dismissed.

- **An ASSIGNEE may record their own work: crew notes and photos** (2026-09-01).
  Until then a technician could read a job and tap "Mark as complete", and
  nothing else — the photo pipeline, the offline upload queue and the
  magic-byte validation all existed and were wired to the admin-only edit form,
  so for a trade where the field record IS the billable artifact it travelled
  by phone call. Three grants, each deliberately narrow:
  **`fieldNotes` is its OWN `allow update` disjunct**, never a widened
  `hasOnly` on the mark-done branch — that branch is the most
  security-sensitive write in the app and its exact key set is what makes it
  reasonable about; one write doing both puts every guarantee on it back in
  play. It is `fieldNotes`, never `notes`: the dispatcher's brief is written at
  booking and an assignee must not overwrite it, so two fields is what makes
  "the crew may add, never edit the brief" a rules-level fact. It carries no
  status gate (a note is often the explanation for a job that went wrong), and
  **its length cap is conditional on the field being PRESENT** — `hasOnly`
  admits a SUBSET, and an assignee adding a photo touches the parent with an
  `updatedAt`-only diff, which a flat cap refuses, so the crew could add the
  photo ROW and never the photo.
  **`appointments/{id}/images` allows CREATE to an assignee**, with update and
  delete still admin-only: adding to the record is additive, removing from it
  is not, and a field record must not be quietly deletable by the person whose
  work it documents. `storage.rules` grants the same assignee the BYTES at the
  same path — the two move together, since a row create with no object write
  leaves a photo pointing at nothing. What stops a compromised employee session
  pointing a row at another job's object is the `storagePath` path constraint,
  not the role.
  The UI half is `DetailsFieldRecordView`, rendered only for a NON-ADMIN
  ASSIGNEE (`activeUserIdentityProvider`), which is exactly the set those rules
  admit — never `!showActions`, which the client job-history surface also
  passes and which is an admin reading somebody else's job.
  **Crew notes moved to a subcollection on 2026-09-06** (the parent
  `fieldNotes` disjunct above is now a LEGACY write path, kept for older
  builds — read on). `appointments/{id}/fieldNotes/{noteId}` —
  `{text, authorId, authorName, createdAt}` — mirrors the images
  subcollection's additive posture: read is admin **or** assignee; create is
  admin or assignee **and** `authorId == myDocId()`, so a note can never be
  filed under a colleague's name; **update and delete are ADMIN-ONLY**, same
  reasoning as images — a field record must not be quietly editable by the
  person whose work it documents. `'fieldNotes'` is a hand-mirrored literal
  between `AppointmentFieldNotesStore.notesSubcollection`
  (`calendar/data/appointment_field_notes_store.dart`) and the
  `match /fieldNotes/{noteId}` block in `firestore.rules` — a divergence there
  is a silent `permission-denied`, the same trap `IMAGES_SUBCOLLECTION` guards
  against. **A note write never touches the parent document** — appending one
  goes through `AppointmentFieldNotesStore.append`, which never calls the
  appointments collection's `update()` — so this added NO new parent
  `allow update` disjunct: `appointment_employee_update_rules_test.dart` still
  pins that count at three (mark-done, the legacy `fieldNotes` field, Start
  job), and `field_notes_rules_test.dart` re-asserts the same count and says
  why it did not move.
  **The parent `fieldNotes` string, its `allow update` disjunct and
  `updateFieldNotes` all SURVIVE deliberately** — older builds in the fleet
  still write that field, and there was no backfill, so removing the disjunct
  would break them. The legacy string still renders, unattributed, at the top
  of `DetailsFieldNotesView`'s thread when non-empty; nothing writes it any
  more. **`updateFieldNotes` on `FirebaseAppointmentsRepository` has no
  production caller as of 2026-09-06** — its only reference is
  `firebase_appointments_repository_invalidation_test.dart`. It is KEPT
  DELIBERATELY as an emergency repair path for a doc some older build wrote
  badly; do not delete it as dead code on a later simplify pass without first
  checking whether any build in the fleet still calls it. That is a question
  about the Dart method; the disjunct's own survival is a question about the
  server contract, and the two happen to share an answer for different
  reasons.
  **Who sees the thread versus who may post to it are two different sets.**
  `DetailsFieldNotesView` renders read-only for ANYONE who may read the job —
  admin and assignees both, the same set the rules admit — which is the bug
  this shipped to fix: an admin previously could not see crew notes at all.
  The compose box (`DetailsFieldRecordView`) stays crew-only, gated by
  `_canRecordFieldWork` in `details_view_body.dart`.
- **"Start job" must NOT dismiss the detail sheet.** Mark-done and cancel close
  because the job is finished; Start is mid-job, and that sheet is where the
  crew records it — the status chips, the notes box and the photo picker are
  all on it, and so is the "Started …" line the tap just created. It shares
  `_onStatusOutcome` with the closing actions and passes `closeOnSuccess:
  false`; pinned by `details_view_body_actions_test.dart`.
- **The job time record has ONE owner, the SERVER** (2026-09-01, the audit's
  "no `startedAt`/`completedAt` anywhere"). `lifecycleStamps`
  (`functions/notification_policy.js`) decides `startedAt`/`completedAt` on
  the status TRANSITION only (into `in_progress`; into done, never cancelled;
  never a personal block or time off) and `stampLifecycle`
  (`notification_utils.js`, run by `handleAppointmentWrite` above its events
  early-return) writes them with an Admin-SDK `update`. So every client status
  path — an assignee's Start job or mark-done, the admin edit form's picker, a
  series propagate — lands the same stamp, and NO client is allowed to write
  one. The cost is one extra write and one silent trigger re-fire per
  transition; `notification_lifecycle.test.js` proves the re-fire produces no
  stamp, no event and no completion push. Don't move the stamp client-side to
  save the write: that either widens the mark-done rules branch or leaves the
  admin picker path unstamped.
  **`toMap()` OMITS `startedAt` and `completedAt`.** Every path that
  re-serializes a record writes through a
  merging `update()`/`txn.update()`, so the stored values survive an admin
  edit, while `addAppointments` and `rewriteSeries` copies are NEW documents
  that must not inherit another job's record. `DetailsTimeRecordRow` renders
  the pair (gated on the job not being cancelled) and `DetailsActionBar` offers
  **Start job** (`onStart`, above Mark-as-complete) on an open job whose stored
  status is not yet `in_progress`, to admins and to a non-admin assignee.
  **One more assignee `allow update` disjunct, and it does NOT widen
  mark-done**: Start job (`hasOnly(['status','updatedAt'])`,
  `status == 'in_progress'`, refused when the stored status is already
  `in_progress` or closed, `updatedAt` pinned). The text tests split on the
  literal `|| (isAssignedEmployee(resource.data)` and the mark-done helper keys
  on `== 'done'`, so keep both spellings; `appointment_employee_update_rules_test.dart`
  pins the disjunct COUNT at three (mark-done, field notes, Start job), so a
  new one is a deliberate edit there rather than a silent widening.
  **A crew "On my way" / "Running late" signal was built on 2026-09-01 and
  REMOVED on 2026-09-03 (owner call), across rules, Dart, `functions/` and both
  ARBs** — don't reintroduce `crewStatus`/`crewStatusAt`/`crewStatusBy`, the
  fourth assignee disjunct, or the two admin push kinds from an older copy of
  this file.
  **Push back (admin quick action) withholds any offset that crosses
  midnight** — `pushBackOptionsFor` (`domain/policies/push_back_options.dart`)
  keeps +15/+30/+60/+120 only while the shifted start stays on the day
  `runsOn` puts it. `delayAppointment` is a single-document write (never the
  series), runs the same busy check as Save, and the crew's "rescheduled" push
  comes from the existing differ on the `startTime` change.
- **Editing an appointment must preserve assignees not in the active picker.**
  The employee picker never shows a disabled/removed person, so such an assignee
  can't be deselected — saving must re-append original `employeeIds` not in the
  active set, or that staff is silently unassigned (which also changes who can
  see the visit). **What the picker DOES offer has one owner,
  `offerableAssignees` (same file as the merge), and it narrows the ACTIVE list
  rather than unioning onto a pre-filtered one** — active crew, plus anyone
  active who is already on the job but no longer offerable by title (a
  dispatcher assigned before that rule existed, so it can be taken off). It
  keys on the appointment's STORED `employeeIds`, never the live selection —
  keyed on the selection, deselecting that dispatcher removed their own chip on
  the next rebuild, so the toggle was one-way and an accidental tap could only
  be undone by abandoning the edit. The
  distinction is the trap: a union of "assignable + already selected" also
  re-offers a DISABLED assignee, whose chip then deselects and is silently
  put back by the merge below on every save. Narrowing an active-only list
  cannot express that, which is why the rule lives beside the merge it has to
  agree with rather than inside `EmployeePicker`. The merge itself is the pure, tested `mergeRetainedAssignees`
  (`calendar/domain/assignee_resolver.dart`) — route the retain logic through it.
  Resolve the active set through the ONE owner, `_resolveActiveEmployees`
  (`event_details_controller.dart`), which awaits `watchEmployees().first` —
  never a cached provider value, and never a `.value ?? []` read. The await is
  the point: a cold or empty stream value at save time makes every original
  assignee look inactive, so all of them are retained and a real deselection is
  silently undone. (This bullet previously described a two-tier "cached value
  falling back to a fresh read" that the code does not have and should not
  grow — the single awaited read is both simpler and strictly safer.)
  **`employeeIds` and `employeeNames` are paired POSITIONALLY, and the bounds
  check has one owner: `assigneeNameAt(names, i)`** (same file, returns null for
  "no name here"). It was re-spelled at five sites; the differing missing-name
  fallbacks around it are legitimately per-surface (the day route shows the id,
  the history filter shows nothing), so the helper owns only the LOOKUP and each
  caller keeps its own substitute. The edit-sheet copy is the dangerous one — a
  blank name there flows into `mergeRetainedAssignees` and is written back.
- **The picker DIMS whoever can't take the job on the chosen date, and the
  already-assigned test WINS over it.** `assigneeOfferState`
  (`calendar/domain/assignee_resolver.dart`, beside the two rules above because
  all three must agree) returns `free` / `unavailable` / `onTheJob`; only
  `unavailable` dims, and it is dimmed AND untappable, which is precisely why
  someone already on the job must never be. A chip that can't be tapped can't
  be taken off, and — worse — an assignee who is active but merely un-offered
  is NOT retained by `mergeRetainedAssignees`, so they'd be silently
  unassigned. The "on the job" set is the live selection **union the
  appointment's STORED `employeeIds`**: keyed on the selection alone,
  deselecting an unavailable stored assignee dims their own chip on the next
  rebuild and the toggle is one-way. Same trap as `offerableAssignees`.
  **ANY clash dims, not just a day off** (owner call, 2026-08-24), and the
  accepted cost is that deliberate double-booking is no longer reachable from
  the picker — the Save-time prompt stays as a backstop for races but will
  rarely fire. If putting two people on one big job turns out to matter, keep
  BOOKED chips tappable with a warning look and dim only time off.
  **Availability is date-DERIVED, live where it can be, one-shot where it
  can't.** `assigneeAvailabilityProvider` reduces the range the calendar
  ALREADY holds open (`openCalendarRangeProvider`, published by
  `MainCalendarScreen` and admin-only, since that stream constrains
  `startTime` alone and the rules reject a technician's query) and falls back
  to `findClashingAppointments` when the span falls outside it. The fallback is
  not optional: without it a date past the open range makes every clash
  invisible and the picker silently reports everyone as free, which is worse
  than not dimming at all. Forking a listener keyed on a span-derived range is
  what `forWeekBucketOf` and `forMirrors` carry long comments against.
  **An undetermined span answers nothing** — a date with no times could still
  become an 8 pm job, so `watchAssigneeAvailability`
  (`calendar/utils/assignee_availability_scope.dart`) offers everyone until the
  span is real, which covers "no date picked yet" too.
  **A PERSONAL block dims NOBODY, and that carve-out is load-bearing.** Dimming
  means untappable, and the person a day off is FOR is the one most likely to
  have jobs that day — so dimming made their absence unbookable, and made the
  clash alert that exists to clean up afterwards unreachable. It is the same
  carve-out, for the same reason, as both controllers skipping the Save-time
  busy prompt when `isPersonal`; both halves take `isPersonal` and must keep
  agreeing. A clash is never a reason to refuse time off — it is what the
  alert reports after the write.
- **Job templates are display-only quick-fill, NEVER stored.** `JobTemplate`
  (`calendar/domain/models/job_template.dart`) backs the one-tap chips on the
  **add** flow only (`onApplyTemplate`, null on edit); picking one just seeds the
  title text and the job LENGTH. The appointment still
  saves with `status: 'pending'` and whatever the admin edits afterwards; there
  is no template field on the record. Add new types to the enum + a
  `jobTemplateLabel` case + EN/FR ARB keys (mirrors `statusLabel`).
  **A seeded length goes through `AddEventController.setDurationMinutes`, never
  through the widget** (2026-09-02): the chip and a book-again both hand it a
  number of minutes, it survives until a start is picked LATER (`durationMinutes`
  on the state), and it re-owns the end — `endTimeWasPickedManually: false` — so
  the end keeps following the start afterwards. `JobTemplate.endMinutesOfDay` was
  its own third spelling of the clamp and is gone; the arithmetic owner is
  `AppointmentDraftDefaults.endTimeFor`, whose only difference from
  `defaultEndTime` is that it CLAMPS at 23:59 where the plain default WRAPS past
  midnight. Both behaviours are pinned; don't collapse them without deciding
  which one a bare late start should get.
- **"Book again" carries the WHO and the WHAT, never the WHEN** (2026-09-02).
  `AppointmentPrefill` (`calendar/domain/models/appointment_prefill.dart`) is
  what the add sheet opens pre-filled with, for both the book-a-job flows (a
  bare client) and the repeat callback (`AppointmentPrefill.bookAgain`). The
  contract is the pure factory and it is pinned from BOTH sides — what carries
  over (client, address, title, brief, materials, crew, length) and what stays
  behind (date and times, status, photos, field notes, the time record, the crew
  signal, series and run fields, ids and timestamps) — so a field added to
  `AppointmentRecord` that leaks into a duplicate fails a test. The draft saves
  as an ordinary `pending` appointment; nothing about it is a copy operation.
  Two gates are load-bearing: the crew is re-resolved against the LIVE roster so
  a disabled person can't be put on a new job, and the action is offered only
  when `clientId` is non-empty — not merely when the job is not personal —
  because the `placeholderClient` fallback composes an EMPTY `ClientRecord` on a
  row with no client, and `clientRequired` only checks for non-null.
- **Whether a job used its own address has ONE owner, `usesCustomAddress`**
  (`calendar/domain/policies/custom_address_policy.dart`, 2026-09-02). The edit
  form's address pill and the book-again prefill both ask it, and they must not
  be able to disagree. It compares against `fullAddress` and canonicalises both
  sides; a `noFixedAddress` client is always custom. See the comment there for
  why the raw `address` field is the wrong side of the comparison.
- **The dashboard's window is SPLIT: one live listener, one `.get()`.**
  `DashboardAggregator.liveRangeAround` (this ISO week through next Monday /
  the 3-day pending horizon) is watched; `historyRangeAround` (the seven
  settled weeks behind it) is read once through
  `AppointmentsRepository.fetchInRange`. Held as one range it was a **70-day**
  business-wide live listener capped at `_rangeStreamLimit` (3000), so above ~42
  jobs/day the 8-week trends, busiest-weekday and Attention list were computed
  over a silent PREFIX. The two results **must be merged by doc id**
  (`DashboardAggregator.mergeById`, live wins) and never concatenated — each
  query reaches back to its own `fetchStart`, so they overlap by a fortnight.
  Adding a reducer that needs older data means widening the HISTORY half, not
  the live one.
- **A technician's History is the same terminal archive narrowed by
  `employeeIds`** (2026-09-01, the audit's "technician has no search").
  `_historyQuery(employeeId)` (`firebase_appointments_repository.dart`) is the
  ONE owner of that narrowing for both the paged list and the search scan
  window; served by the `(employeeIds CONTAINS, status ASC, startTime DESC)`
  composite, which must be deployed and READY before an app build that ships
  it. The repository keeps one scan window PER SCOPE (`_scanWindows`, `''` =
  admin); `_patchWindow` patches every window, and a scoped window REMOVES a
  doc whose `employeeIds` stops naming the scope, the same way the
  terminal-status rule removes a reopened one. The search cache key carries
  the scope. `HistorySearchKey` (query + employeeId) is the provider family
  key. No rules change was needed: the list is
  constrained by `arrayContains` on the caller's own doc id, the same shape
  `watchForEmployeeInRange` already relies on. `runAddClientFlow`
  (`clients/widgets/sheets/add_client_flow.dart`) is the one add-client →
  book-a-job flow, called by the Clients FAB and the list's empty state.
  **History became admin-only on 2026-09-06** (owner call) — an employee's
  copy carried no filter control of any kind, and a technician still reaches a
  finished job through the calendar's closed-job sink, so the drawer row and
  `AppointmentHistoryView`'s widget-level `scopeEmployeeId` are gone. The
  repository-layer scoping above deliberately SURVIVES: `_historyQuery`'s
  `employeeId` narrowing, the per-scope scan windows and the server-side
  `historyScope` guard plus its `emp:<id>:` search-token scopes
  (`functions/indexed_search.js`, `functions/search_tokens.js`) all mirror a
  DEPLOYED contract that older shipped builds still call — removing any of
  that would be a breaking backend change, not tidying up dead code.
