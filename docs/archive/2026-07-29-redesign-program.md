# Navigation redesign — program design

**Date:** 2026-07-29 · **Branch:** `redesgin` · **Status:** **COMPLETE.**
P1–P5 and P7 SHIPPED (P4b withdrawn, replaced by P4c); **P6 Time off and P7b
Wave invoice read path are CANCELLED — owner call 2026-09-06, neither will be
needed.** This spec owes nothing further. Two consequences are now PERMANENT
rather than deferred, and are documented as such at their sites: the dashboard's
six money sections stay omitted, and its **Year** period stays absent (it needs
an aggregate read path that nothing is now scheduled to build — see
`dashboard_period.dart`, and do not "add Year back" by widening `fetchInRange`).
Its original status line read "approved design, pre-implementation" until
2026-08-15; the build record for each project is in `redesign-subdocs/`, and the
current behaviour is `CLAUDE.md`, never this file.

Source handoff: `C:\Users\GeorgeVogas\Downloads\Scheduling app navigation redesign\design_handoff_scheduling_app\`
(docs `01`–`11`, clickable prototype `design/Scheduling App.dc.html`, screenshots partially stale —
trust the prototype and the docs; `11-auth-and-invites.md` added 2026-07-29 after the first spec
pass). The handoff is high-fidelity on visuals; every real gap is
data-model or backend. This document is the program-level spec: what ships, in what order, and every
decision made where the handoff and the codebase disagree. Each sub-project below gets its own
implementation plan when its turn comes.

## Program decisions (settled with the owner)

1. **Scope: everything, sequenced** — all seven projects plus the Wave invoice read path (P7b)
   and the auth + invites redesign (P4b, added with handoff doc 11).
2. **Client fields: fast New, full Edit** — the New client sheet ships as designed (fast capture
   only); the Edit sheet is a superset keeping every existing field plus the new ones.
3. **Archive AND delete** — Archive is the primary removal action; hard delete stays as a second
   destructive row behind a `showConfirmDialog(destructive: true)`.
4. **Wide screens: drawer everywhere, keep two-pane** — the `AdaptiveShell` nav rail is deleted at
   every size; `isTwoPane` master-detail panes and the calendar month|agenda split survive, restyled.
5. **Typography: adopt both new fonts** — Instrument Sans for UI, IBM Plex Mono for data
   (times, counts, section labels). Sans-for-UI / mono-for-data becomes a theme convention.

## Deviations from the handoff (deliberate, don't "fix")

| Handoff says | We ship | Why |
| --- | --- | --- |
| Live-map staleness red at ~10 min | **25 min**, text-only | Location is foreground-only since the App Store 2.5.4 rejection; 10 min would mark nearly everyone stale. Must stay in sync with `PRESENCE_STALE_MINUTES` (`functions/travel_utils.js`) via `presenceStaleAfter`. Markers are never dimmed. |
| Client `SINCE` editable in Edit sheet | Rendered from read-only `createdAt` | `createdAt` is server-stamped and drives dashboard trends and list order; never client-editable. |
| Email editable on My details | **Read-only** | Email is the Firebase Auth identity; changing it is an auth flow (verify + token), not a profile edit. Deferred. |
| Photo pill on the My details profile card | Not shipped this pass | No avatar-photo storage exists (avatars are initials-on-colour); adding one is its own small project. |
| Density as a user setting | Fixed at **Balanced** | YAGNI; the tokens keep the three values so a setting can come later. |
| Role-preview segmented control on My details | Not shipped | The handoff itself marks it review-only. Role comes from auth. |
| `+ ADD` photo tile in the detail sheet for everyone | **Admin-only** | Assignee rules only allow `status`/`updatedAt` writes; an employee add would be `permission-denied`. |
| Instrument Sans / IBM Plex Mono "or equivalents" | Exactly those two, **bundled as assets** | Inter is already bundled with runtime fetching disabled, so this is a straight family swap: add the two font families to pubspec, repoint `themes.dart`, and add a theme-level mono/data text-style token (none exists — without it every "mono" in the design silently falls back to the sans). |
| Live inline conflict banner in the job form ("a warning, not a block") | **Keep the save-time conflict dialog, restyled**; extend the check to the edit flow (today it's add-only and first-occurrence-only) | The dialog is already non-blocking in outcome ("Schedule anyway"). A live banner means a debounced `findBusyEmployees` round-trip on every chip/time change plus a repo signature change (it returns employees, not the conflicting windows the banner copy quotes). Revisit after P2. |
| Invite code always visible on the Team pending row | **Re-issue on view** — a "Show code" action mints a fresh code via `createEmployeeInvite`'s existing idempotent re-issue and displays it; the old code stops working | Storage stays sha256-only (`signupCodes/{hash}`); persisting plaintext would let any admin-session read harvest pending codes. Owner decision 2026-07-29. |
| Invite **email** (template, deep-link button, store fallback) | **Deferred to its own project** — this program ships the code path only (entry screen, acceptance, Team row, resend/revoke); admins share codes out-of-band as today | No email infrastructure exists; provider choice (SendGrid vs Trigger-Email extension) is shared with the parked client-reminders project and deserves its own pass. Owner decision 2026-07-29. |
| 6-character invite code, six entry boxes | **12 chars kept**, entry rendered as three groups of four boxes | Existing codes are Crockford base32 `XXXX-XXXX-XXXX` (~60 bits); 6 chars is 30 bits. Rate-limit + email binding would arguably cover it, but not worth weakening for aesthetics — overridable in the P4b plan. Hash normalization already strips dashes/case. |
| "Two tries left before the account locks for 15 minutes" | Firebase-native throttling, no tries counter | Firebase Auth throttles opaquely and exposes no remaining-tries signal; a client-side counter would lie. The handoff itself leaves the locked-out state undesigned. |
| "Keep me signed in" checkbox | Not shipped | Mobile Firebase sessions persist by default; the checkbox is a web pattern. |
| "Use Face ID" sign-in button | Deferred (handoff stubs it) | Re-auth-via-biometric is platform wiring the build order already defers; distinct from the existing biometric app-lock, which stays. |
| Archive a client instead of deleting; an Archived list filter | **Neither shipped — and the existing delete is withdrawn.** A client can no longer be removed at all | Owner decision 2026-08-01. Delete orphaned history (past appointments keep the denormalized `clientName` but lose the `clientId` link); archive was the safe alternative but bought a lot of machinery — filtering archived docs has to happen in Dart (pre-existing and Wave-imported docs lack the field, and Firestore excludes docs missing a filter field), which forces `fetchClientsPage` off a plain `List` onto a page object carrying the raw page size and cursor, or one archived doc in a full page truncates the list permanently. With neither feature, pagination stays exactly as it was. Accepted cost: the clients list and the booking picker grow monotonically. |
| `searchClients` gains an `includeArchived` flag | Not shipped | Follows from the row above — there is nothing to include. |

## Build order

```
P1 foundation → P2 calendar → [P2b hardware-pass changes] → P3 clients → P4 team → P4b auth+invites → P5 settings/my-details → P7 dashboard/history
                                                                                       P7b Wave invoices (parallel, unblocks P7 money sections)
                                                                                       P6 time off   (parallel, DEFERRED — skippable, see P6)
```

**Revised 2026-08-10:** P6 was between P5 and P7 and no longer is — the owner deferred it, so P7
follows P5 directly and P6 becomes a parallel option like P7b. P4b is **withdrawn**, not built:
P4c replaced the signup-code flow it delivered.

**P1, P2 and P3 are shipped, plus P2b** — the owner changes that came out of the
first run on real hardware (2026-07-31). Several P2 bullets below were revised
in place and are marked as such; the rest of P2b is its own section after P2.

P3/P4 model+rules work has no P1 dependency and may land early if de-risking is preferred.
P4b sits after P4 (owner decision): auth already works so nothing is blocked, the pending-invite
row lives on the Team screen, and the restyle needs P1's tokens — the handoff's "auth first"
build-order step is greenfield logic that doesn't apply here.

---

## P1 — Foundation: tokens, fonts, drawer, header pair, toast

**Tokens.** Fold the `01-tokens.md` palette, radii, shadows, and motion into
`core/theme/design_tokens.dart` + `ColorScheme` + the existing `ThemeExtension`s
(`AppStatusColors`, `AppCardStyle`). Dark palette per `09-dark-theme.md`: separation by surface
stepping not shadow, status chips move to 16%-alpha fills, avatar text flips to near-black tints of
the avatar hue, buttons stay saturated (`#1D6BE8`), scrim deepens. **Never branch on
`isDark`/brightness** — every light↔dark divergence is a new extension field set in both `.light`
and `.dark`.

