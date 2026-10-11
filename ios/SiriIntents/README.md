# SiriIntents — Mac setup runbook (Phase 1)

Design: [`docs/archive/2026-07-10-siri-app-intents-design.md`](../../docs/archive/2026-07-10-siri-app-intents-design.md).
Plan: [`docs/archive/2026-07-19-siri-app-intents-implementation.md`](../../docs/archive/2026-07-19-siri-app-intents-implementation.md).

## Xcode target — CREATED 2026-07-19

The `SiriIntents` App Intents extension target now exists in
`Runner.xcodeproj` (created via the `xcodeproj` Ruby gem, not the Xcode GUI)
and the whole app builds clean (`flutter build ipa`),
with `SiriIntents.appex` embedded in `Runner.app/Extensions/`:

- ⚠️ **This is an ExtensionKit extension, NOT an old-style NSExtension**
  (corrected 2026-07-20 after App Store validation rejected the NSExtension
  form with a 409). An App Intents extension point
  (`com.apple.appintents-extension`) MUST be built as ExtensionKit:
  - `Info.plist` uses `EXAppExtensionAttributes` → `EXExtensionPointIdentifier`
    (NOT `NSExtension` → `NSExtensionPointIdentifier`).
  - Target product type `com.apple.product-type.extensionkit-extension`
    (NOT `…app-extension`).
  - Embedded into `Runner.app/**Extensions/**` (NOT `PlugIns/`) via a Runner
    "Embed ExtensionKit Extensions" copy phase (`dstSubfolderSpec 16`,
    `dstPath $(EXTENSIONS_FOLDER_PATH)`), which must sit **before** the
    "Thin Binary" / "Crashlytics dSYM upload" script phases — placing it after
    them triggers a "Cycle inside Runner" archive error. (The `ScheduleWidget`
    WidgetKit extension stays an NSExtension in `PlugIns/` — that's correct for
    WidgetKit; only App Intents is ExtensionKit.)
  - bundle id `net.vogas.scheduling.SiriIntents`.
- `INFOPLIST_FILE = SiriIntents/Info.plist`, `CODE_SIGN_ENTITLEMENTS =
  SiriIntentsExtension.entitlements` (shares App Group
  `group.net.vogas.scheduling`), `DEVELOPMENT_TEAM = H5XWLU87AX`.
- The `.swift` files here are explicit source references on the target (not
  a synchronized group), so **a new `.swift` added to this folder must be added
  to the target manually** (edit `Runner.xcodeproj/project.pbxproj` in all four
  sections — PBXBuildFile, PBXFileReference, the group, and the target's Sources
  phase — or tick it in Xcode). The Phase-2 files `TomorrowScheduleIntent.swift`
  and `DayScheduleIntent.swift` were added this way (2026-07-19).
- **Deployment target is iOS 18.0, not 16.0** — the whole app moved to an 18.0
  floor (owner decision 2026-07-19; the Live Activity Directions button's
  returnable `OpenURLIntent` is iOS 18+). App Intents' iOS-16 floor is
  satisfied comfortably. The step-3 "bump 15 → 16" instruction below is
  superseded.

Remaining: on-device Siri phrase verification (the checklist further down).

The Dart half is done and on-device-ready: the app writes the snapshot into the
App Group under the key `schedule_snapshot` whenever the schedule changes, and
wipes it on sign-out. Nothing below touches Dart.

## Original manual-setup steps (kept for reference — the gem did items 1–3)

## Steps

1. **Add the target.** File → New → Target → **App Intents Extension**, name
   `SiriIntents`, embed in `Runner`. Delete the stub files Xcode generates and
   add the `.swift` files in this folder to the new target (Target Membership:
   `SiriIntents` only).
