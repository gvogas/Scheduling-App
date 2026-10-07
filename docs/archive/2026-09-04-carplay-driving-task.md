# Apple CarPlay for ES Pro — driving-task job list

**CLOSED 2026-09-19 — owner: "CarPlay works, all clear."** The behavioural checks the
sections below leave open are done: the four actions (Directions, Start,
Complete, Call), the technician view and the App Lock behaviour were confirmed
on a device, with App Lock accepted as it behaves today (no change). Nothing is
left in this plan; archived the same day.


Status: **BUILT, COMPILED, DRIVEN and SHIPPED in 1.61.0+90** (release commit
`dd8c4863`; banner corrected 2026-09-13). Written 2026-09-04; UI design finalised
2026-09-09 (decisions 9-14 below); implementation followed the same day.
**Dart is verified**: `flutter analyze` clean, full suite 3590 passed
(including `test/core/app/carplay_bridge_test.dart` and the schema-v4 coverage
in `schedule_snapshot_test.dart`).

**The Swift compiled on 2026-09-10** — the first time it met a compiler, on a
Mac with Xcode 26.6, and it built clean with no edits. `RunnerTests` runs
green (`** TEST SUCCEEDED **`), so `CarPlayTemplateBuilderTests.swift` now
pins the builder for real rather than on paper. The Dart-to-Swift channel
contract was also checked by hand: `net.vogas.scheduling/carplay` and all four
method names match on both sides.

**The signing gate is CLOSED** (2026-09-10). The CarPlay capability was
enabled on the `net.vogas.scheduling` App ID, Xcode regenerated the profiles
under automatic signing, and `com.apple.developer.carplay-driving-task` now
lives in `ios/Runner/Runner.entitlements`; `RunnerCarPlay.entitlements` was
deleted with the gating scheme it existed for. A device build signs against
"iOS Team Provisioning Profile: net.vogas.scheduling", which carries the
entitlement. **Note the order inverts under AUTOMATIC signing**: Xcode cannot
request CarPlay in a profile until the entitlement is already in the file, so
"regenerate profiles, then move the key" is a MANUAL-signing instruction and
following it literally deadlocks. **Distribution** signing is proven by the
shipped 1.61.0+90 build, which carries the key in `Runner.entitlements` at the
release commit (unproven until then — the Mac held only an Apple Development
certificate).

**Simulator entitlement behaviour — what is and is not established.** The
CarPlay scene connects in the Simulator with the key present in
`Runner.entitlements`, and the runtime logs `Application declares driving task
entitlement`, even though `codesign -d --entitlements` on the installed app
prints nothing (simulator builds carry entitlements via the linker's
`-Simulated.xcent` section, not the signature). Two things ARE proven: the app
icon registers on the CarPlay dashboard with no CarPlay key in the entitlements
file at all, and **hand-signing the entitlement in afterwards with
`codesign --entitlements` makes SpringBoard refuse to launch the app outright**
(`SBMainWorkspace` denial) — so do not try to add it that way. What was NEVER
tested is whether the SCENE would connect with the key absent; only the icon
was observed in that state. Treat "the Simulator needs no entitlement" as
unproven, and just keep the key in `Runner.entitlements`, which is where it
now lives anyway.

**It has now been DRIVEN in the CarPlay Simulator** (2026-09-10), signed in
against production data. Confirmed working: the scene connects with
`FlutterSceneDelegate` already owning a window scene (the plan's one genuine
unknown), the tab bar installs as the root, rows and headers render, and the
signed-out empty state is correct. Five UI decisions came out of that session
— see *Decisions taken (owner, 2026-09-10)* below; they outrank the design
sections above wherever the two disagree.

Still behavioural and still open: the four ACTIONS (Directions, Start,
Complete, Call) have not been exercised and the App Lock question is
unanswered. **The TECHNICIAN view has never
been on a screen at all** — every drive was an admin snapshot — and decisions
22-23 changed it structurally, so it is the least-verified surface here.

Mockups — **the final design (revision 3, 2026-09-09):**
<https://claude.ai/code/artifact/27425c62-bc6d-42ac-9f48-9d5bd8b3e65b>
("Final" page: nine screens plus the spec note; "Explorations" page: the two
root screens that lost). The earlier round —
<https://claude.ai/code/artifact/90ed43fb-b5b2-48e8-b84d-df32dfcc7c00>
(root options A/B/C, then A with the two crew treatments) — is **superseded**:
it drew a leading time column that a CarPlay row cannot render, and its
single-list root lost to the tab bar. Its two decisions that survived (crew as
an avatar, title before address on line two) are restated below.

## Context

ES Pro is a Flutter + Firebase field-service scheduling app (iOS-only, App Store
only, iOS 18.0 floor). Technicians drive between customer job sites all day, and
today the only way to check the next job in the vehicle is to pick up the phone
— exactly the interaction CarPlay exists to remove.

This adds a native CarPlay interface showing the signed-in user their jobs
(a Today tab ranked around the drive, a Week tab for the next 7 days), a
details screen, and a hand-off to their navigation app for the job address. **No change to the phone app's UI, business
logic, Firestore rules, or Cloud Functions.** The one data change is a single
new field on the off-app snapshot the widget and Siri already share, so an admin
can tell whose job is whose — see the correction in Step 3.

---

## STEP 1 — Project analysis (done)

| Area | Finding |
|---|---|
| Architecture | Flutter 3.44 / Dart `^3.10.7`, Riverpod 3 (manual providers), feature-first `lib/features/*` |
| Calendar system | **ES Pro's own** Firestore `appointments` collection. `AppointmentRecord` (freezed) + `AppointmentDaySlice` for multi-day scoping |
| **EventKit** | **Zero usage.** No EventKit, no `device_calendar` plugin, no `NSCalendarsUsageDescription` |
| Existing Swift | `ios/Runner/AppDelegate.swift` (1.4 KB, the only app-target Swift file), plus two extensions: `ScheduleWidget` (WidgetKit + Live Activity) and `SiriIntents` (App Intents) |
| Platform channels | Exactly one: `net.vogas.scheduling/native_config` (Dart → Swift, Maps API key). **No Swift → Dart handler exists anywhere in `lib/`** |
| **UIScene** | **Already adopted.** `Info.plist` ships a `UIApplicationSceneManifest` with one `UIWindowSceneSessionRoleApplication` entry using Flutter's own `FlutterSceneDelegate`; `AppDelegate` conforms to `FlutterImplicitEngineDelegate` |
| Deployment target | iOS 18.0, all targets. `DEVELOPMENT_TEAM = H5XWLU87AX`, bundle `net.vogas.scheduling` |
| Dependency policy | **SPM only — there is no Podfile and never will be** (`ios/CLAUDE.md`) |
| App Group | `group.net.vogas.scheduling`, already on Runner + both extensions |
| Off-app data | `schedule_snapshot` (App Group key, schema **v3**, **today + 7 days**, role-aware) written by `ScheduleSnapshotService`, decoded by `ios/SiriIntents/ScheduleSnapshot.swift` |

### The decisive finding

