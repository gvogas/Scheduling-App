# Siri App Intents — "How many appointments do I have today?"

> **CANCELLED 2026-10-09 (owner): not needed.** Phases 4-6 will not be built and the Phase 1-3 device pass is dropped. The six read intents built in Phases 1-3 are still in `ios/SiriIntents/` and in the shipped app.

**Status: design approved 2026-07-10; scope expanded 2026-07-19 to fold in the
former out-of-scope surfaces. Phases 1–3 are BUILT and none has had a device
pass — see [`2026-07-19-siri-app-intents-implementation.md`](./2026-07-19-siri-app-intents-implementation.md)
for current state. Phase 4 is specified but not started
([`2026-07-20-siri-phase4-write-actions.md`](./2026-07-20-siri-phase4-write-actions.md)),
and phases 5–6 are unscoped — which is why this doc is still active rather than
archived.**

Let users ask Siri about their schedule — and act on it — instead of opening the
app. Approved decisions: both roles (role-aware answers), iOS deployment target
bumped 15.0 → 16.0 (**superseded — the app went to 18.0 on 2026-07-19**; the
Live Activity Directions button's returnable `OpenURLIntent` is iOS 18+), App
Group snapshot as the *read* data source ("snapshot now, live later"), snapshot
written via the `home_widget` package.

The work is **phased** — each phase ships independently and every later phase is
additive over the snapshot/extension foundation laid in Phase 1:

| Phase | Scope | Buildable on this box? |
|---|---|---|
| **1 — Read, today/next** | The original 3 read-only intents (today count / today schedule / next appointment) over the App Group snapshot. | Dart yes; Swift on Mac |
| **2 — Date queries** | Tomorrow / arbitrary-date ("what's my schedule Friday?") over the same 7-day snapshot — no data change. | Dart yes; Swift on Mac |
| **3 — Multi-turn** | Conversational follow-ups ("and tomorrow?", "read me the third one"). | Swift on Mac |
| **4 — Write actions** | Booking / reschedule / cancel / status change by voice. **Requires auth + App Check inside the extension** (breaks the "no Firebase in extension" property — see Architecture). | Mostly Mac |
| **5 — Live data** | Direct Firestore read from Swift (keychain-shared auth + App Check) and silent-push snapshot refresh, replacing "answer from last snapshot". | Mostly Mac |
| **6 — Proactive & other surfaces** | Siri Suggestions / intent donations, interactive snippets, CarPlay, Spotlight indexing, Apple Watch, Action button. | Mac only |

**Android stays out** — Google Assistant App Actions have no equivalent
zero-setup voice surface, and Android is dev-harness-only per the
App-Store-only decision. There is no Android voice work, now or planned.

## User-facing behavior

All phrases ship in English and French (Apple requires the app name in the
phrase — "…in ES Pro" / "…dans ES Pro").

**Phase 1 — read, today/next:**

1. **"How many appointments do I have today in ES Pro?"** → "You have 4
   appointments today."
2. **"What's my schedule today in ES Pro?"** → reads the day's list: time +
   client name per visit.
3. **"What's my next appointment in ES Pro?"** → client name, start time, and
   address of the next upcoming job.

**Phase 2 — date queries** (same three shapes, any day in the 7-day window):

4. **"What's my schedule tomorrow / on Friday in ES Pro?"** → reads that day's
   list. Resolved against the day buckets already in the snapshot; out-of-window
   dates answer "I only have your schedule for the next 7 days."

**Phase 3 — multi-turn:** after any answer, a follow-up continues the session —
"and tomorrow?", "read me the third one", "how about next appointment?" — via
an App Intents conversation flow rather than a fresh top-level phrase.

**Phase 4 — write actions** (confirmed before commit; Siri reads the change
back for confirmation):

5. **"Cancel my next appointment in ES Pro"** → "Cancel your 2 PM at 14 Elm St?"
   → "Yes" → writes `status: cancelled`.
6. **"Mark my current job done in ES Pro"** → sets the in-progress visit to
   `done`.
7. **"Move my 3 o'clock to 4 in ES Pro"** → reschedules within the same day.
   (Booking a brand-new appointment by voice is the largest write and lands last
   in this phase — it needs client resolution + a duration default.)

Role-aware throughout: an employee hears/acts only on appointments where their
users doc id is in `employeeIds` (the standard visibility rule); an admin hears
the whole business's appointments. **Write actions honor the same status
allowlist and rules as the in-app flow** — voice is just another client of the
existing repository writes, so `AppointmentStatus.fromRaw(...).raw`
normalization and the `firestore.rules` guards apply unchanged.

Siri answers **from the lock screen without unlocking** for reads — the
hands-free use case (plumber driving between jobs) is the point, and the data is
the user's own schedule. **Write actions require device auth** (Siri prompts to
unlock before committing a change) so a lost phone can't be voice-driven to
mutate the schedule.