2. **Info.plist / entitlements.** Point the target's `INFOPLIST_FILE` at
   `SiriIntents/Info.plist` and its `CODE_SIGN_ENTITLEMENTS` at
   `SiriIntentsExtension.entitlements` (both are committed, mirroring the
   widget's pair), or add the **App Groups** capability in Signing &
   Capabilities and pick the existing `group.net.vogas.scheduling`. The extension
   needs no other capability — Phase 1 is Firebase-free and does no network I/O.
3. **Bump the deployment target 15.0 → 16.0.** App Intents requires iOS 16.
   Change `IPHONEOS_DEPLOYMENT_TARGET` in **all 6 build configurations** in
   `Runner.xcodeproj/project.pbxproj` (Runner *and* the `ScheduleWidget`
   extension, not Runner alone), and set the new target to 16.0 too.
   ⚠️ **This drops iOS 15 users** — a product decision, not just a build setting.
   App Attest's ≥14 floor stays satisfied. Update the "Deployment target is
   **iOS 15.0**" note in `CLAUDE.md` once this lands.
4. **Build and run on real hardware.** App Intents phrases are registered at
   install; give Siri a few seconds after first launch.

## Device verification checklist

Run the app once while signed in (that writes the snapshot), then ask Siri:

- [ ] EN + FR × the Phase-1 phrases ("how many appointments today", "what's my
      schedule today", "what's my next appointment") — see `ESProShortcuts.swift`
      for the exact phrase list.
- [ ] **Phase 2 — "tomorrow"** ("what's my schedule tomorrow" / "quel est mon
      horaire demain"): reads tomorrow's bucket; empty tomorrow answers "…no
      appointments tomorrow", not "today".
- [ ] **Phase 2 — arbitrary day** ("read my schedule for a day"): Siri asks
      "For what day?"; answering "Friday"/"vendredi"/"July 25" reads that
      bucket. A day >7 out or in the past answers "I only have your schedule for
      the next 7 days." **A `Date` parameter can't sit inside a spoken phrase**
      (Siri only allows AppEnum/AppEntity there), which is why this one prompts
      instead of matching the day in one utterance — confirm the prompt→answer
      flow works in both languages.
- [ ] **Phase 3 — specific appointment** ("read a specific appointment" / "lis
      un rendez-vous précis"): Siri asks "Which appointment? Say its number";
      answering "3" reads the third of today (ordinal wording in FR too). Asking
      for a number past the end answers "you only have N appointments today"; an
      empty day answers "no appointments today". Same `Int`-can't-sit-in-a-phrase
      reason as Phase 2 — confirm the prompt→answer flow in both languages.
- [ ] **Employee vs. admin** — an employee hears only their assigned visits; an
      admin hears the whole business ("the team has…").
- [ ] **Empty day** — no jobs today answers "no appointments today", not silence.
- [ ] **Next-appointment rollover** — with today finished, it answers with
      tomorrow's first job.
- [ ] **Locked device** — reads answer without unlocking (intended: hands-free
      while driving).
- [ ] **Signed out** — the snapshot is wiped, so Siri answers "Open ES Pro to
      sync your schedule." Confirm the container key is actually gone, not just
      that the answer changed.
- [ ] **Offline** — answers still work (no network path in Phase 1).

## Boundaries to preserve

- **No Firebase, no network in this extension.** That's what makes an answer
  arrive in milliseconds and work offline. Phases 4–5 break that deliberately,
  as their own reviewed increment — not as drift.
- `ScheduleSnapshot.swift` is hand-mirrored with `buildScheduleSnapshot` in
  `lib/features/siri/domain/schedule_snapshot.dart`. Change one, change both,
  and bump `version` on either side of a schema change. **Currently v4**
  (`scheduleSnapshotVersion` there; `supportedVersions` here is `[3, 4]`,
  since v4's CarPlay fields are additive and the on-disk snapshot stays v3
  until the app next runs) — a snapshot stamped with anything outside that set
  is rejected outright, so the first launch after a
  bump outside that set answers "Open ES Pro to sync your schedule." once, until the app
  rewrites the payload. New fields land as optionals so a stale payload still
  decodes far enough to hit that version gate rather than failing mid-decode.
  v3 added `dayIndex`/`dayCount`/`isOvernight` and — the part that matters —
  buckets a multi-day run on EVERY day it works rather than only the day it
  began, each entry carrying that day's own window. Before it, Siri said
  "nothing today" on day 2 of a five-day job.
- The snapshot stays readable while the device is locked, so it carries only the
  fields the surfaces use (client name, title, times, address, status,
  `isAllDay`, the day counter, v4's `isPersonal`/`isDayOff` flags) plus the doc
  `id` Phase-4 writes target. ADMIN snapshots also carry `crew` (names and
  stored colours) and `viewer` — other people's names, accepted by the owner
  for CarPlay (see the CarPlay bullet in `.claude/rules/notifications.md`).
  Don't widen it casually.
- All spoken text lives in `SiriStrings`. `who(_:article:)` is the single
  client → title → placeholder resolver (a personal job has no client), and
  `timePhrase(_:)` is the single start-time-or-"all day" resolver — it also
  appends the "day 2 of 5" / "nuit 2 sur 3" counter, so every surface that
  speaks a time gets it. Route new
  phrasing through those two rather than reaching for `clientName` or `time(_:)`
  at a new call site — an all-day block stores a real midnight start, so a raw
  `time(appointment.start)` reads it out as 12:00 a.m.