`schedule_snapshot` **already carries exactly what a CarPlay calendar needs**, and
a Swift decoder for it already exists:

```swift
struct SnapshotAppointment {           // ios/SiriIntents/ScheduleSnapshot.swift
    let id: String
    let startMillis / endMillis: Double
    let clientName: String
    let title: String?
    let address: String
    let status: String
    let isAllDay / dayIndex / dayCount / isOvernight
}
struct ScheduleSnapshot { let days: [SnapshotDay]; var today: SnapshotDay? ... }
```

So the CarPlay scene needs **no Flutter engine, no Firestore and no network** to
render — that is what makes this safe to add to a shipping app. It needs one
added field (`crew`) for the admin case; everything else it draws is already
here.

---

## STEP 2 — Apple CarPlay compatibility

*(From Apple's CarPlay developer pages, the CarPlay Developer Guide, Apple
Frameworks Engineer replies on the developer forums, and the committed
`Info.plist` of shipping CarPlay apps. Research completed 2026-09-04; the four
items this plan first flagged as open are now settled — see **Confirmed limits**
below and **Remaining Mac checks** at the end.)*

### What Apple permits

**There is no "calendar" CarPlay category.** Apple's CarPlay program admits only
these app categories, each behind its own Apple-granted entitlement: audio,
video (parked), communication/VoIP, navigation, EV charging, fueling, parking,
public safety, quick food ordering, voice-based conversational, **driving task**,
and automaker. An app may hold **one** category.

**ES Pro fits the Driving Task category, and only that one.** Apple's definition
is that driving task apps "must enable tasks people need to do while driving",
and Apple's own published examples include *recording mileage, managing road
trips, and communicating with fleet systems*. A field-service dispatch app
showing a technician the job they are currently driving to, and handing that
address to their navigation app, is squarely that use case.

Entitlement: **`com.apple.developer.carplay-driving-task`** (iOS 16+).

### What Apple does not permit

- **A generic personal calendar on CarPlay.** Showing a driver their EventKit
  calendar — dentist appointments, birthdays, class schedules — is not a driving
  task. It is the "use cases people shouldn't do while driving" that Apple's
  guidelines explicitly tell you to omit from the CarPlay UI. Requesting an
  entitlement for it would very likely be refused, and shipping it under a
  driving-task grant is a review risk.
- **Mirroring the Flutter UI onto the car display.** Only Apple's templates.
- **Arbitrary depth.** Driving task apps are capped at a shallow template stack
  (2 pushed levels on current iOS; 3 on iOS 26.4+). The UI below is designed to
  the **2-level** limit so it works on the whole iOS 18+ fleet.
- **Text entry while driving.** No search field in the CarPlay UI.

### Consequence — the calendar-source decision

**CarPlay reads ES Pro's own job data and does NOT use EventKit.** Right on all
three axes:

1. **Policy** — a work-job list is a driving task; a personal calendar is not.
2. **Privacy** — no `NSCalendarsFullAccessUsageDescription`, no new permission
   prompt, no permission-denied/restricted state to handle, nothing new stored.
3. **Architecture** — ES Pro already has this data in the App Group. Adding
   EventKit would create a duplicate calendar system.

The brief's "Calendar Access" section (EventKit, permission denial, restricted
access) therefore **does not apply** and is deliberately not implemented. The
error handling it asks for is instead applied to the real failure modes: no
snapshot yet, signed out, stale data, no jobs, no address.

### Directions to a job — permitted

A non-navigation CarPlay app may hand an address to the user's navigation app.
The supported call is `MKMapItem.openInMaps(launchOptions:from:)` passing the
**CarPlay scene** so the map opens on the car display rather than the phone (or
`CPTemplateApplicationScene.open(_:)` with a `maps://` URL). This is the
sanctioned pattern, not a workaround. ES Pro stores addresses as **strings with
no coordinates**, so the address is geocoded on demand or passed as a query.

### Confirmed limits (research, 2026-09-04)

| | Finding |
|---|---|
| Entitlement | `com.apple.developer.carplay-driving-task`, min iOS 16 |
| Template depth | **2** on iOS 18–26.3, 3 on 26.4+. **The root counts**, so root list + one detail push sits exactly at the cap — always pass the completion handler to `pushTemplate`, which throws if it cannot add the template |
| `CPInformationTemplate` | **3 actions** max, **10 items** max. The design uses 3 and 5 |
| `CPListTemplate` | 500 items — **but some vehicles show only 12 rows total across all sections**, with no scrolling past it |
| `CPTabBarTemplate` | The root. Apple's template table lists the tab bar for Driving Task apps — **re-check that table once more before building**, since the whole root rests on it. Its child lists are root-level, so the detail push is still depth 2 |
| `CPListSection` header subtitle | iOS 15+ (`headerSubtitle:`), so it is free on the iOS 18 floor. It is what carries the countdown and the counts without spending a row |
| `CPListItem` | Exactly `text` + `detailText` + `image` + an accessory. **There is no leading time column** — the time is either in `text` or drawn into `image` (below) |
| `CPAlertTemplate` | Modal, does **not** count toward template depth. Used only for a failed write ("Couldn't update that job") |
| The three actions | **All permitted.** Jobber, a field-service app holding this same entitlement, ships Directions, a status write and a phone call today |
| `UIApplicationSupportsMultipleScenes` | **Keep it `false`** |

Two of these change the build:

**The 12-row vehicle cap is the real design risk.** It is why the root is a
Today / Week tab bar rather than one list: today's rows can never be crowded
out by the week (which is where an admin's list gets long), and inside Today
the ranking puts the row that matters first rather than relying on the driver
scrolling — a busy Thursday is longer than some cars will render. The list
must degrade rather than assume the tail is reachable.

**`UIApplicationSupportsMultipleScenes` stays `false`, and this is now
evidence-backed rather than a guess.** VLC for iOS (`91edec0fef`) flipped it to
`false` *after* its CarPlay scene existed, with the commit message "this fixes
#1916 while leaving external screens and CarPlay working"; Pocket Casts
(`eeb5d01327`) made the identical change. The key governs iPad multi-window, not
CarPlay. `true` would additionally assert that the app tolerates concurrent
window scenes sharing state, which Flutter's own docs say it does not fully
support. Note Apple's prose still reads "UIKit never creates more than one scene
for your app" — the reconciliation (the limit applies *within* the window-scene
role, not across roles) is inference, but committed plists from shipping apps
outrank prose guides, and every setup blog asserting `true` cites no source. One
placement gotcha: the key is a **sibling of** `UISceneConfigurations`, not nested
inside it.

### Approval gate — GRANTED 2026-09-09

**Apple has granted `com.apple.developer.carplay-driving-task` for
`net.vogas.scheduling`** (owner, 2026-09-09). This closes what this plan called
its single biggest risk. The table below is kept because the *signing* gate did
not close with it — see the note under it.

### Approval gate — the original risk analysis

| Stage | Needs Apple's grant? |
|---|---|
| Build + run in the **CarPlay Simulator** (Xcode → I/O → External Displays → CarPlay) | **No** — a locally-added entitlement key is enough |
| Run on a **physical iPhone / real head unit** | **Yes** — the provisioning profile must carry the entitlement |
| **TestFlight / App Store** | **Yes** |