## Architecture

```
Flutter app (whenever it runs)
  └─ writes role-filtered schedule snapshot (today + next 7 days, JSON)
     via home_widget → App Group container (group.net.vogas.scheduling)

Siri READ query (Phases 1–3)
  └─ App Intents extension (Swift, iOS 16+, no Flutter, no Firebase)
     reads + decodes the snapshot → speaks the answer (ms latency, offline-capable)

Siri WRITE action (Phase 4) / LIVE read (Phase 5)
  └─ App Intents extension (Swift) + Firebase Auth/Firestore/App Check
     ├─ auth restored from a keychain access group shared with Runner
     ├─ App Check token minted in-extension (App Attest)
     └─ commits the write / runs the live query against Firestore
```

- **App Intents framework (iOS 16+)**, not legacy SiriKit — phrases work out
  of the box with no user setup. This called for a bump to **16.0**; what
  actually shipped is an **18.0** floor, because the Live Activity Directions
  button's returnable `OpenURLIntent` (built the same day) is iOS 18+ and the
  whole app moved together. 16.0 is therefore subsumed, the Swift types stay
  `@available(iOS 16.0, *)`, and App Attest's ≥14 floor is still satisfied.
  iOS 15–17 users are dropped — a taken product decision.
- **Dedicated App Intents extension target**, not intents in the app binary:
  in-app intents make iOS cold-boot the whole Flutter+Firebase app in the
  background per query (multi-second answers); the extension answers in
  milliseconds and needs only the App Group entitlement. No Siri entitlement
  is required for App Shortcuts.
- **Same snapshot the future WidgetKit widget will read** (push-notifications
  plan, Phase: widget). Built once here; the widget reuses it.
- **Reads (Phases 1–3) keep the extension Firebase-free** — snapshot in, speech
  out, no network. This is the property that makes reads answer in milliseconds
  and work offline; preserve it.
- **Writes and live reads (Phases 4–5) break that property deliberately.** To
  commit a change or run a live query, the extension must be an authenticated
  Firebase client:
  - **Shared auth** — Runner and the extension share a keychain access group
    (`$(AppIdentifierPrefix)net.vogas.scheduling`); the app writes the Firebase
    Auth credential there on sign-in, the extension restores the session from it.
    No re-login in Siri; sign-out in the app must also clear the shared item.
  - **App Check from the extension** — App Attest attestation minted in-process
    (the App Attest capability must be on the extension target too, not just
    Runner). Rules already require App Check on writes.
  - **Latency/reliability cost** — a live/write intent does real network work, so
    it is slower and can fail offline. Write intents therefore **confirm, then
    commit**, and surface a spoken failure ("Couldn't reach ES Pro — try again")
    rather than silently dropping. This is the tradeoff for going beyond the
    snapshot; reads stay on the fast offline path.

## Snapshot contract

