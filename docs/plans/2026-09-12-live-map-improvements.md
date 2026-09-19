# Live staff map improvements — design

**Status: BUILT 2026-09-13 on `dev` (uncommitted at time of writing), NOT
SHIPPED.** No backend deploy (the optional rules type check was skipped).
Left: the device-only checks in §7, republishing `docs/legal/privacy-policy.html`
to `es-pro-legal` once the build ships (the rest of that file went live
2026-09-14, so the three two-hour location passages are the only difference),
re-checking the crew-map paragraph of `docs/legal/accessibility.html` (written
2026-09-14 against 1.61's staff list, which this build replaces with the team
sheet) and republishing it, and flipping the Apple tester's Test account switch once the
build ships. Deviations from this design are recorded at the end of this file.

Mockup (chosen design, private artifact):
https://claude.ai/code/artifact/3033bea3-5790-4966-9e8f-a3ce99339655

**Picked: Option B's map (peek team sheet) with Option C's ask step
(full-screen page).** Option A (floating card + separate team sheet) and
Option B's inline calendar card were not taken.

A second, independent request from the same session — a month-end
notification to the admin with an overdue-appointment review screen — gets its
own design doc. It is not part of this one.

---

## Why

- The Apple App Review tester account shows up on the admin live map, and on
  every team list, as if it were staff.
- A pin never goes away: `LiveMapAggregator.join` filters on missing/inactive
  users and never on freshness, so yesterday's location looks the same as a
  live one.
- Opening the app does not refresh a person's pin. The position stream has a
  250 m `distanceFilter`, so someone who opens the app where they last closed
  it produces no fix, and the 10-minute heartbeat is the next write.
- `locationSharingEnabled` defaults OFF (on purpose, 2026-09-04), and nothing
  in the app tells an employee the map exists. Most staff are simply absent,
  and the admin cannot tell why.
- The map's controls, info card and roster still use pre-"fresh" `Card` /
  `ListTile` / FAB styling.

## Decisions made in the session

| Question | Answer |
|---|---|
| Where is a test account hidden? | **Everywhere** a teammate is listed or counted, not only the map. |
| How is an account marked? | **Admin toggle** on the edit-person sheet, not a console-only flag. |
| When does an old pin disappear? | **After 2 hours** with no update. |
| "Update location while in the app" means | **Fresh fix on app open**, **map refreshes live**, and **ask staff to turn sharing on**. Not "update more often while open". |
| Extra ideas taken | **A list of who is missing and why.** Not taken: the person's current job on their card, a Call button. |
| Map layout | **Option B**, the peek team sheet. |
| How staff are asked | **Option C**, a full-screen page, once. |

---

## 1. Test accounts

- New field **`isTestAccount`** (bool, absent = false) on `users/{docId}`,
  read into `EmployeeRecord.isTestAccount`.
- **Admin-only.** It is NOT added to `kSelfServiceUserFields` or to
  `isAvailabilityOnlyChange()`'s `hasOnly`, so a person cannot un-hide
  themselves. **No rules change is required** (verified 2026-09-12):
  `isValidUserData` is a per-key optional check, not a `hasOnly`, so an admin
  write carrying a new key already passes. Adding
  `(!('isTestAccount' in d.keys()) || d.isTestAccount is bool)` is optional
  type hardening, and it would be the only reason to deploy rules. It goes on the
  admin `updateEmployee` field allowlist, and `EmployeeRecord.toMap()`
  round-trips it like the other editable fields.
- **What prod says about the tester** (read 2026-09-12,
  `users/AIMcaSKenB2eyYXCTEp4`): it is an **active ADMIN** with job title
  **dispatcher**, it has **no `fcmTokens`**, and it has **no
  `locationSharingEnabled` field**. Its `presence/location` was last updated
  **2026-09-03** — before the opt-in gate shipped — so the pin on the map is a
  9-day-old leftover that nothing will ever refresh or delete, and the 2-hour
  cutoff (§2) removes it on its own. Being a dispatcher, it is **already**
  excluded from the assignee pickers and the dashboard workload
  (`JobTitle.isAssignable`). The flag's real remaining job is the Team roster,
  the map if a reviewer turns sharing on, and admin fan-outs such as the
  month-end push. Because the tester is an admin, the admin branch lets it
  clear its own flag; accepted.