Apple grants the entitlement by review, via the request form at
`developer.apple.com/contact/carplay`. Turnaround is reported as days to months,
and refusal is possible. **Nothing about the phone app changes if the request is
refused** — the CarPlay code simply never activates.

> **Do not commit `com.apple.developer.carplay-driving-task` into
> `ios/Runner/Runner.entitlements` until the PROVISIONING PROFILE carries it.**
> The grant is not the gate — the profile is. An entitlement the profile lacks
> fails code signing, which would break every normal App Store build of ES Pro.
> Apple granting it (2026-09-09) does not by itself put it in the profile: the
> capability has to be enabled on the App ID in the Developer portal and the
> profiles regenerated first. Order is: portal capability → refresh profiles →
> move the key. See the gating scheme in Step 3.

### Manual step for the owner — DONE

The entitlement request was submitted and **granted (2026-09-09)**. Nothing
remains here. What remains is the portal/profile step recorded under the
approval gate above, which the owner had not done at the time of writing.

---

## STEP 3 — Implementation plan

### Decisions taken (owner, 2026-09-04)

1. **Build now, request the entitlement in parallel.** Full implementation,
   verified in the CarPlay Simulator; the entitlement key stays out of the
   committed release entitlements until Apple grants it.
2. ~~**One root list with day sections**~~ — **superseded 2026-09-09 by
   decision 9** (Today / Week tab bar). It was chosen over a *two-entry home
   screen*, which cost a push; a tab bar costs none, so the objection does not
   apply to it.
3. **Three actions on the details screen: Directions, job status, call client.**
4. **CarPlay shows exactly what the shared snapshot holds**, matching Siri: an
   employee sees their own jobs, an admin sees the whole business schedule.
5. **Crew is shown as an avatar (mockup A1)** — initials on the employee's own
   stored colour, a ring on the viewer's own jobs, `+N` for a multi-crew job.
6. **The row's second line is `title · address`**, title first. Where a job has
   no title the address moves up and takes the line.
7. **Status buttons stay "Start job" / "Mark complete"** — NOT the
   "On my way" / "Arrived" pair Apple's approved field-service apps use. Asked
   and answered; see below.
8. **Crew names may go into the shared snapshot.** A1 needs them, and the
   privacy consequence was put to the owner explicitly before it was accepted.

### Decisions taken (owner, 2026-09-09 — the final design)

9. **The root is a `CPTabBarTemplate` with two tabs, Today and Week.** Today
   is the default tab. The detail is the one push, so the stack sits at the
   2-level cap exactly as before.
10. **The Today tab is ranked around the drive, not the clock**: a **Now**
    section (jobs `in_progress` — one row for a technician, one row per
    technician on site for an admin), then **Next** (the single earliest job
    nobody has started, whether scheduled or overdue), then **Later today**
    (the remaining open jobs). Done and cancelled jobs are omitted and counted
    in the subtitle. The Week tab is the next 7 days, one section per day,
    today excluded.
11. **Section headers carry a subtitle** — "Starts in 18 min", "Overdue by
    57 min", "Started 10:04 AM", "4 more jobs · 1 done", "Friday 11 September ·
    3 jobs". Because two of those are wall-clock text, the visible template is
    rebuilt on a 60 s main-queue timer while the scene is connected, on top of
    the snapshot-change rebuild. **Superseded in FORM by decision 19** — the
    subtitle is now appended to the header on one line, not a second line.
12. **Both roles see job state on the row** — *Overdue* (amber) and *In
    progress* (green) — as the trailing accessory image. The technician's
    time tile is tinted the same colour; the admin's avatar is not, because the
    avatar owns that slot. **Half-superseded by decision 22** — the tile is
    gone, so the accessory is the technician's only state marker.
13. **Mark complete hands the driver the next job.** The job leaves the list
    the moment it is done, so the detail is popped to the root and a
    `CPAlertTemplate` names the next job with a *Directions* action and a
    *Done* action. *Start job* needs no confirmation.
    **REVERSED by decision 18 (2026-09-10) — the alert is gone.**
14. **Empty states use the template's own empty view**, and the Today one
    names the next job ("No jobs today" / "Next: Monday 8:00, Lachance").
    Decision 2's non-selectable "No jobs" row is gone with it.
15. **Every CarPlay connect refreshes the data.** No stale-schedule banner:
    the answer to staleness is that connecting the phone pulls a fresh
    snapshot, every time. This upgrades the method channel from an
    optimisation to a **requirement** — see *Two paths* under Architecture for
    what that means when CarPlay launches the app itself. The residual case
    (no network at connect time) shows the last written snapshot with nothing
    said, accepted as-is.
16. **An admin sees the whole business's schedule, and Next is
    business-wide** — the earliest job nobody has started, whoever it is
    assigned to. Confirms decision 4 for the ranking: the admin's CarPlay is
    the dispatcher's view, not the driver's.

### Decisions taken (owner, 2026-09-10 — after the first drive on the Simulator)

These came out of looking at the running CarPlay screen, so they outrank the
design above wherever the two disagree.

17. **Times are 12-hour, in both locales.** `CarPlayStrings.time` is the single
    formatter, so this moved every surface at once. The AM/PM symbols are
    **pinned** to `AM`/`PM`: `en_CA` otherwise renders `a.m.` with periods,
    which is wrong on a car display. Reverses the 24-hour choice the original
    plan made to keep the ~44 pt time tile legible. That tension is moot now:
    decision 22 deleted the tile and moved the time into the row text, where
    it renders at full size.
18. **No confirmation screen after Mark complete.** The write pops straight to
    the root list. The cost is real and was accepted: the hand-off alert was
    also how a driver got *Directions to the next job* in one tap, and that is
    now a manual pick from the list.
19. **Section headers use the PLAIN `CPListSection` initializer.** The rich one
    (`headerSubtitle:`/`headerImage:`/`headerButton:`) renders a **floating**
    header that a scrolling row card slides under and shows through — legible
    as a bug on the Week tab, where the day heading sat on top of the first
    row. Subtitle is appended to the header instead: "Tomorrow · Friday 11
    September · 4 jobs". Applies to Today's headers too, since one helper
    builds both.
20. **The detail screen is three rows, not five.** When / Where / Crew.
    *Status* went because the row accessory already carries it, and *Job*
    because the job title now rides in the template TITLE beside the client
    ("Tremblay · Réparation de fuite"). `.twoColumn` was tried first and is
    **worse** — it does not remove anything, it halves the width of the same
    rows on a 400x240 display. `CPInformationTemplate` offers only `.leading`
    and `.twoColumn`, so row COUNT is the only real lever.
21. **The When row never restates a time its own range shows.** A job an hour
    or more out read "Tomorrow, 7:00 AM – 8:00 AM · Starts at 7:00 AM". The
    absolute-time tail is dropped when a range is displayed; "Starts in 18
    min", "Due now" and "Overdue by 57 min" all stay, and an all-day block
    keeps its tail because it has no range. Pinned by
    `testWhenRowDropsAStartTimeTheRangeAlreadyShows`.