Written by Flutter via `home_widget` (`HomeWidget.setAppGroupId(...)` +
`saveWidgetData('schedule_snapshot', jsonString)`); read in Swift from
`UserDefaults(suiteName: "group.net.vogas.scheduling")`.

```json
{
  "version": 2,
  "generatedAt": 1791234567890,
  "role": "employee",
  "days": [
    {
      "date": "2026-07-10",
      "appointments": [
        {
          "id": "appt_abc123",
          "startMillis": 1791234567890,
          "endMillis": 1791238167890,
          "clientName": "…",
          "title": "…",
          "address": "…",
          "status": "pending",
          "isAllDay": false
        }
      ]
    }
  ]
}
```

**v2 (2026-07-31)** added `title` and `isAllDay` for personal jobs. A personal
job carries no client, so without `title` Siri said "an unnamed client"; an
all-day block stores a real midnight → 23:59 span, so without the flag Siri read
its start out as 12:00 a.m. `SiriStrings.who(_:article:)` and
`timePhrase(_:)` are the two resolvers that consume them — new phrasing goes
through those rather than touching `clientName` or `time(_:)` directly. The
version is stamped in `schedule_snapshot.dart` and gated in
`ScheduleSnapshot.swift`; bump both together, and expect one "Open ES Pro to
sync your schedule" answer on the first launch after a bump, until the app
rewrites the payload.

- Window: today + next 7 days, device-local day boundaries. The 7-day span is
  exactly what **Phase 2 date queries** read — "Friday" resolves to that day's
  bucket; a date past the window answers "I only have your schedule for the next
  7 days." No schema change is needed for Phase 2.
- **Cancelled appointments excluded** at build time. Today's count/list =
  everything else; "next appointment" = earliest `startMillis > now` whose
  status is not `done` — except that an **all-day block never wins "next" while
  a timed visit remains** (it starts at midnight, so it would own the slot all
  day and hide the real next visit), and it counts as upcoming until its
  `endMillis`, not its start.
- Each appointment carries its **doc id** (`id`, added for Phase 4) so a write
  action can target the exact Firestore document the user named by voice; unused
  by the read intents.
- Statuses pass through `AppointmentStatus.fromRaw(...)`, then a guard maps the
  display-only `overdue` to `pending` **before** taking `.raw` (reading
  `AppointmentStatus.overdue.raw` throws by design, so the bare `.raw` this doc
  originally specified would fail the whole build on one odd doc). Legacy
  `confirmed` docs normalize to the allowlist. *(As-built correction.)*
- Size cap: 30 appointments per day (defensive; Siri reads at most a day).
- `version` lets the Swift side reject snapshots from a future schema instead
  of mis-decoding.
- **Only these fields.** The App Group stays readable while the device is
  locked, so the payload deliberately omits notes, phone, pictures, and
  materials — everything here is at-rest PII at a weaker protection class than
  the rest of the app's data. Don't widen it without re-reading the Privacy §.

**Refresh triggers (Flutter side) — as built:** the snapshot is
**provider-driven, not event-driven**. `scheduleSnapshotProvider` recomputes
whenever the underlying appointments stream emits, and `ScheduleSnapshotService`
dedups on a `generatedAt`-insensitive signature so an unchanged schedule never
rewrites the container. It also watches `currentDayProvider`, which
self-invalidates at midnight — without that, an app left running overnight kept
publishing yesterday's buckets and Siri answered "no appointments today" while
jobs existed (2026-07-19 audit, bug B2).

*(This supersedes the original plan of "sign-in routing + debounced stream
emissions + app-lifecycle resume". There is no `Debouncer` on this path — the
signature dedup does that job — and no lifecycle-resume hook.)*

**Sign-out wipes the snapshot**, but **implicitly**: signed-out/inactive makes
`activeUserIdentityProvider` resolve null → the snapshot provider emits
`data(null)` → the listener calls `clearSnapshot()`. There is **no explicit
clear on the sign-out path** and none should be added — same contract as the
widget. Account deletion/kick-out wipe it the same way.