**Fonts.** Instrument Sans (UI) + IBM Plex Mono (data) bundled as assets. New type ramp from
`01-tokens.md` (display 26/700 −0.025em … micro mono 9px floor). Add a theme-level accessor for the
mono data style so call sites don't hand-build `GoogleFonts.ibmPlexMono(...)`.

**Header pair.** One reusable widget: Calendar pill (blue-tint pill, 38px tall) + hamburger icon
button (38×38, radius 12, blue tint), with a back-chevron variant for pushed pages. Replaces
`AppTopBar`'s current action area on every screen — **except the calendar itself, which builds it
with `showCalendarPill: false`** (revised 2026-07-31: a go-home pill on the screen it goes home to
is dead weight). The Calendar pill routes through
`HubTabSelector.select(AdaptiveDestination.calendar)` — clears pushed pages, closes sheets/drawer;
no screen is a dead end. The Live map floats the pair top-right on white shadowed surfaces.

**Drawer.** New right-anchored 284px grouped end drawer replacing both the current
`SettingsDrawer` nav list and the `AdaptiveShell` rail (rail deleted; `endDrawerFor` no longer
returns null on split layouts). Groups and dot colours per `02-navigation.md`:
TODAY (Calendar · Day route · Live map) / PEOPLE (Team · Time off · Clients) /
THE BUSINESS (Dashboard · History) / ACCOUNT (My details · Settings). Header = avatar + name +
`"Owner · Espro Plumbing"`-style line; version string pinned at the bottom. Counts wired live:
Calendar = today's job count, Live map = crew-on-the-clock count, Time off = pending count
(red when > 0; provider arrives in P6, renders nothing before that). **Employee drawer is scoped:**
TODAY (Calendar, Day route) + ACCOUNT only.

**Toast.** Restyle `NoticeListener`'s notice to the dark pill (`#0B1A33`/dark `#1A2436`, radius 16,
status dot, 2600 ms in-hold-out, 56px from top). Architecture, `noticeServiceProvider` API, and the
per-kind haptic are unchanged. Dot colours: mint success · `#7FCBFF` info · `#F0C36A` request sent ·
`#FF9AA8` declined/error.

**Hub restructure.** Hub tabs shrink to **Calendar · Clients · Team · Live map** (persistent
`IndexedStack`). **History and Settings become pushed routes** alongside Dashboard, Day route,
Time off, My details, client detail, employee detail. Handled consequences (verified against the
code 2026-07-29):

- **The `IndexedStack` index is currently the raw `AdaptiveDestination` enum ordinal**
  (`hub_shell.dart` iterates `AdaptiveDestination.values`; `index: _current.index`). Shrinking to
  4 tabs while `destinationRoute`/drawer nav/tour scopes still need `history`/`settings` members
  requires an explicit hub-tab list + `indexOf` (or a split tab-vs-pushed enum) — the ordinal
  coupling must go. `AppRoutes.history`/`.settings` stop calling `_hubRoute` and become plain
  `AppPageRoute`s. `hub_shell_test.dart` selects `.settings`/`.history` and breaks; so does
  `tour_definitions_test.dart`'s "every enum value has an admin tour" assertion.
- **The Calendar pill needs a composite go-home helper, not `select()` alone**:
  `closeEndDrawer()` → `HubShell.liveState.showCalendar()` → pop back to the shell. The pop
  target is the **shell's own route**: `HubShellState` captures `ModalRoute.of(context)` and the
  helper does `popUntil((r) => r == shellRoute)` — precise regardless of stack composition,
  unlike `popUntil(isFirst)`, which is wrong on the `_hubRoute` fallback branch where the shell
  is not route #1 (the existing appointment deep-link handler shares that latent assumption).
  Two dispatch paths: `HubShellScope` on tab screens, static `HubShell.liveState` on pushed
  screens (the Dashboard back button is the existing precedent).
- **Feature tours on pushed routes need a new host gate.** `FeatureTourHost` gates on
  `HubShellScope.currentOf`, which is null on a pushed route — the Settings/History tours would
  silently never start (Settings is one of only two employee tours). Decision: add a
  route-current gate mode (`ModalRoute.isCurrent`) and widen the scope/seen key beyond
  `AdaptiveDestination`; keep both tours.
- **Placing the header pair in `actions` on every screen kills Flutter's auto `EndDrawerButton`**
  (four screens rely on it today) — every screen wires `openEndDrawer` explicitly and gains a
  `GlobalKey<ScaffoldState>` where missing (7 of 9). Settings and the text-size sub-page have no
  drawer at all today and get one. The new drawer header reads identity from live providers
  (`currentUserNameProvider` / auth) — never feed it back through `select()`, which would nuke the
  hub's screen cache mid-session.
- New pushed screens (History, Settings, Time off, My details, detail pages) each get their own
  `PrimaryScrollScope` — a pushed route sits above the tab scopes and would otherwise attach to
  the root controller.
- FAB `heroTag`s stay unique across tabs **and pushed routes** (pushed screens don't unmount the
  hub). Current set: `addFab`, `todayFab`, `clientsAddFab`, `employeesAddFab`, `liveMapRosterFab`,
  `liveMapRecenterFab`; History/Settings have none, so the restructure itself changes nothing.
- Android back / iOS edge swipe still return to Calendar (`PopScope` + the hand-rolled edge swipe
  in `hub_shell.dart`, which exempts the calendar tab because the calendar owns horizontal
  swipes — see P2 month paging).
- Dead code to remove with the rail: `AdaptiveShell`/`_RailEntry` only (the file also holds
  `AdaptiveDestination`, `destinationRoute`, `HubTabSelector`, `HubShellScope`,
  `navigateToDestination` — all load-bearing), plus `ResponsiveContext.isExpanded` and
  `Breakpoints.expanded`, whose only consumer is the rail.
- Stacking order per `02-navigation.md`: pushed page below status bar; sheets above; dropdown menu
  sheet above sheets; drawer above that; notice on top.

## P2 — Calendar

- Fixed header block (never scrolls): mono `SCHEDULE` label, tappable month name + year + chevron →
  the **existing `MonthYearPicker`** (already shipped — restyle only), route icon button, hamburger.
  **The header is a custom widget outside `Scaffold.appBar`** — `AppTopBar`'s `PreferredSizeWidget`
  contract can't host an animated week strip (static height per build; it would clip or jump), and
  the design's white header block isn't a Material AppBar anyway.