- **UI:** a switch on `edit_person_sheet.dart` — "Test account", with a caption
  saying it hides the person from the map, the pickers and team counts.
- **Hidden from:** the live map and its sheet; the assignee pickers (via
  `assignableEmployeesProvider`, which already owns "who can be put on a
  job"); the calendar crew filter; the dashboard's per-person workload,
  capacity and availability flags; the time-off clash swap candidates; the
  Team roster's main list.
- **The Team roster keeps a collapsed "Test accounts" section at the bottom.**
  Without it an admin can never reach the account to turn the switch back off.
- **NOT hidden:** the colour and name lookup maps (jobs already assigned to
  the tester must still render their crew), History, the tester's own session,
  and every server-side push. The tester still receives notifications.
- The edit form's `offerableAssignees` rule already keeps anyone STORED on a
  job selectable, so hiding the tester from the picker cannot strand them on
  an existing job.
- **Planning must enumerate every consumer** of `employeesStreamProvider`,
  `assignableEmployeesProvider` and `allUsersStreamProvider` and classify each
  one as a list (filter) or a lookup (don't). That grep is the risky part of
  this change. A missed list leaves the tester visible; filtering a lookup
  blanks names on real jobs.

## 2. Location freshness

- **Fresh fix on open.** `PresenceSyncController`'s existing
  `AppLifecycleListener.onResume` gains a one-shot
  `Geolocator.getCurrentPosition` (medium accuracy) when tracking is already
  running, fed through the same `_uploadThrottled` path. The existing 2-minute
  `minPresenceUploadGap` still applies, so rapidly switching apps cannot spam
  writes; any resume after more than 2 minutes away writes. A cold start
  already writes on the stream's first fix.
- **Pins hide after 2 hours.** New `presenceHiddenAfter = Duration(hours: 2)`
  beside `presenceStaleAfter` in `live_map_aggregator.dart`. Dart-only — the
  server's `PRESENCE_STALE_MINUTES` (25) is a different question (is a fix
  fresh enough to route from) and does not change.
- **Between 25 minutes and 2 hours** a person stays on the map with the
  existing "offline, last seen" text. The pin is never dimmed (standing rule);
  only the avatar in the list fades, as the roster row already does.
- **The cutoff re-evaluates on the existing 30 s `liveMapTickProvider`**, so a
  pin crossing 2 hours drops off without reopening the screen. The points
  provider does not watch the tick today, so the filter must sit where it
  does.

## 3. The map (Option B)

- **The team sheet replaces the roster FAB.** A draggable sheet rests at about
  48 % of the screen, drags up to about 86 %, and down for more map.
  `showStaffRosterSheet` and the `liveMapRosterFab` hero tag go away, leaving
  `liveMapRecenterFab`'s replacement as the only floating control besides the
  toggles. The `heroTag` registry in `frontend.md` loses both FAB entries once
  they are ghost controls.
- **At rest:** header "Team" with a mono count line ("4 on the map · 3 not on
  it"), then the ON THE MAP section, nearest first. The self row leads and
  carries the "You" pill — existing `sortedByProximity`.
- **Pin or row tapped:** that person moves to the top of the sheet — avatar,
  name, mono freshness + distance line, reverse-geocoded address, an accent
  ghost pill "Open in Maps", and a close ghost tile that returns the sheet to
  rest. The rest continue under "Also nearby". The camera eases to them, as
  `_focusOn` does today. `StaffInfoCard`'s content moves into the sheet; the
  floating card goes.
- **Dragged up:** three counted sections — ON THE MAP, NOT SEEN IN 2 H (fix
  older than `presenceHiddenAfter`), LOCATION SHARING OFF (active, non-test
  team members with `locationSharingEnabled` false and no fix). Rows in the
  last two sections are not tappable, since there is no pin to open. Footer:
  "They can turn it on in Settings › Location sharing."
- Grouping is a pure function beside `sortedByProximity` on
  `LiveMapAggregator`, taking the users list, the fixes and `now`, so it
  unit-tests without plugins.
- **Controls:** traffic and satellite as `GhostControl.icon` tiles top-right
  on the map, `GhostTone.active` when on. Recenter is a ghost tile riding the
  sheet's top edge. Ghost tiles over a map need `cardStyle.pillShadow`; the
  plain ghost tone has no shadow.
- **Tour:** `TourStepId.liveMapRoster` KEEPS its member name (it is a storage
  key — renaming replays or orphans the tour) and its target moves from the
  FAB to the sheet handle; its copy is reworded to describe the sheet.
  `liveMapRecenter` retargets to the new tile.

## 4. Asking staff to share (Option C)

- **Full-screen page**, pushed over the calendar. It shows a map thumbnail with
  the person's own pin in their crew colour, the headline "Be on the team
  map", one sentence of why, three true statements (only while the app is
  open; only the latest spot, never a trail; off anytime in Settings), and two
  buttons: **Turn on** (primary) and **Not now**. No close icon.
- **Shown when all hold:** the signed-in account is active, not a test
  account, has `locationSharingEnabled == false`, has not been asked on this
  device, and no feature tour is running or pending on the calendar. It shows
  once, the first time the calendar is reached after the update.
- **Remembered per device, per uid** (SharedPreferences, keyed on the uid so a
  shared phone asks each person). **Not now is final** — never re-asked; the
  Settings row remains the way back.
- **Turn on** calls the existing `saveLocationSharing` (offline guard,
  `ME-SAVE` tag, notice), which runs `PresenceSyncController.sync()`, which
  issues the single iOS permission prompt if iOS has never been asked. If the
  person declines the OS prompt, sharing stays saved as ON and nothing uploads
  until they grant it in iOS Settings — the existing silent-degrade path.
- **This is the "explicit in-context step" `notifications.md` asks for.** It
  never runs from a sync path, and it is optional, so it does not reopen
  guideline 2.5.4. Still: review the page copy against that rejection before
  submission.

## 5. New look

- Map toggles, recenter: `GhostControl`, replacing the `Card` + `IconButton`
  stack in `live_map_overlays.dart` and the `FloatingActionButton.small`s.
- Sheet rows: plain rows on `palette.sheetRow` / sheet background with
  `outlineVariant` dividers and 48 pt minimum — never `ListTile` inside a
  decorated panel (standing rule). The "You" badge becomes a status pill, not
  `secondaryContainer`.
- Section labels are mono uppercase via `theme.monoType.groupLabel`;
  distances and freshness in `theme.monoType.data`.
- `EmptyMapCard` restyles to the same vocabulary. No `isDark` branching.

## 6. Privacy policy

`docs/legal/privacy-policy.html` currently says a stored reading "remains, and
administrators can still see it on the live map, shown" with its age (§6, §8,
and the §2.4 / Settings passages around lines 460–530). With a 2-hour cutoff
that becomes false. Update those passages to say the map stops showing a
location older than two hours; the stored reading itself is still kept until
sign-out, account deletion or disable, which is unchanged. **Republish to the
`es-pro-legal` repo in the same change, byte-identical** — editing
`docs/legal/` alone changes nothing a user can read.