## Components

### Dart (all buildable + testable on this Windows box)

*(All three shipped 2026-07-19 — see the implementation plan's Phase 1 for the
as-built detail. Descriptions below corrected to match the code.)*

- **Pure snapshot builder** — `buildScheduleSnapshot({appointments, role, now})`:
  day bucketing, cancelled exclusion, id-less records dropped, status
  normalization, per-day cap, `generatedAt` stamp. Pure function, plain `test()`
  coverage (12 tests).
- **Writer service** — thin wrapper over `home_widget` exposing
  `writeSnapshot(...)` and `clearSnapshot()`, with signature-based dedup and a
  `Platform.isIOS` gate. It takes an optional injected `AppLogger` but calls
  `home_widget` **statically** — the "injected interface so tests mock it" idea
  here was dropped to match `WidgetSyncService`. Consequence: write/clear are
  device-only, and only the pure dedup signature is unit-tested (3 tests).
- **Riverpod wiring** — `scheduleSnapshotProvider` watches the signed-in user's
  identity (via `activeUserIdentityProvider`, **not** a hand-rolled role/status
  guard) plus the appointments stream, and emits the payload or `data(null)`.
  The listener lives in `AppSyncListeners` (`lib/core/app/`), not inline in
  `main.dart` — it was extracted there so the wiring is testable without
  building a `MaterialApp`. Clearing is implicit via `data(null)`; there is no
  sign-out-path clear.
- `pubspec.yaml`: no change needed — `home_widget` was already a dependency for
  the home-screen widget.

### Swift (authored here in `ios/SiriIntents/`, compiled only on the Mac)

**Phase 1 (read foundation) — ✅ all authored + target built 2026-07-19:**

- `ScheduleSnapshot.swift` — Codable structs + App Group `UserDefaults`
  loader; rejects missing/undecodable/wrong-version data. Decodes `id`
  (non-optional, needed by Phase 4) and exposes `deepLink`.
- `AppointmentCountIntent.swift`, `TodayScheduleIntent.swift`,
  `NextAppointmentIntent.swift` — each returns a spoken `IntentDialog`;
  formatting via device-locale `DateFormatter`. All three set
  `openAppWhenRun = false` + `authenticationPolicy = .alwaysAllowed` so reads
  answer from the lock screen; **Phase-4 write intents must not copy that**.
- `ESProShortcuts.swift` — `AppShortcutsProvider`, 14 phrases across EN + FR.
- `SiriStrings.swift` — all spoken text, EN + FR. **Shipped as one plain-Swift
  file rather than the string catalogs this doc originally specified**, so both
  localizations sit side by side and review together. Response language follows
  `Locale.current`, matching `ScheduleWidget.swift`.
- `Info.plist` — `NSExtensionPointIdentifier = com.apple.appintents-extension`.
- Target `SiriIntents` (`net.vogas.scheduling.SiriIntents`) created + embedded
  in Runner, sharing the App Group via `SiriIntentsExtension.entitlements`.
  Firebase deliberately **not** linked — Phases 1–3 stay Firebase-free.

**Phase 2 (date queries):**

- `DayScheduleIntent.swift` — takes a resolved date parameter (`@Parameter`
  with a date `EntityQuery`/`AppEnum` for relative days), maps it onto a
  snapshot bucket, reuses the Phase-1 formatting. Add the "…tomorrow / on
  {day}…" phrases to `ESProShortcuts.swift`.

**Phase 3 (multi-turn):**

- Follow-up handling on the read intents via App Intents' conversation
  continuation (returning a result that requests further input), so "and
  tomorrow?" stays in-session. No new data; formatting/session logic only.

**Phase 4 (write actions) — introduces Firebase into the extension:**

- `FirebaseExtensionBootstrap.swift` — configures a minimal Firebase app in the
  extension, restores auth from the shared keychain access group, activates
  App Check (App Attest).