- Month grid: **only the weeks the month occupies — 4, 5 or 6 rows** (revised 2026-07-31; it
  shipped as a fixed 42 cells, which trailed a week of nothing but off-month days. A fixed 5 is
  wrong the other way and drops the end of months like August 2026, so the count must stay
  derived), 2px gap, 46px
  cells, **32×32 day circle carries the selected fill** (not the cell), max-3 crew dots (5px)
  coloured by who works that day, off-month cells blank and untappable. (Revised 2026-07-31: the
  dots render on **every** cell that has crew — off-month, today, and the selected day. Because
  the fill is on the circle and not the cell, the dot row below it stays legible, and hiding it
  on selection blanked the crew for the one day the user was looking at.) Replacing `table_calendar`
  (blast radius: `app_calendar_view.dart`, two `isSameDay` imports, one test file, pubspec). The
  custom grid must own what the package did:
  - **horizontal month-swipe paging** (the hub's calendar-tab edge-swipe exemption assumes the
    calendar owns horizontal drags);
  - **locale-driven weekday headers** via `DateFormat` symbols — the design's hardcoded
    `S M T W T F S` is wrong for fr_CA;
  - **per-cell full-date `Semantics`** (the merged "date + N appointments" label is pinned by
    `app_calendar_view_test.dart` — the only a11y coverage the grid has);
  - **today from `currentDayProvider`**, never bare `DateTime.now()` — a grid that caches its
    today index keeps yesterday circled past midnight (same for the Today pill's visibility).
  - Crew dots need a new per-day **distinct-assignee** colour aggregation (derived beside the
    existing `_dayIndex`) — today's dots are the first three *appointments* and any multi-crew job
    renders grey (`colorFromMap` nulls on `employeeIds.length != 1`).
- **Appointment fetch range widens from month ±7 to ±14 days** — a 42-cell grid showed up to 12
  trailing days of the next month, which the old range would leave dotless. (Revised 2026-07-31:
  with a variable-row grid the true worst case is ±6, and ±14 is kept as a deliberate superset.
  The range is also **unioned with the selected day** — `AppointmentDateRange.forCalendar` —
  because paging months leaves the selection behind and its jobs then fall outside the fetch.)
- Collapse (**revised 2026-07-31 — this is no longer a scroll-driven "sticky" collapse**): the
  grid is FIXED above the agenda and the jobs get their own scroll view, so reading down the day
  never moves the calendar. Collapsing is a deliberate **drag on the divider between the two**
  (24px of travel, `CalendarCollapse.onDragDelta`; the handle is a tap-toggle too), and the grid
  unmounts in favour of a week strip (56px cells, 30×30 circles, one 4.5px dot) in the fixed
  header. **No spacer** — with two viewports there is no vacated scroll extent to hold, which
  retires both the design's 150px and the derived `gridHeight − stripHeight` that replaced it.
  There is likewise no scroll listener and no arm/fire hysteresis. Collapse applies to the
  portrait layout only — the `isSplitLayout` month|agenda split keeps its two independent panes.
  *(As shipped in P2 this was one `CustomScrollView`, collapsing past 80px with a 44/6 two-stage
  re-arm; the owner reversed it after the first hardware pass.)*
- Agenda header: date title + mono `N JOBS` count.
- **Appointment card** (single shared widget): white radius 15, 4px full-height crew bar (today
  3px), title + status chip row, mono time range (en-dash; the merged semantics label and time
  formatting change together), then **an avatar per assignee followed by the client name**
  (revised 2026-07-31 — it shipped as one avatar plus a `"Theo +1 · Client"` string; the crew is
  now entirely visual and the client gets the whole text line. The bar bands every assignee's
  colour to match. `clientName` is already denormalized on the record). **API change:** the card takes
  a per-assignee `(name, color)` list instead of today's pre-resolved single colour + pre-joined
  name string — 5 call sites (agenda, client job history, day route, dashboard ×2). **History's
  `AppointmentTile` merges into the card**, porting `dimWhenCancelled` (strikethrough — currently
  only the tile has it), `alwaysShowChip`, and reconciling both test suites. Cancelled =
  strikethrough at 0.6 opacity. Keep the `IntrinsicHeight` constraint — title stays plain `Text`,
  and no `LayoutBuilder`/`AutoSizeText`/`FittedBox` anywhere inside the card's row. The employee
  detail `TODAY` panel and the P6 review sheet are new consumers, not restyles. (The iOS Live
  Activity card mirrors this card's layout by hand — divergence is allowed but deliberate.)
- **Detail sheet + job form restyle belong to P2** (new sheet chrome, mono when-line, action
  tiles, info panel; form sections restyled in the form-sheet chrome). The busy-conflict UX keeps
  the existing save-time dialog, restyled (see deviations) — and note the conflict check today is
  add-flow-only and first-occurrence-only for repeats; extending it to the edit flow is in scope
  for P2, the live inline banner is not.
- FAB (58×58, radius 20) + "Today" pill (popIn, only off-month; today it's a never-unmounted FAB
  hidden via scale/opacity — becomes a pill, keep the `find.byTooltip('Today')` test alive).
  Status model unchanged: `overdue` stays display-only and derived. (`pending` → "Scheduled" is
  **already shipped** — `status_pending` is "Scheduled"/"Planifié" in both ARBs; no work here.
  The chip's fill moves from amber to the design's neutral grey — amber is reserved for time-off
  Pending / employment Invited chips.)

## P2b — Owner changes from the first hardware pass (2026-07-31)

P2 shipped, then ran on a real iPhone for the first time. These came out of that
pass. They are **done and tested**, listed here so a later phase doesn't read the
P2 spec above and "restore" something that was deliberately changed. Per-item
rationale lives in `CLAUDE.md`; the device checks are in
`2026-07-30-p1-p2-DEVICE-TEST.md`.

**Calendar**
- Month grid renders only the weeks the month occupies; the pager animates
  between month heights and clips a taller page mid-drag.
- Collapse became a drag on the divider (see the revised bullet above).
- Paging a month — by swipe or from the picker — **selects that month's 1st**,
  and swiping the collapsed week strip pages a week and selects its first day.
  The agenda must always describe the grid above it.
- The fetch window unions the visible month with the selected day
  (`AppointmentDateRange.forCalendar`), which is what fixed "0 jobs" on a day
  that had jobs after a few swipes.
- The Today pill also shows when today's month is no longer the one on screen.
- The header month name falls back to the locale's abbreviation **by
  measurement**, not by a text-scale gate — the in-app XL setting is exactly
  1.4, which the `isCompact` (`> 1.4`) gate missed entirely.
- No Calendar pill in the calendar's own header.

**Appointment card**
- An avatar per assignee, then the client name; the colour bar bands every
  assignee's colour.

**Personal jobs (new feature, no prior plan)**
- `isPersonal` on the record: time blocked off for the crew rather than a client
  visit. Hides client, address, templates, repeat, materials and photos; the
  title is optional and stores as "Personal"; assignees stay required.
- `isAllDay` alongside it: no time entered means the block owns the day, stored
  as a real midnight → 23:59 span so every range query and sweep still works,
  and rendered as "All day".
- A personal block never derives `in_progress`/`overdue` and is skipped by the
  server's "job finished?" sweep — the two must stay in sync.
- **Off-screen mirrors — closed 2026-07-31**, in the same pass. `isAllDay` now
  reaches all four:
  - **Reminder sweep**: `selectTravelCandidates` skips all-day records. This was
    the only *bug* of the four — the midnight start put the block inside the
    90-min window at ~23:30 the night before, firing a "time to leave" push for
    something with no departure time. A timed personal job keeps its reminder.
  - **Push + digest text**: the date alone, never "12:00 a.m.".
  - **Widget**: the flag is in the job JSON in both hand-mirrored builders and
    the Swift decoder (`Bool?`, so older payloads still parse); "All day"
    replaces the time. Two extra fixes fell out: the *today* filter was
    start-time based, so an all-day block was dropped from today entirely and
    surfaced only under tomorrow; and `nextJob` would have let a midnight block
    own "up next" all day.
  - **Siri**: snapshot schema **v2** — `isAllDay` plus `title`, since a personal
    job has no client and the snapshot had no title to fall back on, so Siri
    said "unnamed client". Version bumped on both sides.
  - Swift is Mac-only verification: widget row, and the Siri phrases.

**Form + chrome**
- The schedule panel now holds all of *when*: all-day, date, start/end, repeat
  (repeat became a `SheetFieldRow` + action sheet).
- The shared address field regained its clear "×".
- The drawer's drop shadow moved outside the drawer — inside, it hazed the
  panel's own surface in light mode.

## P3 — Clients (the flagged gap)

**Model.** `ClientRecord` and `isValidClientData` (firestore.rules) gain, in lockstep:

| Field | Type | Rules cap |
| --- | --- | --- |
| `type` | string enum `residential` · `commercial` · `property_mgmt` (empty = unset) | `size() <= 32` |
| `tags` | list of strings | list `size() <= 10`; UI caps each tag via `TextLimits` |
| `accessNotes` | string | `size() <= 500` |
| `onSiteManager` | string | `size() <= 200` |
| `billingTerms` | string | `size() <= 200` |
| `autoInvoice` | bool | `is bool` |
| `archived` | bool | `is bool` |
| `jobCount` | int, **function-owned** | rejected on client writes, like `wave` |

`toMap` emits all user-owned new fields (so docs self-heal `archived: false` on first edit) and
still **never** emits `waveCustomerId`/`wave`/`jobCount`.

**Archived hazard (the trap).** Existing docs lack the field and Firestore excludes docs missing a
filter field — so **no `where('archived' == false)` anywhere**; filtering is Dart-side, and the
test is always `!(archived ?? false)` (Wave-imported docs never carry the field). The
backfill-then-where-filter alternative was considered and REJECTED: it needs a composite
`(archived, name)` index, a one-shot mass write over every client doc, a patch to Wave
`importCustomers` (Admin SDK bypasses rules, so rules can't enforce the field on that path), and
permanent every-writer discipline — one missed writer silently hides clients again. Dart-side
filtering contains the whole cost in the repository. Verified against
the code 2026-07-29, the filtering splits by surface:

- **Search** matches in Dart already — one choke point (`matchClientDocs` in the repo, plus the
  instant `_localFilter`/`ClientSearchPolicy.entryMatches` fallback). `searchClients` gains an
  `includeArchived` flag because the appointment client picker shares it (via
  `appointment_form_concerns.searchClients`, NOT `clientSearchProvider`).
- **The paginated list does NOT match in Dart today** — and naive filtering there is a data-loss
  bug: `clients_list_view.dart`'s `getNextPageKey` treats a page shorter than `_pageSize` as
  end-of-list, so one archived doc in a page would permanently truncate the list. The page API
  must carry the RAW server-page size separately from the filtered items (page object / over-fetch),
  and the pagination cursor must stay the last **raw** doc — the `_pageBoundaryNames` legacy-
  `businessName` cursor invariant depends on it.
- **`getClientById` stays unfiltered** — editing an old appointment for an archived client must
  still resolve its name/address.
- The archive toggle routes through `ClientFormController.updateClient` so the search-cache
  invalidation and `clientsRefreshProvider.bump()` both fire.

Archived clients: hidden from the client list and the appointment picker; reachable via an
"Archived" list filter; unarchive lives in the Edit sheet; job history and past appointments
untouched. `propagateClientEdits` behaviour unchanged (it reads only name/phone/address and
returns before any query when nothing relevant changed — an archive toggle costs zero reads).
Wave: `importCustomers` merges (`{merge: true}`) so an import can't resurrect an archived client,
and none of the new fields are in `mappedFieldsHash`, so archiving never enqueues a Wave sync;
app-archived and Wave-archived stay independent (accepted). Archived clients still count in the
dashboard "new clients" trend (they were new that month — accepted).

**Delete** keeps its repository path and gains a confirm dialog; sits under Archive in the Edit
sheet footer. Deleting orphans `clientName` on past appointments — the confirm copy says so.

**New client sheet** (form sheet, 88%): exactly as designed — WHO (name-or-business, type chips),
REACH THEM (phone, email · optional), SITE (address + **Map** pill → existing autocomplete,
access notes · optional), caption "Billing terms and tags can wait…". Primary verb **Add**.
Secondary **Add and book a job**: saves (existing `addClient` returns the record with its doc id),
pops, then opens the add-appointment sheet with the client pre-seeded — sequential sheets, not
stacked; double-tap-guarded with the `InlineAddClientHost` pattern (in-flight flag set before the
first await). The existing appointment-side inline add-client flow keeps working unchanged.

**Edit client sheet** (form sheet, 92%): superset in the new chrome (Cancel / title / Save bar,
white field panels, split rows) — CLIENT (name, first/last, type, since = read-only `createdAt`,
tags), CONTACT (phone, mobile, email, on-site manager), SITE (address grid incl. apt/city/
province/postal, `noFixedAddress` toggle, access notes), BILLING (terms, **Wave customer read-only
mono**, auto-invoice toggle), then Archive + Delete. Additional `contacts[]` editor stays.

**Client detail** (pushed on phones, detail pane under `isTwoPane` — decision 4): Edit pill →
edit sheet; action tiles **Call · Directions · Book job** (Book job opens the add-appointment sheet pre-seeded with this client; admin-only surface);
info panel `PHONE · ADDRESS · MANAGER · BILLING` (empty rows omitted); `JOB HISTORY` panel via the
existing `clientJobHistoryProvider`.

**Job count.** Server-maintained `jobCount` on the client doc — but by **absolute recount, never
`FieldValue.increment`**: the appointment write trigger runs `retry: true`, and a retried event
would double-count an increment. Instead, on any appointment create/delete/`clientId` change the
trigger runs a Firestore `count()` aggregate for the affected client(s) (both clients on a
reassignment) and **sets** the value — idempotent by construction, same "absolute writes +
`retry: true`" principle `propagateClientEdits` already documents, ~1 aggregate read per
appointment write. This also makes the backfill lazy: a client's count self-heals on its next
appointment write; rows render no count until the field exists (empty-omitted rule), and a
one-time recount script is optional polish rather than a migration prerequisite. The archive
caption ("keeps the N past jobs") reads the same field.

## P4 — Team

**Model.** `role` today is the ACCESS flag (`admin`/`employee`) — it keeps that meaning; the ACCESS
toggle in the Edit person sheet maps to it. The design's role chips (Lead tech · Technician ·
Apprentice · Dispatcher) become a **new `jobTitle` field**. Also new on the user doc, all
rules-capped: `workingDays` (7 bools), `workStartMinutes`/`workEndMinutes`, `maxJobsPerDay`,
`onCall` (bool), `emergencyContact` (string). Write access splits two ways: `jobTitle`,
`maxJobsPerDay`, colour, `role`, and `status` are **admin-only**; the availability family
(`workingDays`, hours, `onCall`, `emergencyContact`, `phone`) is admin-writable **and**
self-service-writable (the P5 own-doc clause). The users-doc rules keep their four read clauses.

**Names.** The invite + acceptance flows collect First/Last, but users docs have a single `name`
and `watchAllUsers` orders by it (a doc missing `name` silently vanishes from the admin roster).
So: add `firstName`/`lastName` fields AND **always keep writing the composed `name`** — never stop
populating it. `EmployeeRecord.fromMap/toMap` need explicit wiring for every new field (`toMap` is
currently test-only dead code; don't let a future `set()` call site erase fields — the live save
path is a field-scoped `txn.update`, which is safe).

**Screens.** Team list (40px colour avatar, `"<jobTitle> · <n> jobs today"`, Active/Invited chip);
employee detail: **the read-only-detail + Edit-sheet split already exists today**
(`employee_details_view` is read-only; editing is `EmployeeFormSheet`) — P4 restyles it and adds
the new sections (pushed on phones, pane under `isTwoPane`; profile card + Edit pill, info panel
`COLOUR · PHONE · HOURS · ACCESS`, `TODAY` panel of their stops — a new appointment-card
consumer); **Edit person sheet** gains — details, role chips, colour swatch grid (taken colours
hidden, current selection always visible — matches `EmployeeColorGrid` behaviour today; while
here, fix the pre-existing quirk that `usedColors` comes from `watchEmployees()`, which filters to
active — a **disabled** employee's colour isn't counted as taken and can be double-assigned),
availability (7 toggle cells + start/end + max jobs), ACCESS group (admin toggle + time-to-leave
alerts), Disable account with the reassign-count caption.
**Invite sheet** restyled (first/last, work email, role chips, colour grid with "N colours left"
caption, admin toggle off by default, amber invited note); the signup-code flow
(`createEmployeeInvite` → copy dialog) is unchanged at this stage — P4b then adds the
pending-invite row lifecycle on top. (P4b was later **withdrawn** — see its banner below; P4c
replaced the signup-code flow entirely, and the invite sheet described here now mints a real Auth
account instead.)

## P4b — Auth + invites (handoff doc 11, added 2026-07-29)

> ## ⚠️ WITHDRAWN — the signup-code invite lifecycle below was never built
>
> P4c (2026-08-02) replaced this section's entire design with admin-minted
> Auth accounts on a shared starting password, and the signup-code backend
> (`createEmployeeInvite`, `redeemSignupCode`, `signupCodes/{sha256}`,
> `app_links` invite branch) was deleted from production on 2026-08-08. Only
> the restyled sign-in and reset-password surfaces described below survive.
> Kept as written for history — see
> `docs/plans/redesign-subdocs/2026-08-02-p4c-HANDOFF.md` for what actually
> shipped.

**Scope:** restyle the three auth surfaces, redesign the invite-acceptance flow, and land the
pending-invite lifecycle on Team. **No email in this program** (see deviations); **no new stored
entity** — doc 08's "Invites" table stays modelled by the existing invited `users` doc +
`signupCodes/{sha256}` pair (revoke deletes them; accepted-at is activation).

**Sign in.** Hero-gradient top block + floating card per §1: labelled bordered fields, Show/Hide
password link (mono tracking shift), error state with red border + dot. `AuthScaffold`'s
`AutofillGroup` + commit-on-success halves are kept. Below the card: "Invited by your employer?
**Accept your invite**" → code entry. Face ID button, tries-counter copy, and "keep me signed in"
per the deviations table. Sign-in logic (`findUserByUid` → route or sign out,
`_retryOnAuthPropagation`) unchanged.

**Reset password.** Two states per §2 — idle (email + Send reset link + the amber "no email on
your account? ask your admin" note) and sent (`riseIn`; expiry + signs-out-everywhere facts; a
`SENT` panel whose **Send it again** row relabels and greys once used). Existing
`forgot_password_screen` flow underneath; `AuthFailure.isExpected` /
`logger.authFailure` conventions unchanged.

**Accept your invite — code entry.** Pushed from sign-in, or prefilled by deep link. Twelve mono
boxes in three groups of four (deviation above), not case-sensitive (hash normalization already
uppercases + strips dashes). CTA relabels "Enter the code" → "Continue" when full; a bad code
turns every box red with the expiry explanation. `DON'T HAVE A CODE?` panel copy adjusted for the
no-email reality (the admin reads it off the Team page).

**Deep link — this is a delivery layer, not a route** (verified 2026-07-29: the only URLs that
reach Dart are the widget/Live-Activity taps carrying the `homeWidget` query param, via the
`home_widget` channel — `FlutterDeepLinkingEnabled` is `false`, `AppDelegate` has no `open url`
override, Android has no `intent-filter`, and the `home_widget` handler rejects any URL without
that param, so an invite link from mail/Safari reaches nothing today). Delivery mechanism: the **`app_links` package** (SPM-vetted 2026-07-29
— ships `ios/app_links/Package.swift`, latest 7.2.1) rather than hand-rolled native handlers. It
provides the initial-link + stream API on both platforms; still required around it: the Android
`intent-filter` for `esproschedule` in the manifest (the iOS scheme is already registered;
`FlutterDeepLinkingEnabled` stays `false` — that's the correct setting *for* app_links), **one
Dart dispatcher** on the app_links stream that routes by URI host (`invite` → code screen,
`appointment` → the existing `_openAppointmentDeepLink`), a `code` parameter + **named route** for
`CreateAccountScreen` (today an anonymous `MaterialPageRoute` taking only `initialEmail`), and a
**signed-out path** — the invite branch must bypass the `currentUser == null` guard and the
live-`HubShell` wait that gate the appointment branch. This also becomes the long-term fix for the
three iOS URL producers (home-screen widget, Siri snapshot, Live Activity): the verification task
confirmed the bug 2026-07-29 (their URLs carried no `homeWidget` param, so the `home_widget`
plugin's `isWidgetUrl` never claimed them and taps were plain app launches) and applied the
interim fix — the producers now append `&homeWidget` so taps ride the existing `home_widget`
channel (Mac verification pending). Once the dispatcher exists they ride it instead, and the
`home_widget` tap channel and the `homeWidget` param retire **together** — dropping the param
while the channel is still the consumer re-breaks taps. The https store-fallback page still
ships with the deferred email project.

**Accept your invite — details.** Invite banner (who invited you, role, scope caption), first/last
split row, phone, password with a 4-segment strength meter (client-side), then the combined
**terms + location consent** checkbox gating Create account. Flow stays
`signUpWithCode` → `redeemSignupCode`: the callable gains optional validated `firstName`,
`lastName`, `phone` (each `requireString`-capped) and stamps `termsAcceptedAt` /
`locationConsentAt` server timestamps on the users doc at activation — activation stays
Admin-SDK-only, and the orphan-rollback, email-binding rate limit, and `code-email-mismatch`
failure all survive unchanged. **Email is rendered locked with a "From invite" chip and is never
editable** (watch-out 9). The code screen must pass the code forward so acceptance never re-asks.

**Pending-invite row (Team, admin).** The invited person's row expands in place per §6: dashed
`#C0CAD8` avatar with Ink 25 initials (no colour claimed yet), `INVITE CODE` block driven by
**Show code** (re-issue on view — fresh code, 19px mono, Copy pill relabelling "Copied"), amber
sent/expiry caption from the invite doc's timestamps, **Resend** (same re-issue path; relabels
"Sent again just now" — copy adjusted until email exists, e.g. "New code ready"), and **Revoke** —
a new `revokeInvite` callable (guard order auth → `assertAdmin` → shape → durable rate limit)
that deletes the `signupCodes` doc and the still-`invited` users doc; refuses if the account is no
longer `invited`. Expiry display needs `createEmployeeInvite` to also stamp `codeExpiresAt` on the
invited users doc (admin-readable), since clients can never read `signupCodes`.

**Not designed / explicitly out:** locked-out state, first-run tour, dark auth screens (palette
rules from `09` apply), owner/company sign-up (web, out of scope).

## P5 — Settings + My details

> **SHIPPED AND DEPLOYED 2026-08-11 — implementation plan and its decision log:
> `redesign-subdocs/2026-08-10-p5-my-details.md`. NOT device-verified.** All
> three phases are built and green (1795 flutter / 850 jest), and the backend
> went out at `258cc91a` (functions, rules, storage — see the deploy log in
> `docs/DEPLOYMENT.md`), so the ordering hazard is discharged and an app build
> carrying this UI is safe to ship. What remains is to verify as a
> **technician** — the whole self-service path is unreachable as an admin.
>
> **Four deliberate deviations from the text below**, each argued in the plan:
> 1. **No NOTIFICATIONS block on My details.** `settings_screen.dart` already
>    owns that section; a second copy would be two surfaces for one state. What
>    was genuinely missing was the P4-parked time-to-leave toggle, which landed
>    in the existing Settings section as `travelAlertsEnabled`.
> 2. **No profile card on My details.** Settings renders `SettingsProfileCard`
>    immediately above the row that navigates here, and the photo pill was
>    already deferred with the email.
> 3. **SCHEDULING is `maxJobsPerDay` and nothing else.** Role, job title and
>    crew colour stay on the admin Team sheet — an admin editing their own role
>    from a self-service screen is a privilege-escalation shape with no product
>    reason to exist. It writes through the ADMIN rules branch, which is why a
>    technician sees the section hidden rather than disabled.
> 4. **Identity fields are explicitly saved** behind a dirty-gated Save/Discard
>    bar (owner instruction, 2026-08-10), while availability keeps the
>    apply-immediately behaviour this spec describes. Free-text identity fields
>    auto-committing is a bad write with no undo; a switch that needs confirming
>    reads as broken.
>
> Also note `isSelf()` did not exist and had to be written — it gates on
> `isActiveUser()` as well as the uid match, so a disabled or invited account
> falls through to the admin-only branch.
>
> **Reconciled against the code 2026-08-10. Most of the Settings half already
> shipped, and the rules paragraph below was wrong.** See the reconciliation
> section after P7b for the full sweep.

**Settings** (pushed): ~~profile row → My details; grouped panels APPEARANCE (theme, text size,
language) · SECURITY (app lock, change password) · INTEGRATIONS (Wave, admin-only) ·
NOTIFICATIONS; version footer.~~ **DONE** — `settings_screen.dart` already renders the profile
card, a My-details row under ACCOUNT, and APPEARANCE / SECURITY / NOTIFICATIONS / INTEGRATIONS
(Wave, admin-only) / LEGAL / HELP sections through `SettingsSectionCard`. LEGAL post-dates this
spec (2026-08-05) and carries the Privacy Policy + Terms rows the consent stamp depends on.
Nothing in the Settings half is outstanding.

**My details** (pushed, everyone): profile card (photo pill deferred with email — see deviations);
YOU CAN CHANGE THESE (phone, emergency contact; email shown read-only); MY AVAILABILITY (7 day
toggles, start/end, on-call) — **applies immediately**, with the inline amber conflict warning when
a turned-off day has booked work ("…the jobs stay until someone moves them"); ~~TIME OFF section
(P6)~~ *(omitted while P6 is deferred)*; NOTIFICATIONS (existing toggles). For admins the SET BY YOUR ADMIN panel appears as an
editable SCHEDULING panel; for technicians it is **hidden entirely**.

**The screen exists and holds the emergency contact only** (`my_details_screen.dart`), reading and
writing `users/{docId}/private/emergency` — the emergency pair moved OFF the users doc on
2026-08-02 because rules are document-level and `/users` read clause 2 lets every active employee
read every active peer. Everything else in the list above is still to build.

**Owner decision, 2026-08-10: an employee edits their OWN contact details here — phone AND
email.** This supersedes "email shown read-only" above. The two are not the same size of job:

- **Phone is nearly free.** `phone` is already in `isAvailabilityOnlyChange()`'s allowlist, so
  wiring P5's self-service clause gives it with no new callable. Bind the field to
  `TextLimits.phone` and `PhoneInputFormatter` (numbers are stored formatted, `(514) 555-1234`).
- **Email is a sign-in identity and needs the joining callable.** The client must **never** write
  `email` on the users doc — `email` must NOT join that allowlist. Auth and Firestore move together
  or neither, which is the whole reason `changeEmployeeEmail` exists and is called from *inside*
  `updateEmployee` rather than exposed as its own repository method. The shape:
  - **Add a `self` branch to `changeEmployeeEmail`, don't write a second callable.** Keep one owner
    for "an email edit moves both stores". Guard order stays auth → (admin **or** the caller's own
    docId) → `assertPayloadShape` → `enforceDurableRateLimit` → work, and the per-caller budget
    stays — this rewrites a sign-in identity. The Auth-first / Firestore-second ordering, the
    revert, and the `email-changed` concurrent-edit rejection all apply unchanged.
  - **Re-authenticate before the write.** An unattended unlocked phone changing the sign-in address
    is the account-takeover primitive. `AccountDeletionService.reauthenticateWithPassword` already
    exists for exactly this shape — reuse it. Any new password field owes
    `enableIMEPersonalizedLearning: false` beside `obscureText`, unconditionally.
  - **Know the typo hazard, and that it is recoverable.** The Admin SDK sets the address with no
    proof the person controls it, so a mistyped email means they cannot sign in. An admin can undo
    it with the same callable, so the blast radius is bounded — but the sheet should confirm the
    address twice rather than lean on that. The alternative, Firebase's `verifyBeforeUpdateEmail`,
    flips Auth **outside** the callable and leaves `users.email` stale with no trigger to reconcile
    it — the exact desync the callable was built to end. If proof-of-control is wanted later, it
    needs a two-phase `pendingEmail` + reconcile, specced separately.
  - **Tell the admins, not the employee.** `notifyEmailChanged` pushes the person whose address
    moved, which is right when an admin made the change and pointless when they made it themselves.
    A self-service change should notify active admins instead — the same fan-out P6 needs, so build
    it once (see P6's requirement 1).

**Rules.** A user may update **only** the self-service keys on their own doc, under
`resource.data.uid == request.auth.uid`; scheduling fields (role, jobTitle, colour, maxJobsPerDay,
status) stay admin-only. **The key list is not this spec's to invent — `isAvailabilityOnlyChange()`
is already written in `firestore.rules` and P5's job is to CALL it**, by adding
`|| (isSelf() && isAvailabilityOnlyChange())` to `allow update`. As built it is
`hasOnly(['workingDays', 'workStartMinutes', 'workEndMinutes', 'onCall', 'phone', 'updatedAt'])`.

**`emergencyContact` must NOT be added to that list** (this spec originally listed it). It is not a
users-doc field any more, and `allow update` routes both emergency keys through
`emergencyFieldNotSet()`, which permits a write that leaves them ABSENT and refuses one that leaves
a value. The subcollection already carries its own self-service grant
(`isAdmin() || (isActiveUser() && myDocId() == userId)`), so My details edits them there and needs
nothing new.

~~**`allow create` currently has zero field validation**, so the new caps must be applied to create
as well.~~ **CLOSED 2026-08-08** — `allow create` now runs `isValidUserData` and denies
`uid`/`termsAcceptedAt`/`locationConsentAt`/`emergencyContact`/`emergencyPhone` outright. (One
stale comment inside `isValidUserData` still says otherwise; it is a comment, not a gate.)

The two "only an admin can write" rule comments become wrong and must be updated. Nothing is ever
auto-unassigned: availability changes notify (inline warning + P7 dashboard flag), a human moves
the jobs.

## P6 — Time off (new feature) — CANCELLED

> **Owner call, 2026-09-06: P6 is CANCELLED and will not be built.** It had been
> deferred since 2026-08-10; this closes it. Nothing below is live work — the
> design is kept only as the record of what was decided and why. The personal
> block / day-off stopgap described under "what P6 would have bought" is now the
> permanent answer, not a placeholder. Everything from the deferral still holds:

> **Owner call, 2026-08-10: P6 is deferred and may be skipped entirely.** Nothing has been
> built — no `timeOff` collection, no rules, no surfaces; the only trace in the code is two
> comments reserving the `PushedDestination.timeOff` slot. **It is not a prerequisite for P7**;
> the build order below now runs P5 → P7 and treats this as a parallel option.
>
> **P7 must therefore omit, not stub, the three places it reaches into P6** — the Time off card,
> the drawer's pending count, and the pending-time-off entry in Needs attention. That is the
> spec's own empty-omitted rule (the same treatment the money sections get until P7b), so no
> placeholder, no zero state, no disabled row.
>
> **Until then, the stopgap is a personal all-day block** — an admin books a `isPersonal` +
> `isAllDay` appointment spanning the dates, assigned to whoever is away. Verified 2026-08-10 that
> this genuinely covers the most valuable thing P6 would buy: the person **shows as busy in the
> booking conflict dialog**, because `findBusyEmployees` skips only terminal jobs and
> non-overlapping daily windows — it has no opinion about personal or all-day. It also renders on
> every day of the run, is visible to the employee, and is deliberately spared both the travel push
> and the "job finished?" nag. Its limits: the **14-day cap** means a three-week holiday is two
> blocks; and only an admin can book it (the appointment forms are admin-only), so there is no
> request step. **The third limitation — "it counts as a job in the dashboard's workload bars and
> jobs-per-day" — was CLOSED on 2026-08-24** by the `isDayOff` chip on the personal form: a block
> marked time off is dropped from every job count (dots, agenda header, drawer badge, roster
> "jobs today", the whole dashboard) while still rendering its card wearing a "Day off" chip. It
> is not P6 and does not stand in for one — there is still no request/approve flow, no allowance,
> no `timeOff` collection.
>
> **P5's availability is NOT a substitute and must not be sold as one.** `workingDays` /
> `workStartMinutes` / `workEndMinutes` / `onCall` describe a *repeating weekly pattern*, so
> turning Thursday off for a holiday turns off **every** Thursday. A dated absence is not
> expressible there. That gap is precisely why P6 exists.
>
> Everything below is the design as approved on 2026-07-29, kept intact for whenever it is
> picked up. Its four backend requirements were re-verified against the code on 2026-08-10 and
> all still hold — with one addition: the **active-admins fan-out** it needs is now also needed by
> P5's self-service email notice, so whichever lands first should build it for both.

**Collection `timeOff`:** `{employeeDocId, uid, from, to, kind: holiday|sick|unpaid, note, status:
pending|approved|declined, declineReason, decidedBy, decidedAt, createdAt, updatedAt}`. Allowance:
`allowanceDays` on the user doc (admin-set, default 15); used-count derived from approved requests
in the current year. **Rules:** employee creates own request only with `status == 'pending'` and
`uid == request.auth.uid` (payload shape validated); employee reads own; admin reads all; admin
updates status pending→approved / pending→declined, **decline requires a non-empty
`declineReason`**; no client deletes. Server timestamps on create/decide.

**Surfaces.**
- **Request sheet** (employee, from My details): From/To, kind chips, note; derived mono summary
  (`4 DAYS · 2 WORKING DAYS` — working days from their own `workingDays`); derived **jobs in this
  window** panel with the caption "Nothing is cancelled by asking"; footer "Send request to
  <admin>".
- **Review sheet** (admin): request header + note; `N JOBS TO REASSIGN` — each job with crew chips;
  a chosen chip **reassigns through the existing appointment edit path** so
  `mergeRetainedAssignees` and the notification diff hold; decline-reason chips; Decline / Approve
  (label tracks: "Approve" / "Approve and reassign").
- **Board** (pushed, admin): Waiting / Upcoming / History segmented tabs per `05-screens-business.md`
  — request cards with age chip and coverage warning; month-grouped upcoming; allowance-used bars +
  decided list **with the decline reason quoted**. Declines always carry their reason, here and on
  the employee's page.
- **Dashboard card** + drawer pending count (red when > 0).
- **Calendar context:** approved days block the employee's calendar visually (rendering decided in
  the P6 plan).
- **Pushes:** request-created (to admins) and decision (to the employee) ride the existing FCM
  pipeline in `notifications.js`, with per-recipient idempotency ledgers like the existing kinds.
  Verified 2026-07-29 and **re-verified against the code 2026-08-10 — all four still hold**:
  (1) `sendToEmployee` is single-recipient and **no admin fan-out helper or `where('role')` query
  exists in functions/** — the request-created push needs a new active-admins query and a ledger id
  keyed per admin docId (or one admin's claim suppresses the rest); the role filter itself won't
  fight it — callers pass their own role set, like the timed sweeps do. It is now **exported from
  `notification_utils.js`** (2026-08-04, for `notifyEmailChanged`), so call it — never re-derive the
  token fetch, the role/active gate or stale-token pruning. (2) New kinds MUST be added to the
  `_MESSAGES` table in **both** EN and FR — an unregistered kind silently sends an
  empty-title/empty-body push, no error. That table now lives in
  **`functions/notification_messages.js`**, and the pure decision helpers it reads
  (`contextFor`, ledger ids, kind priority, recipient roles) live in
  **`notification_policy.js`** — a new *pure* rule goes there and is re-exported from
  `notification_utils.js`; only a helper that needs `deps` stays in the orchestration file.
  (3) The client's `_handlePushTap` (`main.dart:247`) **still** ignores `kind` and unconditionally
  yanks to the Calendar tab — it must branch on `data['kind']` so a time-off tap opens the
  board/My details instead. (4) The new ledger collection needs the Admin-SDK-only rules deny block
  and an **offset-0** TTL policy declared as a `fieldOverrides` entry in `firestore.indexes.json`
  (console-only state gets deleted as drift), like the existing ledgers.
- **Rules/query discipline:** the employee-read clause (`resource.data.employeeDocId ==
  myDocId()`) is only provable for list queries whose WHERE carries it — every employee-side
  `timeOff` query must filter `employeeDocId == <own docId>`, or Firestore rejects the whole query
  (the users-collection lesson). Admin queries ride `isAdmin()` unconstrained.

## P7 — Dashboard + History

**Dashboard** (pushed, admin): hero gradient card (today's count + completed / in progress); period
segmented control **wired** (Today · Week · Month · Year re-filter the aggregator); KPI grid
(only the tiles with data — see P7b); ~~Time off card (P6)~~ *(omitted while P6 is deferred)*;
employee workload bars; New clients
(from `createdAt`, tappable rows → client detail); Jobs booked per day (7 bars, over-capacity red
using `maxJobsPerDay`); Needs attention (existing flags + ~~pending time-off~~ *(omitted while P6
is deferred)* + availability-conflict + ~~stale invites~~ → **accounts never set up**). **Chart rule everywhere:** bars live in their own fixed-height track; value and
axis labels are siblings outside it — labels sharing the flex column silently clip tall bars.

> **Reconciled 2026-08-10 — three constraints this spec predates:**
>
> - **The period control cannot just widen the aggregator's range.** The dashboard window is
>   deliberately SPLIT (2026-08-08): `DashboardAggregator.liveRangeAround` is a live listener,
>   `historyRangeAround` is a one-shot `fetchInRange`, merged by doc id (live wins, never
>   concatenated — they overlap by a fortnight). Held as one 70-day range it was a business-wide
>   listener capped at `_rangeStreamLimit`, silently computing the trends over a PREFIX above
>   ~14 jobs/day. **Month and Year must widen the HISTORY half**, never the live one.
> - **"Jobs booked per day" counts a multi-day run on every day it runs.** The aggregator already
>   scopes through `runsOn(...)`; a new reducer must too. A `startTime` comparison would drop days
>   2+ of a run and, because the range stream is a superset of its range, report a fortnight of
>   past jobs as today's.
> - **"Stale invites" becomes "never finished setting up".** P4c deleted the signup-code invite flow
>   and the backend went with it on 2026-08-08. **Owner call 2026-08-10: keep the flag, re-pointed
>   at accounts still `status == 'invited'`** — created by an admin, never set up by the person, and
>   therefore still sitting on the shared `Welcome123!`. It is the one operational risk that design
>   creates, so the dashboard should say so.
>
>   Read them from **`allUsersStreamProvider`**, never `employeesStreamProvider` — the latter filters
>   to `status == 'active'`, so it would be permanently empty and the flag would silently never fire.
>   `watchAllUsers()` is already always-on, so this costs no extra listener. Test with
>   `EmployeeRecord.isInvited` (an **exact** match — an empty or unknown status is not this). Age
>   comes from the users doc's `createdAt`, which is function-owned and **nullable on legacy docs**:
>   treat null as unknown and still list the row rather than dropping it. Tapping one should land on
>   the Team roster, where `PendingInviteTile` already owns Reset password and Remove. No new query,
>   no index, no rules change.
>
> - **"New clients" excludes archived clients.** Owner call 2026-08-10. The dashboard answers *what
>   should I look at now*, and an archived client is one you decided not to look at.
>
>   Note this is a **behaviour change, not a no-op**: `fetchClientsCreatedSince` has no `archived`
>   filter today, so archived clients are being counted. **Filter in Dart** —
>   `if (!client.archived)` beside the existing `createdAt != null` guard in `newClientDatesProvider`
>   — rather than adding `.where('archived', isEqualTo: false)`, which would need a new
>   `(archived, createdAt)` composite index and a deploy. The repo's "never filter a server page in
>   Dart" rule is about `fetchClientsPage`, where a shortened page breaks the cursor and truncates
>   the list permanently; this read is a bounded one-shot window feeding a count, with no cursor and
>   no pagination, so the hazard does not apply. The only cost is that archived clients still count
>   toward the read cap, which is irrelevant at an 8-week window.

**Money sections do not ship in P7.** Revenue trend, Avg ticket, Unpaid invoices, Top clients by
revenue, Quotes won, First-time fix are **omitted** (not stubbed — empty-omitted rule) until P7b.

**History** (pushed): search field with clear button; **Year / Crew dropdowns opening as
dropdown-menu sheets** (the reusable single-select sheet pattern from `06-sheets-and-dialogs.md`);
quick-filter chips; mono result count; day-grouped panels; cancelled struck through. Filtering
stays the existing bounded Dart-side search (`historySearchProvider`); no new server queries.

> **Reconciled 2026-08-10.** The Year/Crew filters already exist
> (`HistoryFilterBar`) — as `FilterChip`s opening a **`MenuAnchor`**, not the sheet pattern. So
> this is a presentation swap plus the chips/count/grouping, not new filtering. Two things this
> spec predates: `AppointmentHistoryView` now takes an `isAdmin` and passes it straight through as
> `showActions` (restored 2026-08-08 — History is where `done`/`cancelled` jobs live, so it is the
> one screen an admin looks for a completed job's edit button on); and the closed-job **collapsed
> green treatment is calendar-agenda-only by design** — History keeps the plain full-height
> `AppointmentCard`. Don't "unify" it here; the agenda sinks closed work because it answers
> *what's left today*, and History is a record where everything is closed.

## P7b — Wave invoice read path (independent project) — CANCELLED

> **Owner call, 2026-09-06: P7b is CANCELLED and will not be built.** The six
> dashboard money sections therefore stay permanently omitted (empty-omitted
> rule, not stubbed), and the dashboard's **Year** period stays absent — this
> was the aggregate read path that would have served it. The design below is
> kept as a record only.

Unblocks the six dashboard money sections. Server-side only: scheduled function queries Wave
(GraphQL, `WAVE_FULL_ACCESS_TOKEN` from Secret Manager) for invoices; projects the minimal fields
(totals, status, age buckets, customer id) into a rules-locked `waveInvoices` (or aggregate doc)
collection readable by admins via a callable, mirroring the `waveGetConnection` pattern — the app
never talks to Wave directly and no client-side reads of the raw collection. Scoped and specced
separately when it starts.

## Reconciliation — what changed under this spec (2026-08-10)

P5, P6 and P7 were specced on 2026-07-29. Eleven days and five projects later the
code they build on has moved. The corrections are inline above; this is the list of
**new obligations any of the three now inherits**, none of which existed when the
spec was written. Read it before starting any of them.

**A new screen is no longer just a screen.** P6's board and P5's My-details expansion
each pick up:

- **A sealed `AppDestination` member.** `PushedDestination.timeOff` is already reserved by a
  comment in `drawer_catalog.dart`. `.name` is load-bearing twice over — it is the persisted
  `tour_seen_tabs` key AND the showcase scope name, so renaming a member later replays or orphans
  a tour.
- **A drawer row is an icon chip, not a label.** `drawerRowIcon(d)` and `drawerDotColor(d)` are two
  separate exhaustive switches over the sealed family; a new member fails to compile until both
  are answered. Row padding is `sp8` on purpose (it keeps the 28px chip inside the 48px minimum).
- **A feature tour.** Tours are keyed on the sealed `TourScope` — `DestinationTour` for a screen,
  `FormTour` for a create-flow sheet. A data-dependent screen MUST pass `FeatureTourHost(ready:)`
  false while its body is a placeholder: a partial start runs the surviving steps, marks the WHOLE
  scope seen, and the dropped ones are gone for good. A paginated body has no `AsyncValue`, so it
  exposes an `onFirstPageSettled` and gates on that.
- **`guardedOffline` at every widget-layer write**, and a **sealed action outcome** from any
  controller action with more than two results — a reentrancy skip is a `Busy` member, never a
  fabricated `SocketException`, which `_classifyError` would render as "you appear to be offline"
  while perfectly online.
- **Notices, not SnackBars**, composed through `composeErrorNotice(context, intro:, error:)`. The
  notice carries **no support tag** any more (2026-08-04) — the tag survives only as the
  `logger.warn` label prefix, and a new operation still owes a new tag plus an `error_intro*` key
  in both ARBs.
- **Busy state as sets of doc ids, not booleans**, on anything that can show several rows acting at
  once (`EmployeeFormActivity` is the reference). A time-off board approving three requests is
  exactly the shape that bit the roster.
- **Rules caps vs client caps vs callable caps**, now enforced by
  `test/core/validators/text_limits_test.dart`, which reads `firestore.rules` back and fails the
  build on a client cap that exceeds its rules or callable cap.

**P6 additionally inherits the appointment model's day rules.** "Jobs in this window" on the
request sheet, and "N jobs to reassign" on the review sheet, are **daily-window overlap questions**:
route them through `runsOn` / `runsInRange` / `dailyWindowsOverlap` (`appointment_day_slice.dart`),
never a `startTime` comparison. A range stream is a superset of its range — a reducer over
`appointmentsInRangeProvider` without a day predicate is a bug, and that exact omission shipped in
four surfaces before the 2026-08-04 audit caught it. The reassign path must also keep going through
the appointment edit path so `mergeRetainedAssignees` holds.

**P6's "approved days block the employee's calendar visually"** now lands on a calendar that
renders per **work day** slices with an agenda comparator that sinks closed jobs. Whatever the
blocking treatment is, it is not an appointment and must not be fed through `expandToDays`.

## Open questions — all three SETTLED 2026-08-10

Three things the code had settled differently from this spec. The owner's calls are recorded here
and written into the sections above; the detail lives there, not here.

1. ~~**P7 "Needs attention": what replaces stale invites?**~~ **ADD IT**, re-pointed at accounts
   still `status == 'invited'` — created but never set up. See the P7 reconciliation block.
2. ~~**P7 "New clients": do archived clients count?**~~ **HIDE THEM.** Note this is a behaviour
   change: they are counted today. See the P7 reconciliation block for why the filter goes in Dart.
3. ~~**P5's "photo pill deferred with email" — is it still deferred?**~~ **SETTLED 2026-08-10:
   employees edit their own phone AND email in My details.** The full shape — the `self` branch on
   `changeEmployeeEmail`, re-authentication, the typo hazard and who gets notified — is written up
   in the P5 section above. The **photo pill stays deferred**; only the two contact fields were
   asked for.

## Mobile-use requirements (added 2026-07-30)

The handoff is a static 390×844 mock; these rules translate it to real devices. They bind every
project, same weight as the invariants below.

- **Touch targets: design sizes are visual, never the hit area.** The handoff specs 38×38 icon
  buttons, 32×32 day circles, 30×30 week-strip circles, ~34px chips and pills — all below the
  repo's 48×48 minimum. Ship the visual sizes, but pad every interactive element's tap region to
  ≥48×48 (Material tap-target padding / `InkResponse` radius; for grid cells the *cell* — 46px ×
  ~1/7 width — is the target and the circle is decoration; the handoff's own "list rows ≥48px
  effective" shows the intent). Never shrink a hit area to match a mock.
- **No hardcoded status-bar or home-indicator insets.** The handoff reserves a literal 62px top
  and floats FABs/sheets 42px from the bottom. Real devices vary (Dynamic Island vs. SE vs.
  Android cutouts; home indicator). Every fixed header uses `MediaQuery.paddingOf(context).top` /
  `SafeArea`; every bottom-floating element adds `padding.bottom`. A literal 62 anywhere is a bug.
- **Design px heights are 1.0-scale minimums.** 46px day cells, 56px week-strip cells, 38px
  buttons, field rows — all clip at textScaler 2.0 if fixed. Heights derive from scaled text
  (the month grid already derives row height from available space — keep that; the `AppSearchBar`
  `textScaler:` lesson generalizes). The 0.8–2.0 sweep at 375×667 is the enforcement.
- **Offline-first for field use.** The primary users are techs in trucks. Every NEW write surface
  inherits the offline fail-fast pattern (`isOfflineProvider` check before the in-flight flag,
  `SocketException('offline')` → `composeErrorNotice`): time-off request/approve/decline,
  archive/unarchive, availability saves on My details, invite acceptance (show the offline notice,
  never a spinner that hangs until reconnect). Reads on the new pushed screens keep serving from
  the pinned Firestore persistence cache — no extra work, just don't break it.
- **Scroll performance on the collapse.** The week-strip listener rebuilds ONLY on the
  collapsed-flag transition (threshold crossing), never per scroll frame; the card `riseIn`
  entrance plays on first build only, not on every scroll into view; both collapse to instant
  under `disableAnimationsOf`.
- **Keyboard ergonomics.** Code entry: `autocorrect: false`, `textCapitalization: characters`,
  keyboard type visible-password-ish (no predictive bar garbage over code boxes). Phone fields:
  `keyboardType: phone`. The fixed-92%-height form sheets keep keyboard-inset-aware scrolling so
  the focused field is never under the keyboard (`FormSheetScaffold` already does this — preserve
  it in the new chrome).
- **App size: bundle only the weights the ramp uses** — Instrument Sans 400/500/600/700, IBM Plex
  Mono 500/600 — not the full families.
- **The handoff's thumb-reach decisions are load-bearing — don't "correct" them:** right-anchored
  drawer, dropdown-menu *sheets* instead of floating menus, bottom form sheets, FAB bottom-right.
  These exist for one-handed phone use; a future pass must not swap them for desktop idioms.

## Cross-cutting requirements

- **Localisation:** every new string = paired EN+FR ARB keys with `@key` blocks; `flutter gen-l10n`
  (auto-hook on ARB edits). Chip labels, mono captions, notices, decline reasons — all of it.
- **Accessibility:** text-scale sweeps 0.8–2.0 at 375×667 per screen touched; every new animation
  collapses under `disableAnimationsOf`; `Semantics` on icon-only controls (header pair, day cells).
- **Load-bearing invariants unchanged:** `showActions` required + false default · unique FAB
  `heroTag`s · `PrimaryScrollScope` on simultaneously-mounted scrollables · `isSplitLayout` vs
  `isTwoPane` not conflated (rail dies but the two-pane gate lives) · no `LayoutBuilder` under
  `IntrinsicHeight` · success ≠ `tertiary` · offline fail-fast on entity writes · notices not
  SnackBars.
- **Rules discipline:** every new client-writable field gets a type/length cap in the same commit;
  new callables follow guard order auth → `assertAdmin` → shape → rate limit → work; no new client
  `runTransaction` call sites.
- **Testing:** policy/domain logic as pure classes with `test()`; widget tests per the harness
  requirements; jest for any function changes (pure logic extracted into plain modules). Each
  project plan must enumerate the pinned suites it moves — known casualties: `hub_shell_test`
  (selects settings/history tabs), `tour_definitions_test` (every-enum-value-has-a-tour +
  settings-employee-tour assertions), `clients_screen_test` (in-pane inline edit survives
  refresh), `client_detail_view_test` (drives the inline `_isEditing` toggle),
  `appointment_card_test` + `appointment_tile_test` (merge), the calendar scale sweeps at 2×
  French, `client_form_validator_test` (signature diverges for fast-New/full-Edit), and the Wave
  mapper/worker hash tests if `toWaveCustomerInput` ever grows.

## Sequencing note

Each project gets its own implementation plan (superpowers:writing-plans) and its own
verify-and-ship cycle on this branch. P1 is first unless the owner asks to front-load the P3/P4
model + rules work.