## 7. Testing

- Unit: the test-account filter at each list consumer; `presenceHiddenAfter`
  boundaries (exactly 2 h, just under, null `updatedAt`); the three-section
  grouping (test accounts excluded from all three; a sharing-on user with no
  fix at all lands in NOT SEEN, not SHARING OFF); the ask-page gate (each
  condition false in turn).
- Rules read-back: `isTestAccount` is on the admin path, absent from the self
  `hasOnly`, extending the existing
  `test/features/employees/domain/self_service_fields_test.dart` pattern.
- Widget: sheet at rest / selected / expanded through the existing
  `LiveMapScreen.mapBuilder` seam; the ask page's two buttons; the Team
  roster's collapsed Test accounts section; 260 px × 2× text overflow sweeps
  on the sheet and the ask page.
- Device only: fresh fix on resume (geolocator has no channel tests), the iOS
  permission prompt after Turn on, and sheet drag physics over the map
  platform view (the map needs its `EagerGestureRecognizer`; the sheet must not
  lose drags to it).

## Deploy

- **No required backend deploy.** The optional `isTestAccount` type check in
  `firestore.rules` is the only candidate. If taken, old builds never write the
  field, so deploying it first breaks nothing.
- No functions, no indexes, no backfill. Marking the Apple tester is a manual
  admin step after the build ships (flip the switch on that account).