- `CancelAppointmentIntent.swift`, `CompleteJobIntent.swift`,
  `RescheduleIntent.swift`, `BookAppointmentIntent.swift` — each resolves the
  target by snapshot `id` (or client name for booking), uses
  `requestConfirmation` to read the change back, then commits via Firestore.
  Writes go through the **same field shapes and status normalization** the app's
  repository uses; the extension is just another authenticated client.
- Sign-in/sign-out in the Flutter app must write/clear the shared keychain item
  (new step in the Dart auth service).

**Phase 5 (live data):**

- `LiveScheduleClient.swift` — direct Firestore read (same bootstrap as Phase 4)
  used when the snapshot is stale/missing, falling back to the snapshot on
  network failure. Plus a Cloud Function silent-push (or reuse the push plan's
  `content-available` messages) to refresh the snapshot in the background.

**Phase 6 (proactive & other surfaces):**

- Intent **donations** after in-app views (`IntentDonationManager`) to power
  Siri Suggestions; interactive `SnippetView` result cards; CarPlay scene
  wiring; Spotlight `CSSearchableItem` indexing of upcoming jobs; an Apple Watch
  companion; Action-button assignment. Each is independent and can ship à la
  carte.

### Mac runbook (new doc, `docs/plans/` — same pattern as `APP_STORE_SUBMISSION.md`)

Phases 1–3 (read):

1. Create App Group `group.net.vogas.scheduling` in the developer portal;
   add the App Groups capability to **both** Runner and the extension.
2. Add an **App Intents extension** target (iOS 16.0) named `SiriIntents`;
   pull in the authored Swift files.
3. Bump `IPHONEOS_DEPLOYMENT_TARGET` to 16.0 on Runner (the pbxproj edit may
   land from Windows; verify in Xcode).
4. Device test matrix (below).

Phase 4+ (write / live — extra Mac steps, do these only when that phase lands):

5. Add the **App Attest** capability + `com.apple.developer.devicecheck.appattest-environment`
   entitlement to the **extension** target (Runner already has it).
6. Add a shared **Keychain Access Group**
   (`$(AppIdentifierPrefix)net.vogas.scheduling`) to both Runner and the
   extension; wire the Flutter auth service to write/clear the Firebase
   credential there.
7. Add `firebase-ios-sdk` (Auth, Firestore, AppCheck) to the extension target
   via SPM (the project is SPM-only — no Podfile). Keep the extension's linked
   product set minimal to stay within the extension memory budget.
8. Register the extension's App Attest key path in the Firebase Console App
   Check config if it differs from Runner.

## Error handling & freshness

| Condition | Siri response |
|---|---|
| No snapshot / decode failure / wrong version / signed out (wiped) | "I couldn't find your schedule — open ES Pro and sign in." |
| Snapshot `generatedAt` not today (device-local) | Answer prefixed with the caveat: "As of yesterday 5 PM, you had 3 appointments…" |
| Zero appointments today | "You have no appointments today." |
| No upcoming appointment (next-appointment intent) | "You have no upcoming appointments." |
| Date query outside the 7-day window (Phase 2) | "I only have your schedule for the next 7 days." |
| Write action can't reach Firestore (Phase 4, offline) | "I couldn't reach ES Pro to make that change — try again in a moment." (No partial write.) |
| Write target ambiguous (Phase 4, e.g. two 3 PM jobs) | Siri disambiguates: "You have two at 3 — the one at 14 Elm or 8 Oak?" |

The extension never crashes on bad data — every read failure degrades to the
open-the-app message, and every write failure degrades to a spoken retry prompt
with no partial commit.