22. **The technician row is the admin row without the avatar.** Both roles
    lead line one with the time; the technician's image slot is now EMPTY.
    The time tile is deleted (`CarPlayImages.timeTile`, and the `"24 h"`
    `allDayTile` label with it). It existed to put the time somewhere, and
    12-hour time made it cramped at ~44 pt — moving the time into the text
    fixes the legibility and the duplication at once. Cost: a technician loses
    the tinted tile, so the accessory glyph is their only state marker.
    **Unverified — the technician view has never been on a screen.**
23. **Nothing shows a clock time for an all-day block.** Its start is
    midnight, so a time there is noise at best and wrong at worst. Three
    surfaces were audited and two were leaking: the detail's When row said
    "Tuesday, all day · Starts at 12:00 AM", and the Now header said "Started
    12:00 AM" for one in progress. `startedAt` takes the appointment and
    returns `String?` now, so the call site cannot forget. The row title and
    the Today empty state were already correct.

### The row, precisely (corrected 2026-09-09)

A `CPListItem` is exactly `text` + `detailText` + `image` + one accessory.
**There is no leading time column** — the first two mockup rounds drew one, and
the template cannot render it. So the time goes where the slot allows:

```
admin        [MC]  8:00  Tremblay                              ›
                   Réparation de fuite · 142 Rue Principale

technician   [8:00] Tremblay                                   ›
                    Réparation de fuite · 142 Rue Principale

with state   [9:15] Roy                          Overdue  (⏱)
             amber  Inspection annuelle · 3100 Boulevard Laurier
```

- **Image slot.** Admin: the crew avatar (initials on the employee's stored
  colour, dark-lifted in dark appearance, a white ring on the viewer's own
  jobs, `+N` for a multi-crew job) — A1, unchanged. Technician: **empty**
  (decision 22). It used to hold a time tile; the time moved into line one,
  and a tile repeating it would be the duplication decision 21 removed.
- **Line one, BOTH roles.** The time then the client, in one string with a
  two-space gap (`"8:00 AM  Tremblay"`) — the time cannot be styled
  separately. **An all-day block omits the time** and leads with the client,
  since its start is midnight (decision 23).
- **Line two.** Job title first, then ` · ` and the address, which truncates
  from the right — losing "Québec" costs nothing. Title is optional in ES Pro
  (filled from a job template, often empty on an ordinary visit), so an empty
  one is not rendered and the address takes the line.
- **Accessory.** The disclosure chevron, or — for an overdue or in-progress
  job — a rendered image carrying the word and a glyph (`"Overdue"` + clock,
  `"In progress"` + play). If a head unit renders the accessory too small for
  the word, fall back to the glyph alone; the tinted tile and the section it
  sits in still say the same thing. State comes from `displayStatusAt(now)`,
  the single owner of the ladder. **It is now the ONLY state marker a
  technician gets**, since decision 22 removed the tinted tile.
- **One thing to check on hardware**: where the row text truncates. The tile's
  ~44 pt fitting problem is gone with the tile.

### The snapshot MUST gain a crew field — correcting this plan

> **The first draft of this plan said the snapshot schema would not change.**
> That was written before the admin-visibility question was asked, and it was
> wrong. Both places that claimed it have been corrected; this section is the
> one that governs.

`schedule_snapshot` v3 carries no assignee at all — Siri never had to name one,
and an employee's copy is only ever their own jobs. An admin's copy is
business-wide, so without this every row is indistinguishable in the one respect
that matters. Showing it needs:

- `lib/features/siri/domain/schedule_snapshot.dart` — `scheduleSnapshotVersion`
  **3 → 4**, and `_appointment()` emits `crew`.
- `ios/SiriIntents/ScheduleSnapshot.swift` — decode `crew` as **optional**, and
  accept `version` **3 or 4**. Accepting both is not politeness: the on-disk
  snapshot is still v3 until the app next runs after an update, and a strict
  v4 gate would make **Siri** answer "no appointments" in that window.

Shape — a list of objects, not two positional arrays:

```dart
'crew': [ {'n': 'Marc Cloutier', 'c': 4286578816}, … ]
```

Two rules on building it. `employeeIds` and `employeeNames` are paired
**positionally**, so resolve each name through `assigneeNameAt` against the
**raw** `employeeIds` — `toIdList` filters, which shifts the arrays out of step
and names the wrong person. And `c` is the **stored light-theme ARGB**; the car
does the dark lift, mirroring `crewColorOf`. Never store a lifted colour.

**Emit `crew` only when `role == 'admin'`.** An employee's jobs are all theirs,
so the field would be noise on the row and would put colleagues' names on a
device that has no use for them.

**Colour needs a roster join, and it is free in practice.** Colour lives on
`EmployeeRecord.colorValue`, not on the appointment, so `scheduleSnapshotProvider`
watches `allUsersStreamProvider` — but only on the admin branch. That provider
is a plain `StreamProvider` (not `autoDispose`) and the calendar tab's
`CrewFilterButton` already watches it for an admin, and the calendar tab is
always mounted in the hub's `IndexedStack`. So this opens **no additional
Firestore listener** for the role that uses it. Confirm that still holds before
building; if it ever changes, fall back to names only (mockup A2).

**No `functions/` change.** The server mirrors the *widget* payload
(`widget_payload_utils.js`), not this one — `buildScheduleSnapshot` and the Swift
decoder are the only hand-mirrored pair here.

**One privacy note to make deliberately.** This is the first time the shared file
names a person. It is readable while the phone is locked, which is why it
carries no notes, phone numbers or photos. A colleague's name is a long way from
those and an admin sees it throughout the app — but record it as a decision.

### Architecture

```
Flutter / Dart  ── unchanged business logic, models, providers ──┐
                                                                 │
   AppSyncListeners._snapshotSync  ──►  ScheduleSnapshotService  │
                                             │ writes                writes
                                             ▼
                        App Group  group.net.vogas.scheduling
                             key  schedule_snapshot  (v3, today+7d)
                                             │ reads
                                             ▼
   Swift  CarPlayScheduleStore ──► CarPlayTemplateBuilder ──► CPTemplates
                                             ▲
                                             │  freshness ping / connect poke
   MethodChannel  net.vogas.scheduling/carplay  ◄──►  CarPlayBridge (Dart)
```

**Two paths, deliberately.** The App Group is the *data* path and always works —
including when CarPlay launches the app with no phone window. The method
channel is the *freshness* path: a snapshot rewrite pokes CarPlay to re-read,
and a CarPlay connect asks Dart for a fresh snapshot. **If the channel is
unavailable, CarPlay still renders from the last written snapshot.** That is
the "Flutter communication fails → fail gracefully" requirement, met by design
rather than by a catch block.

**Refresh-on-connect is a requirement, not an optimisation (decision 15).**
The first draft called the channel "a pure optimisation" because the engine
might not exist when CarPlay launches the app with no phone window. The owner
wants fresh data on every connect, so the build has to make the Dart side run
on connect, not hope it is already running:

1. **Find out whether the implicit engine already starts on a CarPlay-only
   launch.** Under scene lifecycle, Flutter's app delegate may initialise the
   implicit engine in `didFinishLaunching` regardless of whether a window
   scene ever appears — `didInitializeImplicitFlutterEngine(_:)` fires either
   way — in which case `main()` runs, `AppSyncListeners` register, and the
   snapshot is rewritten from the cached/live Firestore data with no extra
   work. This is the first thing the first Simulator run must establish, with
   the app killed and CarPlay doing the launch.
2. **If it does not, the scene delegate starts a headless engine on
   connect** (`FlutterEngine(name:).run()` with no view controller, the same
   shape a background isolate uses), registers the channels on its messenger,
   and lets `main()` reach the snapshot sync. It is torn down on disconnect.
   Two things to keep in view: `main()` must tolerate running with no window
   (the splash and routing are behind `runApp`, and a headless engine has
   nowhere to attach a view — verify nothing in `main()` before `runApp`
   assumes a screen), and App Lock's lifecycle gates must not be tricked into
   treating the headless engine as a foregrounded app.

Either way `carPlayConnected` stays the trigger, and the store keeps rendering
the last snapshot while the refresh is in flight — the driver never waits on a
network read to see the list.

A consequence worth having: with the engine alive on every connect, the two
engine-dependent buttons (status, Call) are present on every normal drive.
Their absence rule stays as the fallback for the case where the engine could
not start, not the expected morning.

### CarPlay UI (final design, 2026-09-09 — designed to the 2-level driving-task depth limit)

```
ROOT  CPTabBarTemplate
 ├─ TODAY  CPListTemplate                       (technician, 10:12)
 │    Now · Started 10:04 AM
 │      10:00 AM  Gagnon                          In progress (▶)
 │                Chauffe-eau · 8 Avenue des Pins
 │    Next · Overdue by 57 min
 │      9:15 AM  Roy                              Overdue (⏱)
 │               Inspection annuelle · 3100 Boulevard Laurier
 │    Later today · 2 more jobs · 1 done
 │      1:30 PM  Pelletier                                     ›
 │               1290 Rue Saint-Jean
 │      Côté                                                   ›   (all day)
 │               Chauffe-eau · 77 Rue Saint-Paul
 └─ WEEK   CPListTemplate
      Tomorrow · Friday 11 September · 1 job
        1:00 PM  Bélanger  …
      Monday · 14 September · 2 jobs
        …

(An ADMIN sees the same rows with a crew avatar in the leading image slot.)
                              │  tap a row
                              ▼
PUSH  CPInformationTemplate  "Tremblay · Réparation de fuite"
      When     Today, 8:00 AM – 9:00 AM · Starts in 18 min
      Where    142 Rue Principale, Québec
      Crew     [LB] Luc Bergeron                 (admin only)
      [ Directions ]  [ Start job ]  [ Call ]
                              │  Mark complete
                              ▼
      writes, then pops to the root list. No confirmation screen.
```

**Today tab — the ranking.** Three sections, each present only when
non-empty:

| Section | Contents | Header subtitle |
|---|---|---|
| **Now** | every job whose stored `status` is `in_progress`, by start time. One row for a technician; one per technician on site for an admin | "Started 10:04 AM" (one row) or "2 on site" |
| **Next** | the single earliest open job nobody has started (`displayStatusAt` scheduled **or** overdue). For an admin that is business-wide, whoever it is assigned to (decision 16) | "Starts in 18 min" or "Overdue by 57 min" |
| **Later today** | the remaining open jobs today, by start time | "4 more jobs · 1 done" |

Done and cancelled jobs are omitted (cancelled already at snapshot build time)
and counted in the subtitle. Before the first job the tab is just Next + Later
today; with everything done it is the empty view. The Now/Next split moves
with the clock, so the store rebuilds the visible template every **60 s** on
the main queue while the scene is connected, as well as on every snapshot
change.

**Week tab.** Days 1–7 of the snapshot, one `CPListSection` per day, header
"Tomorrow" / weekday name **followed by** the date and job count on ONE line
("Tomorrow · Friday 11 September · 4 jobs"). Today is never on it.

**Rows** are the anatomy in *The row, precisely* above — time then client,
avatar for an admin and no image for a technician, title before address,
state as the accessory. Sorted strictly by start time
inside each section.

- **Empty views** use `emptyViewTitleVariants` / `emptyViewSubtitleVariants`
  on each list — never a dead row. Today: "No jobs today" / "Next: Monday
  8:00, Lachance". Week: "Nothing scheduled this week". Signed out / no
  snapshot, both tabs: "Sign in on your iPhone to see your schedule."
- **Detail rows** in the order a driver asks: When (with the countdown), Where,
  Crew (admin only). Three of the ten the template allows; nothing is padded.
  The job title rides in the template TITLE beside the client rather than a
  row of its own. Directions is the `.confirm`-style (tinted) button.
- **The chain.** A successful write of either status pops to the root list and
  presents nothing. There is no confirmation or hand-off screen.
- A job with no address omits the Where row **and** the Directions button.
- A job with no client name falls back to `title`, then to a generic label.
- **Role behaviour is inherited from the snapshot, not re-decided in Swift.** An
  employee's snapshot already contains only their own jobs; an admin's is
  business-wide, and CarPlay renders it as-is (owner call — same as Siri). Two
  consequences fall out for free: an admin's day sections can be long, so the
  builder keeps the existing per-day cap; and the snapshot already blanks the
  address of *other* people's personal blocks for an admin, so those rows land
  on the no-address path and correctly show neither a Where row nor a
  Directions button — no extra Swift logic. The builder does have to know the
  role for one thing: whether the image slot carries a crew avatar at all, and
  the snapshot already says which role it was built for.
- **No "Open on iPhone" button** — asking a driver to pick up the phone is the
  anti-pattern CarPlay exists to prevent.
- **No stale-schedule treatment, by decision 15.** Every connect refreshes,
  so a stale list is the no-network case only, and it shows the last snapshot
  with nothing said.

`CPInformationTemplate` allows at most **three** actions, so Directions + status
+ Call is exactly the budget — there is no room for a fourth, which is another
reason "Open on iPhone" is out.

### The three actions — and why Call does NOT widen the shared payload

**Directions** works from the snapshot alone, so it is always available.

**Job status** is a Firestore write over the method channel, reusing the existing
`AppointmentsRepository.updateAppointmentStatus` — the same call the phone app
makes. The assignee `allow update` disjuncts in `firestore.rules` already permit
**both** values from an assignee, so **no rules change is needed**:

- `status == 'in_progress'`, only from an open status (`firestore.rules:467-474`)
- `status == 'done'`, only when not already cancelled (`:442-449`)

Both require `affectedKeys().hasOnly(['status','updatedAt'])`, which is exactly
what `updateAppointmentStatus` writes.