- New l10n keys in both ARBs: `employees_` (test-account switch and caption,
  Test accounts section), `liveMap_` (sheet header count, the three section
  labels, "Also nearby", footer, "Hasn't turned sharing on"), `settings_` or
  `onboarding_` (ask page), and reworded `tour_liveMapRoster*`.

## As built (2026-09-13) — deviations from the design above

- **One owner for "not crew": `EmployeeRecord.isAssignable` now includes
  `!isTestAccount`.** Every picker, the dashboard's per-person numbers, the
  calendar crew filter, the clash swap pool and a book-again crew already
  route through it, so no call site re-spells the filter. The map uses
  `LiveMapAggregator.join`/`groupTeam`; the roster splits the list itself.
- **`neverSetUpAccountsProvider` is NOT filtered.** It is a security flag about
  an account still on its starting password, not a teammate listing.
- **The three sections are always in the sheet's scroll**, revealed by dragging
  up, rather than swapped in when the sheet crosses a height.
- **"No calendar tour pending" means no calendar step has EVER been seen**, not
  every step: `calendarCollapse` never renders in split layout, so the literal
  reading would hold the ask page back forever on a tablet. Consequence: on an
  upgraded device whose calendar catalog gained a step, that one step's tour can
  coincide with the ask page once.
- **"Asked" is recorded when the page is pushed**, not on a button, so a
  swipe-back or a killed app counts as Not now.
- **The ask page's map thumbnail is a painted street grid** with the person's
  avatar as the pin — a real map would cost a platform view and a billed tile
  load for decoration.
- **The recenter tile tracks the sheet's top edge** through
  `DraggableScrollableNotification`, isolated in a `ValueListenableBuilder` so a
  drag does not rebuild the map.
- **The hidden tab renders the last-known team** with no live tick, the same
  paused treatment the markers already had.
- `liveMap_rosterButton`, `liveMap_rosterTitle` and `liveMap_rosterCount` were
  deleted with `staff_roster_sheet.dart` and `staff_info_card.dart`.
- The optional `isTestAccount` rules type check was skipped (owner scope), so
  this change needs no backend deploy.
- The gate's conditions are pinned by `location_share_ask_policy_test.dart`
  and `location_share_ask_gate_test.dart`; hub-tab switching is left to the
  device pass.
- **Revised 2026-09-15 (owner call): the page shows once per app build to
  everyone, before the calendar tour.** It picks one of three versions: Turn
  on, Open Settings (a refusal iOS will not re-ask, or Location Services off),
  or "You're on the team map" with Done for someone already sharing. The
  calendar tour waits for it. This replaces both "after the calendar tour" and
  "once per device" above. The first build also skipped anyone already sharing,
  so the page appeared the moment they switched sharing off in Settings.
- The admin live map tour gained a middle step, `liveMapNotOnMap`, on the team
  sheet's count line: why someone is missing and how staff turn sharing on.

### Follow-ups still open (2026-09-15)

Not verifiable in the test harness, so they need a device pass before release:

- [ ] Install a NEW build number over an older one: the team-map page opens
      first on the calendar, and the calendar tour starts only after it closes.
- [ ] Relaunch the same build: the page does not come back.
- [ ] Fresh install, sharing off: Turn on raises the iOS location prompt.
- [ ] Location refused for the app ("Don't Allow"): the page shows Open
      Settings, the switch is saved on, and iOS Settings opens on the app.
- [ ] Location Services off for the whole phone: same Open Settings version.
- [ ] Already sharing with location allowed: "You're on the team map" + Done.
- [ ] Launch from a notification tap that opens a job: neither the page nor
      the calendar tour opens on top of the job sheet; both follow once it closes.
- [ ] Admin live map tour: the new "Not on the map?" step highlights the count
      line in the team sheet at rest and in landscape.
- [ ] French: the three page versions and the new tour step fit at large text.
- [ ] Add the change to the next CHANGELOG entry (`/release`).