**Freshness path (now in scope — Phase 5):** silent pushes (reusing the
push-notifications plan's `content-available` messages) refresh the snapshot in
the background, and a direct Firestore query from Swift (keychain-shared auth +
App Check) serves a live answer when the snapshot is stale/missing, falling back
to the snapshot on network failure. Phases 1–3 still answer purely from the last
snapshot — the live path is an escalation, not a replacement.

## Privacy

The snapshot holds client names + addresses in the App Group container —
on-device only, sandboxed to this app's targets, never transmitted, wiped on
sign-out. **Phases 1–3: no Firebase, no network, no analytics in the extension.**

**Phases 4–5 change the extension's data posture** and must be reviewed as such:
the extension gains an authenticated Firebase session (restored from a shared
keychain item) and does make network calls. Guardrails: the shared keychain
credential is cleared on sign-out alongside the snapshot; the extension performs
only the user's own role-scoped reads/writes (same `firestore.rules` as the
app); still no third-party analytics in the extension; and write actions require
device auth (Siri unlock) so a locked-but-stolen phone can't be voice-driven to
mutate data. Adding Firebase to an extension widens the on-device attack surface
versus the snapshot-only reader — that is the deliberate cost of voice writes,
called out here so it's a conscious App Review / security-review decision, not a
silent drift.

## Testing

**Windows/Dart (this box):**
- Pure builder tests: role matrix (admin vs employee input lists), day
  boundaries, cancelled exclusion, legacy-status normalization, per-day cap,
  empty input, and (Phase 2) arbitrary-date bucket resolution incl. the
  out-of-window case.
- Writer service with mocked `home_widget` interface; sign-out wipe test
  (snapshot **and** shared keychain item, once Phase 4 adds the latter).
- Android dev harness: `home_widget` works on Android, so snapshot writes are
  verifiable end-to-end on the emulator (read back the stored JSON).

**Mac/device only (runbook test matrix):**
- Phrase recognition EN + FR × all intents (reads, Phase-2 date, Phase-4
  writes).
- Read states: normal day, empty day, stale snapshot, signed out, locked phone.
- Phase 3: multi-turn follow-up stays in-session.
- Phase 4: confirm-then-commit happy path; write while offline (spoken retry, no
  partial write); ambiguous-target disambiguation; role scoping (employee can't
  mutate another's job); Siri-unlock gate on writes.
- Phase 5: live query when snapshot stale; fallback to snapshot on network fail;
  silent-push snapshot refresh.
- Confirm Runner **and the extension** pass App Attest after the target bump and
  the Phase-4 entitlement additions.

## Scope status

The formerly out-of-scope surfaces are now **in scope**, sequenced into the
phases above. Summary of where each landed:

| Former out-of-scope item | Now |
|---|---|
| Tomorrow / arbitrary-date queries | **Phase 2** (no snapshot change) |
| Multi-turn / conversational follow-ups | **Phase 3** |
| Siri write actions (book/reschedule/cancel/complete) | **Phase 4** (adds Firebase to the extension) |
| Live Firestore-from-Swift + silent-push refresh | **Phase 5** |
| Proactive Siri Suggestions / intent donations | **Phase 6** |
| Interactive snippets / custom Siri UI | **Phase 6** |
| CarPlay, Spotlight indexing, Apple Watch, Action button | **Phase 6** |

### Still out of scope

- **Home-screen WidgetKit widget** — owned by the push-notifications plan
  (it *reuses* this snapshot); tracked there, not duplicated here.
- **Android voice** — Google Assistant App Actions have no equivalent
  zero-setup surface, and Android is dev-harness-only per the App-Store-only
  decision. Not planned.
- **Languages beyond EN + FR** — phrase lists and response catalogs stay EN/FR,
  matching the app's `supportedLocales`. Add locales when the app does.

### Sequencing note

Phases 1–2 are the highest value-per-effort (pure additive read work, most of it
buildable and testable on this box) and should ship first. **Phase 4 is the
inflection point** — it puts an authenticated Firebase client inside an App
Intents extension, which is a real security-surface and App-Review change (see
Architecture + Privacy); do it as its own reviewed increment, not bundled with
the read phases.