**One status button, not two — a deliberate divergence from the phone.** The
phone's `DetailsActionBar` offers *both* Start job and Mark as complete on a
pending job (mark-complete carries no clock gate by owner decision, 2026-08-17).
That is right on a phone and wrong in a car: it is also three actions before
Directions and Call, and `CPInformationTemplate` allows three total. CarPlay
therefore shows the **next step in the ladder only** — "Start job" while
`pending`, "Mark complete" while `in_progress`, nothing once terminal — which
both fits the budget and is the single-decision shape driving demands. The
condition mirrors the rules exactly, so CarPlay can never offer a tap Firestore
will reject.

The *button* keys off the stored `status`, never the display ladder, since
`overdue` is display-only and reading `.raw` on it throws by design. (A Status
*row* on the detail used to show the ladder's word; decision 20 removed it —
the row's own accessory already carries that state.)

Writes require the Flutter engine, so the button renders only when the bridge
reports connected.

**Call the client** takes the *same* route rather than the obvious one. Putting
`clientPhone` into `schedule_snapshot` would reopen a documented privacy
decision (the App Group is readable while the phone is locked, so the payload
deliberately carries no notes, phone numbers or photos). Since the status button
already requires a live engine, the phone number is instead **fetched on demand
over the same channel** — CarPlay asks Dart for it at tap time, Dart reads
`getAppointmentById(id)?.clientPhone`, Swift opens `tel:`. Nothing extra is ever
written to disk.

| | Store phone in snapshot | Fetch on demand (chosen) |
|---|---|---|
| Privacy rule | Reopens it | **Untouched** |
| Snapshot schema | v3 → v4 bump | **No change** |
| Hand-mirrored Swift decoder | Must change in lockstep | **No change** |
| Post-update gap (stale v3 on disk rejected by a v4 decoder, breaking Siri too) | Real, self-healing | **None** |
| Works with engine asleep | Yes | No — same as the status button |

Both engine-dependent buttons follow one rule: **if the bridge is not connected,
the button is absent** — never present-but-broken. That is the brief's "if
information is unavailable, do not display empty or broken fields", applied to
actions.

### Files to CREATE

**Swift — `ios/Runner/CarPlay/`** (Runner target, *not* a new extension; CarPlay
scenes must live in the app, which also avoids a new `PrivacyInfo.xcprivacy`):

| File | Purpose |
|---|---|
| `CarPlaySceneDelegate.swift` | `CPTemplateApplicationSceneDelegate`. Connect / disconnect / reconnect, root template install, teardown. Holds no strong reference that outlives the scene. |
| `CarPlayScheduleStore.swift` | Loads `ScheduleSnapshot`, exposes today + upcoming days, caches the decode, re-reads on connect / foreground / refresh ping. Owns the **60 s main-queue timer** that re-ranks Today while the scene is connected (invalidated on disconnect). |
| `CarPlayTemplateBuilder.swift` | **Pure** functions taking `now` as a parameter: snapshot → the two `CPListTemplate`s for the tab bar (the Now / Next / Later ranking, the Week day sections, every header subtitle); appointment → `CPInformationTemplate`. Pure so `RunnerTests` can cover ranking, grouping, ordering, the subtitles and every omit-the-empty-field rule without a car. |
| `CarPlayImages.swift` | The two rendered images: crew avatar (initials on the stored colour, dark lift, own-job ring, `+N`) and the state accessory (word + glyph). `UIGraphicsImageRenderer`, sized for the CarPlay image slot. The technician time tile was deleted by decision 22. |
| `CarPlayStrings.swift` | EN/FR display strings + date/time formatters, mirroring `ios/SiriIntents/SiriStrings.swift` (same `Locale`-prefix idiom, same "both localizations side by side" rationale). |
| `CarPlayBridge.swift` | Registers the `net.vogas.scheduling/carplay` channel on the implicit engine's messenger; tracks whether Dart is reachable (which gates the two engine-dependent buttons); posts a `NotificationCenter` refresh in-process. |

**Dart:**

| File | Purpose |
|---|---|
| `lib/core/app/carplay_bridge.dart` | `CarPlayBridge` — the app's **first** Swift → Dart method-call handler. Built on the `AppointmentLinkOpener` pattern: `start()`/`dispose()` from `initState`/`dispose`, injected `bool Function() isIosPlatform`, providers read up front (never `ref.read` after an `await` — Riverpod 3 throws on an unmounted consumer), every failure caught and logged under tag `CARPLAY` so nothing escapes to `runZonedGuarded` as a fatal. |

### Channel contract — `net.vogas.scheduling/carplay`

**Swift → Dart** (Dart sets the handler; each returns a value or a `FlutterError`
Swift turns into a "couldn't do that" alert, never a crash):

| Method | Args | Returns |
|---|---|---|
| `carPlayConnected` | — | `null`; asks Dart to refresh the snapshot now |
| `setAppointmentStatus` | `{id, status}` | `bool` — via the existing `updateAppointmentStatus` |
| `dialableNumberFor` | `{id}` | `String?` — the finished `tel:` URI, read on demand, never persisted |

**Dart → Swift:**

| Method | Args | Effect |
|---|---|---|
| `snapshotChanged` | — | Swift re-reads the App Group and rebuilds the visible template |

Dart is the *responder* on this channel, so `setMethodCallHandler` runs on the
root isolate and every handler is `async`-safe.

**`dialableNumberFor` returns a finished `tel:` URI, not a raw number, and that
is deliberate.** Phone numbers are stored FORMATTED — `(514) 555-1234` — and
`Uri` percent-encodes the brackets and space into a path some dialers reject.
`dialableUri(phone)` (`core/launchers/phone_call_launcher.dart`) is the pure,
tested owner of that stripping rule (digits only, keeping a leading `+`, falling
back to the raw text when there is nothing to strip). Returning the built URI
keeps that rule in ONE place instead of hand-mirroring it into Swift, where a
second spelling would silently fail to dial some numbers.

It is fetched **once when the detail screen is built**, not on tap, so the same
answer decides both whether the Call button renders and what it opens — a button
that appears and then turns out to have no number is the "present-but-broken"
shape this plan rejects everywhere else. Swift opens it with
`CPTemplateApplicationScene.open(_:)` so the call lands on the car display.

Three cases where Call is correctly absent: the engine is asleep (same condition
as the status button), the client has no number on file, and a personal block
(both save paths write `clientPhone` as an empty string on those by design). `clientPhoneFor` returning
`null` (no number on file) means the Call button is simply not rendered.

**Tests:**

| File | Purpose |
|---|---|
| `test/core/app/carplay_bridge_test.dart` | Mocks the channel via `TestDefaultBinaryMessengerBinding` — the idiom already used in `test/core/launchers/external_uri_launcher_test.dart`. Covers: each of the three inbound methods, an unknown method returning `notImplemented` rather than throwing, a repository throw surfacing as a handled failure and a logged `CARPLAY` warn (not an escape to the zone handler), `clientPhoneFor` returning `null` for a job with no number, non-iOS no-op, and `dispose()` clearing the handler. |
| `ios/RunnerTests/CarPlayTemplateBuilderTests.swift` | Pure builder tests (Mac-gated): the Today ranking (Now holds every `in_progress` job; Next is exactly one job and is the overdue one when there is one; Later is the rest; a section is absent when empty), the header subtitles at a fixed `now` ("Starts in 18 min", "Overdue by 57 min", the done count), Week day grouping and ordering with today excluded, terminal jobs omitted, address-less job omits both the Where row and the Directions button, client-name → title → generic fallback, empty and signed-out variants on both tabs, the connected/not-connected action sets, the When row dropping a start time its own range already shows, every all-day surface omitting a midnight time, and the avatar drawn only for an admin. |

### Files to MODIFY

| File | Change |
|---|---|
| `ios/Runner/Info.plist` | Add a `CPTemplateApplicationSceneSessionRoleApplication` array **beside** the existing `UIWindowSceneSessionRoleApplication` entry — leave the `flutter` / `FlutterSceneDelegate` entry byte-for-byte untouched (see below). |
| `ios/Runner/AppDelegate.swift` | Capture the messenger in `didInitializeImplicitFlutterEngine(_:)` into a shared holder and register both channels from there. This also **fixes an existing latent bug**: `registerNativeConfigChannel()` currently resolves the messenger through `window?.rootViewController`, which under scene lifecycle can silently `NSLog("Native config channel unavailable")` and leave the live map blank. |
| `ios/Runner.xcodeproj/project.pbxproj` | `ios/Runner/` is a plain `PBXGroup`, so each of the 6 new Swift files needs hand-adding in **four** sections (`PBXFileReference`, `PBXBuildFile`, group children, `PBXSourcesBuildPhase`). Plus one `PBXBuildFile` + Sources entry giving `ios/SiriIntents/ScheduleSnapshot.swift` **Runner target membership** — the file does not move, so the SiriIntents wiring is untouched. |
| `lib/core/app/app_sync_listeners.dart` | **Built differently, deliberately.** A separate `_carPlaySync()` listener was written first and then REMOVED: two `_fireAndForget` listeners on the same emission fire in the same synchronous turn, so the ping raced ahead of `writeSnapshot`'s App Group write and the car re-read the OLD file every time — deterministically, with sign-out leaving the ex-user's client names on the car screen. The rewrite and the ping are now ONE chain inside `_snapshotSync`, so "landed" is structural rather than hoped for. Write and clear take the same path. Don't re-split them. |
| `lib/main.dart` | Construct/`start()` `CarPlayBridge` in `initState` beside `AppointmentLinkOpener`; `dispose()` it. |
| `ios/CLAUDE.md` | Record the scene-manifest change, the entitlement gate, and why CarPlay reads the App Group rather than the engine. |
| `.claude/rules/notifications.md` | CarPlay is a fourth off-app surface; document it beside the widget and Siri snapshot. |
| `docs/ARCHITECTURE.md`, `CHANGELOG.md` | Feature entry. |

### The one high-risk edit, spelled out

`Info.plist` is the change that could break the phone app, so it is purely
additive — a second key inside the existing `UISceneConfigurations` dict:

```xml
<key>UISceneConfigurations</key>
<dict>
    <key>UIWindowSceneSessionRoleApplication</key>
    <array>… existing flutter / FlutterSceneDelegate entry, UNCHANGED …</array>

    <key>CPTemplateApplicationSceneSessionRoleApplication</key>   <!-- NEW -->
    <array>
        <dict>
            <key>UISceneClassName</key>
            <string>CPTemplateApplicationScene</string>
            <key>UISceneConfigurationName</key>
            <string>carplay</string>
            <key>UISceneDelegateClassName</key>
            <string>$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate</string>
        </dict>
    </array>
</dict>
```

The `$(PRODUCT_MODULE_NAME).` prefix is required — a bare Swift class name does
not resolve from a plist, and the failure mode is a CarPlay scene that silently
never connects. `UIApplicationSupportsMultipleScenes` **stays `false`** (see
Confirmed limits) and remains a sibling of `UISceneConfigurations`.

### Explicitly NOT changed

`pubspec.yaml` (**no new Flutter dependency** — `flutter_carplay` is CocoaPods-only
and would force a Podfile into this SPM-only project, violating `ios/CLAUDE.md`);
the appointment model, repository or providers; **`firestore.rules`** (the status
write reuses `updateAppointmentStatus`, already covered by the assignee
disjunct — and `appointment_employee_update_rules_test.dart` pins the disjunct
*count* at three, so adding one would be a deliberate act, not a side effect);
the ARBs (CarPlay strings live in Swift, matching the `SiriStrings.swift`
precedent); `UIBackgroundModes`; any permission string; `functions/` entirely —
**this feature needs no deploy**.

**The snapshot schema IS changed** (v3 → v4, for `crew`) — see the correction
above. An earlier draft of this plan listed it here as unchanged; that was
written before the admin-visibility question and is wrong.

### Entitlement gating — RETIRED 2026-09-10, scheme collapsed

This slot used to describe a two-file scheme: `com.apple.developer.carplay-driving-task`
was kept OUT of `Runner.entitlements`, and `ios/Runner/RunnerCarPlay.entitlements`
carried it for local work only, so a normal build signed exactly as it did before.

**That scheme is gone and the extra file is deleted.** The trigger it was
waiting on happened: the capability was enabled on the App ID, Xcode
regenerated the profiles, a device build signed against a profile carrying the
entitlement, and the key moved into `Runner.entitlements`. All three Runner
build configurations point at that one file again.

Two corrections this leaves behind, both worth keeping because following the
old text now would waste an afternoon:

- **Under AUTOMATIC signing the prescribed order cannot be followed.** This
  document said portal capability -> refresh profiles -> move the key. Xcode
  only requests an entitlement it can already see in the entitlements file, so
  the profile cannot carry CarPlay before the key moves. The working order is:
  enable the capability on the App ID, move the key, then build to a device
  with `-allowProvisioningUpdates` and let Xcode mint the profile.
- **Do NOT hand-sign the entitlement for Simulator work.** Running
  `codesign --force --sign - --entitlements ...` over a built simulator app to
  add the CarPlay key makes SpringBoard refuse the launch outright
  (`SBMainWorkspace` denial); this was isolated to that one key, with
  app-groups and get-task-allow launching fine on their own, and a real Apple
  Development identity denied too. The supported path is the entitlements FILE
  the target builds against — see the simulator note in the status header for
  exactly what that does and does not prove.

Still open: **distribution** signing is unproven — the Mac this ran on holds
only an Apple Development certificate, so the App Store profile has never been
minted with the entitlement. Archive once before shipping. (Closed 2026-09-13:
the shipped 1.61.0+90 build proves it — see the status header.)

---

## STEP 4–6 — Build, review, test

Implementation order (each step leaves the tree building and shippable):

1. Swift template builder + strings + store, with `RunnerTests` coverage. No
   wiring — nothing runs yet.
2. Scene delegate + `Info.plist` scene role + pbxproj wiring. CarPlay renders in
   the Simulator from whatever snapshot is on disk.
3. `CarPlayBridge` (both directions) + the snapshot-write→ping chain in
   `AppSyncListeners._snapshotSync` + Dart
   tests. Live refresh, and the two engine-dependent buttons appear.
4. Self-review pass (CarPlay/Flutter/iOS lifecycle, retain cycles between the
   scene delegate and the interface controller, threading — every CarPlay
   callback on the main queue, null safety, Apple guideline conformance), then
   `flutter analyze` (baseline: `No issues found!`) and the full `flutter test`
   suite.

### Verification

**On the Windows box (what can be proved there):**
- `flutter analyze` → `No issues found!`
- `flutter test` → full suite green, including the new `carplay_bridge_test.dart`
  and the extended `app_sync_listeners_test.dart`. Existing counts must not drop.

**On the Mac (Xcode; everything native is Mac-gated):**
- Build Runner; run `RunnerTests` for the template builder.
- Simulator → **I/O → External Displays → CarPlay**, then: first connect ·
  reconnect · app already running when CarPlay connects · app launched *by*
  CarPlay · disconnect while running · phone app used while CarPlay is active ·
  no jobs · many jobs · jobs with and without an address · signed out · stale
  snapshot · **the tab bar installs as the root and a row push from either tab
  succeeds** (the depth assumption) · **Today re-ranks on its own**: leave the
  Simulator open across a job's start time and watch it move from Later today
  to Next, and the countdown tick down at the 60 s cadence · avatar rows on an
  admin snapshot, no image on a technician one · an overdue job's accessory,
  an in-progress job's accessory.
- Action-specific: Directions opens the nav app **on the car display**, not the
  phone · "Start job" writes and the row moves into Now with no alert · "Mark
  complete" writes and pops to the root with NO confirmation screen
  (decision 18) · Call places the call ·
  **launch from CarPlay with the phone app never opened and confirm the list
  still renders while Start/Call are correctly absent**, then open the phone
  app and confirm both appear · a job whose client has no number shows no Call
  button.
- **Two items that must be settled on hardware, not assumed:**
  1. **`UIApplicationSupportsMultipleScenes` stays `false`** — settled by
     research, but confirm the CarPlay scene actually connects on the first
     Simulator run, since `FlutterSceneDelegate` coexisting with a second scene
     role is the one thing no source could settle.
  2. **App Lock.** `lib/core/security/app_lock.dart` locks on `inactive`,
     `paused` **and** `hidden`, and releases only through biometrics. Verify
     that (a) plugging into CarPlay does not trap the driver behind a Face ID
     prompt, and (b) more importantly, backgrounding the phone while CarPlay is
     connected still engages the lock — a second scene keeping the app "active"
     would be a real security regression, not a cosmetic one.
- Physical head unit: unblocked by the 2026-09-09 grant, but still needs the
  App ID capability enabled and the provisioning profiles regenerated first.

---

## Known limitations (stated up front)

- **Freshness.** Every connect refreshes (decision 15), so CarPlay is as fresh
  as the last connect. Between connects it renders the last snapshot the app
  wrote; a schedule change while the car is already connected reaches it only
  if the phone app is alive to hear the Firestore update, and a connect with no
  network shows the previous snapshot with nothing said.
- **No coordinates.** Appointments store an address string only, so Directions
  hands a query to the navigation app rather than a pinned coordinate.
- **7-day horizon**, inherited from the existing snapshot window.
- **Start/Complete and Call need the phone app's engine alive.** Reading the
  schedule and getting Directions always work; the two write/lookup actions are
  hidden only when the engine could not be started on connect (decision 15
  makes starting it the normal path). This is the deliberate cost of not
  persisting client phone numbers to a lock-screen-readable container.
- **No notes on the CarPlay screen**, deliberately: the App Group is readable
  while the phone is locked, and the existing snapshot privacy rule excludes
  notes, phone numbers and photos. The brief's "notes if appropriate and
  permitted" resolves to *not permitted here*.
- **Apple approval was granted 2026-09-09**, so device, TestFlight and App
  Store use are no longer blocked on review. They are still blocked on the
  portal/profile step, which is outside this repo's control.

## Remaining Mac checks

Everything documentable is settled above. These four cannot be resolved from
documentation and are on-device checks, not blockers on starting:

| Item | Why it needs hardware |
|---|---|
| Runtime section and row counts on a real head unit | The 12-row cap is vehicle-specific; only a car (or a specific simulator profile) shows where it truncates — and with the tab bar it is the Week tab, not Today, that meets it first |
| Where row text truncates | Depends on the head unit's width and the system font |
| The state accessory at the unit's real image size | The slot is ~44 pt on some units and the word may not fit — the glyph-only fallback exists for this. **The whole TECHNICIAN view is untested: every drive so far was an ADMIN snapshot, and decisions 22-23 changed that view structurally (no image, time in the row text)** |
| The tab bar on a Driving Task grant | Apple's template table lists it; confirm in the guide before Step 1 and again on the first Simulator run, since the root rests on it |
| `openInMaps(launchOptions:from:)` landing on the **car** display, not the phone | Jobber ships it, so low risk — but worth seeing once |
| **`FlutterSceneDelegate` coexisting with a second scene role** | Could not be settled from any source. This is the one genuine unknown in the plan, and the first Simulator run answers it |
| **Whether the implicit engine starts on a CarPlay-only launch** | Decides which branch of decision 15's refresh-on-connect gets built (nothing extra, or a headless engine started by the scene delegate). Kill the app, connect CarPlay, check for `didInitializeImplicitFlutterEngine` |

Plus the two behavioural checks already listed under Verification: whether App
Lock still engages when the phone is backgrounded with CarPlay connected, and
whether the CarPlay scene connects with `UIApplicationSupportsMultipleScenes`
left at `false`.

## Closed: the status verbs

Apple's approved field-service CarPlay apps use **"On my way" / "Arrived"** —
status about the *drive* — rather than "Start job" / "Mark complete". ES Pro had
exactly that crew signal (`crewOnMyWay` / `crewRunningLate`) and it was removed
on 2026-09-03 by owner call, across rules, Dart, `functions/` and both ARBs.

**Owner call, 2026-09-04: keep Start job / Mark complete.** So the deleted crew
signal stays deleted — don't restore `crewOnMyWay`, `crewRunningLate`,
`crewStatusSignal` or the two admin push kinds from an older copy of any rule
file on the strength of this feature. The buttons write `in_progress` and
`done` through the existing `updateAppointmentStatus`, which the assignee
`allow update` disjuncts already permit, so this needs **no rules change, no new
write path and no deploy**.

The cost is stated rather than hidden: it is a marginally weaker story in the
entitlement request, since a job-status write is about the work rather than the
drive. Directions is what carries that argument, and it is the stronger half
anyway.

## Closed: crew names in the shared payload

The App Group file is readable while the phone is locked, which is why it
deliberately carries no notes, phone numbers or photos. A1 adds a colleague's
name and colour to it. **Owner call, 2026-09-04: accepted**, on the reading that
a name is a long way from those and an admin already sees it throughout the app.
Recorded here so it reads as a decision rather than something that leaked in
with a feature.

Two limits hold it in place and must not be relaxed casually: `crew` is emitted
**only for an admin's snapshot**, and it carries a name and a colour and nothing
else — no id, no phone, no email.
