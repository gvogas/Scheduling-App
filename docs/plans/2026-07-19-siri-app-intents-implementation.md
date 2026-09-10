# Siri App Intents — Implementation Plan

Companion to the design doc [`2026-07-10-siri-app-intents-design.md`](./2026-07-10-siri-app-intents-design.md).
That doc is the *what/why* (six phases, scope decisions, architecture). This is
the *how* — files, order, tests, Mac steps — grounded in the code that already
exists.

**Status: Phases 1, 2 and 3 are BUILT; none has ever been run on a device**
(banner corrected 2026-08-15 — it had said "Phase 1 COMPLETE" since 2026-07-19,
while the per-phase headings below already recorded 2 and 3 as built). The
snapshot the intents read is at **schema v3** — the multi-day mirrors work
raised it. Phase 4 (voice write actions) is specified in its own doc and nothing
is landed.
The Dart half (builder, service, provider, `main.dart` wiring, 15 unit tests) is
in `lib/features/siri/`; the Swift half is in `ios/SiriIntents/` with a Mac
runbook + device checklist at `ios/SiriIntents/README.md`. The `SiriIntents`
App Intents extension target **was created and embedded in Runner 2026-07-19**
and builds clean (bundle id `net.vogas.scheduling.SiriIntents`, entitlements
`SiriIntentsExtension.entitlements` sharing the App Group). The deployment
target went to **iOS 18.0**, not the 16.0 this plan originally called for — the
Live Activity Directions button's returnable `OpenURLIntent` forced the whole
app to an 18.0 floor. Remaining for Phase 1: the on-device Siri phrase pass.
**Phases 2 and 3 are now also code-complete** (2026-07-19) — all Swift-only:
Phase 2 `TomorrowScheduleIntent` + `DayScheduleIntent`, Phase 3
`NthAppointmentIntent`. All six intents build clean and pass the App Intents
metadata compiler; all three phases await the same on-device Siri pass.
**Reviewed 2026-07-19 against the code; corrections applied inline.** Phases 1–3
are built; Phase 4 is the next unbuilt milestone.
**Re-verified 2026-09-09:** `ios/SiriIntents/` holds exactly the six read
intents (`AppointmentCount`, `TodaySchedule`, `NextAppointment`,
`TomorrowSchedule`, `DaySchedule`, `NthAppointment`) and no write intent, no
`keychain-access-groups` entitlement and no second Firebase app — so Phase 4 is
still entirely unlanded, and the only thing standing between Phases 1-3 and
done remains the on-device Siri pass. **Phase 4 is blocked** on two paper decisions flagged in
its Mac steps (App Attest's bundle-ID binding; the not-yet-existing
`keychain-access-groups` entitlement).

## Key head-start: the widget already paved this road

The design doc frames the App Group snapshot as new infrastructure. It mostly
isn't — the iOS home-screen widget already established every foundation piece:

| Foundation | Already exists | Reuse |
|---|---|---|
| `home_widget` package | `pubspec.yaml` (`^0.9.3`) | No new dep |
| App Group `group.net.vogas.scheduling` | `widgetAppGroupId` in [`widget_sync_service.dart`](../../lib/features/home_widget/application/widget_sync_service.dart#L23); entitlements on Runner + `ScheduleWidget` | Same container, **new key** `schedule_snapshot` |
| Pure payload builder pattern | `buildWidgetPayload(...)` (same file) | Copy the shape for `buildScheduleSnapshot(...)` |
| Sync service w/ dedup + iOS-gate | `WidgetSyncService` (`_signatureOf` dedup, `_lastState`, `clear()`) | Copy for `ScheduleSnapshotService` |
| Employee-id + payload providers | `widgetEmployeeIdProvider`, `widgetPayloadProvider` | Copy/parametrize for the snapshot |
| Emission-driven wiring | `_widgetSync()` in [`app_sync_listeners.dart`](../../lib/core/app/app_sync_listeners.dart) | `_snapshotSync()` sits beside it (both moved out of `main.dart` 2026-07-19) |
| Off-screen-mirror identity | `activeUserIdentityProvider` | Same provider — one active+role gate for both mirrors |
| Midnight rollover | `currentDayProvider` | Same provider — neither mirror may use a bare `DateTime.now()` |
| Deep-link scheme | `esproschedule://appointment?id=…` | Siri result tap reuses it |

So **Phase 1 is ~90% "clone the widget path with a wider date window and a
count/next projection"** — very little genuinely new Dart.

Divergences from the widget payload to design in deliberately:
- **Window:** widget carries today+tomorrow; the snapshot needs **today + 7
  days** (design doc), so `days[]` is a per-day bucket array, not two lists.
- **Role:** widget is employee-scoped only; the snapshot is **role-aware** —
  admins hear the whole business. `widgetEmployeeIdProvider` returns null-for-
  clear semantics; the snapshot provider must instead branch employee (own
  `employeeIds`) vs admin (all) — see the appointments providers below.
- **Cancelled excluded at build**; widget keeps them for its rollover math.

---

## Phase 1 — read, today/next (the foundation) — ✅ BUILT

Everything below is **as-built** (2026-07-19), not a plan. Where the shipped
code diverges from what this doc originally specified, the divergence is called
out — those are the parts worth knowing before touching it.

### Dart — landed in `lib/features/siri/`

1. **`domain/schedule_snapshot.dart`** (98 lines) — pure builder.
   `buildScheduleSnapshot({appointments, role, now})` → `Map<String, dynamic>`.
   Day-buckets `now.dateOnly … +7d` (device-local), **excludes cancelled**,
   per-day cap 30 (`scheduleSnapshotPerDayCap`), stamps
   `version: scheduleSnapshotVersion` + `generatedAt` + `role`, carries `id`.
   Records with a null/empty `id` are dropped — Phase-4 write actions resolve
   their target by `id`, so an id-less entry is unactionable, and `id` is
   **non-optional** in the Swift `Codable`.
   - ⚠️ **Divergence — status normalization needed a special case.** This plan
     said "normalize via `AppointmentStatus.fromRaw(a.status).raw`". That alone
     would **throw**: reading `AppointmentStatus.overdue.raw` throws on purpose
     (CLAUDE.md — it's a display-only state that must never be written), so a
     doc somehow storing `overdue` would fail the entire snapshot build rather
     than one record. The shipped `_storedStatus` maps `overdue → pending`
     first, then takes `.raw`. Keep that guard if you touch the builder.
2. **`application/schedule_snapshot_service.dart`** (83 lines) — imports
   `widgetAppGroupId` (not redefined), writes under the **public** const
   `scheduleSnapshotKey = 'schedule_snapshot'`, `_signatureOf` dedup minus
   `generatedAt`, `_lastState` with a distinct `_clearedState` sentinel so a
   repeat clear is also deduped, `Platform.isIOS` gate, `warn` on failure.
   Provider `scheduleSnapshotServiceProvider` injects `loggerProvider`.
   - **Divergence:** this plan (and the design doc) called for "an injected
     interface so tests mock it". The shipped service takes only an optional
     `AppLogger`; `home_widget` is called statically, exactly as
     `WidgetSyncService` does. Consequence: the write/clear paths are
     device-only, and just the two pure statics are unit-tested — which is the
     established pattern, not a shortfall.
3. **`application/schedule_snapshot_provider.dart`** (47 lines) — role-aware,
   `Provider.autoDispose`. Employee → `myAppointmentsProvider`, admin →
   `appointmentsInRangeProvider`. Signed-out/inactive → `data(null)` (clear).
   Two divergences, both deliberate and both load-bearing:
   - ⚠️ **Identity comes from `activeUserIdentityProvider`**, not
     `currentUserDocProvider` / a copy of `widgetEmployeeIdProvider`'s guard.
     Both off-screen mirrors (this and the home-screen widget) now resolve *who
     they're for* through that one provider — active-status gate,
     employee-or-admin, `retryAsync(findUserByUid)` for the post-sign-in token
     lag. It returns `(role, docId)`, and its null is what wipes both mirrors on
     sign-out. Route any new mirror through it rather than re-deriving.
   - ⚠️ **The provider watches `currentDayProvider`** (`core/utils/`) for its
     day bucketing instead of a bare `DateTime.now()`. The appointments stream
     only re-emits on a write, so an app left resident overnight otherwise kept
     publishing yesterday's buckets and **Siri answered "no appointments today"
     while jobs existed**. This was found and fixed by the 2026-07-19 audit
     (bug B2); don't reintroduce a bare `now` here.
4. **Wiring** — `_snapshotSync()` in
   [`lib/core/app/app_sync_listeners.dart`](../../lib/core/app/app_sync_listeners.dart),
   registered by `AppSyncListeners.registerAll()`.
   - **Divergence:** this plan said "add `_listenForSnapshotSync()` to
     `main.dart`". It landed there first, then moved: the ~10 `ref.listen`
     wire-ups were extracted out of `main.dart` into `AppSyncListeners` so they
     could be unit-tested without building a `MaterialApp`. The
     account-lifecycle listeners stayed in `main.dart` (their registration order
     is load-bearing). Old `main.dart:458/469/378` line references in earlier
     drafts of this doc are dead.
   - **Clearing is implicit — do NOT add an explicit sign-out clear.**
     `scheduleSnapshotProvider` emits `data(null)`, the listener calls
     `clearSnapshot()`. Same contract as the widget.

**No pubspec change** (`home_widget` already present). No new App Group.

### Swift — landed in `ios/SiriIntents/`

| File | Lines | What |
|---|---|---|
| `ScheduleSnapshot.swift` | 99 | `Codable` + App Group `UserDefaults` loader; rejects missing/undecodable/wrong-`version`; `day(on:)`, `today`, `nextAppointment(after:)`, `dayKey` mirroring the Dart `_dayKey`; `deepLink` → `esproschedule://appointment?id=…` |
| `AppointmentCountIntent.swift` | 30 | "how many appointments today" |
| `TodayScheduleIntent.swift` | 35 | reads today's list, time + client per line |
| `NextAppointmentIntent.swift` | 32 | earliest upcoming not-done visit across the **whole 7-day window**, so an empty rest-of-today still answers with tomorrow's first job |
| `ESProShortcuts.swift` | 50 | `AppShortcutsProvider`, 14 phrases across EN + FR |
| `SiriStrings.swift` | 132 | all spoken text, EN + FR |
| `Info.plist` | 11 | `NSExtensionPointIdentifier = com.apple.appintents-extension` |
| `README.md` | 86 | Mac runbook + device checklist |

- **Divergence:** the plan called for "EN/FR string catalogs". Shipped as one
  plain-Swift `SiriStrings.swift` instead, so both localizations sit side by
  side and review as one file. Response language follows `Locale.current`,
  matching how `ScheduleWidget.swift` picks its labels.
- All three intents set `openAppWhenRun = false` and
  `authenticationPolicy = .alwaysAllowed` — reads answer from the lock screen
  without unlocking, which is the hands-free point. **Phase-4 write intents must
  NOT copy that policy.**
- Types are gated `@available(iOS 16.0, *)` even though the app floor is now
  18.0. Harmless and left alone: the gate is what the App Intents API requires,
  and keeping it means the files don't need touching if the floor ever moves.

### Mac steps (Phase 1) — done 2026-07-19

1. ✅ **App Intents extension target `SiriIntents` created and embedded in
   Runner** — bundle id `net.vogas.scheduling.SiriIntents`, entitlements
   `SiriIntentsExtension.entitlements` sharing the App Group
   `group.net.vogas.scheduling`. Builds clean.
2. ✅ **Deployment target bumped — but to 18.0, not 16.0.** This plan called for
   15.0 → 16.0 across all 6 build configurations. What actually happened: the
   Live Activity Directions button's returnable `OpenURLIntent` is **iOS 18+**,
   so the whole app moved to an **18.0** floor in the same session, which
   subsumes Siri's 16.0 requirement. iOS 15–17 users are dropped — a product
   decision, taken. App Attest's ≥14 floor is still satisfied. (The pbxproj line
   numbers this plan used — 512, 569, 615, 658, 779, 832 — are stale; the file
   has changed since.) CLAUDE.md's deployment-target note is updated.
3. ✅ Swift files pulled in. `firebase-ios-sdk` deliberately **not** linked into
   the extension — Phase 1 is Firebase-free.

### Phase 1 tests — 15, all passing

- `test/features/siri/schedule_snapshot_test.dart` — **12 tests** over the pure
  builder: role matrix, 7-day bucketing + device-local boundaries, cancelled
  exclusion, legacy `confirmed`→allowlist normalization, per-day cap 30, empty
  input, `version`/`generatedAt`/`id` presence, null-`id` records dropped.
- `test/features/siri/schedule_snapshot_signature_test.dart` — **3 tests** on
  `signatureForTesting`: dedup ignores `generatedAt`; a changed schedule changes
  the signature.
- `test/features/auth/application/active_user_identity_provider_test.dart` —
  added by the 2026-07-19 audit (finding T4). It covers the identity provider
  both mirrors now depend on: the active+role gate returning null, and
  `retryAsync` surviving the post-sign-in `permission-denied` lag. A regression
  there silently wipes both the widget and this snapshot.
- **Not unit-testable** (CLAUDE.md device-only rule): the write / `clearSnapshot`
  / iOS-gate paths — `home_widget` is a method-channel plugin.

### Phase 1 remaining: on-device verification

The only thing left. Per `ios/SiriIntents/README.md`: EN + FR phrase
recognition × 3 intents; normal / empty / stale / signed-out / locked states;
snapshot write + clear actually landing in the App Group.

**Phase 1 exit:** three read intents answer from the snapshot on a device;
sign-out wipes it. *(Code complete; awaiting the device pass.)*

---

## Phase 2 — date queries (pure additive) — ✅ BUILT (device pass pending)

No snapshot schema change — the 7-day window already carries every day. **No
Dart change** landed: the builder already emits all 8 buckets, so this was
Swift-only, as predicted.

As-built (2026-07-19):
- **`TomorrowScheduleIntent.swift`** — deterministic, no parameter. Mirrors
  `TodayScheduleIntent` against `now + 1 day`. Bilingual single-utterance
  phrases ("what's my schedule tomorrow" / "…demain"). "Tomorrow" is the most
  common relative-day query, so it gets its own intent rather than sharing the
  parameterized one — zero App Intents ambiguity, guaranteed to match.
- **`DayScheduleIntent.swift`** — arbitrary day via a `Date` `@Parameter`.
  - ⚠️ **Divergence — the date can't live in the phrase.** This plan said "add
    …on {day}… phrases". App Shortcut phrases only accept **AppEnum/AppEntity**
    parameters (Siri needs a finite value set to match an utterance) — a `Date`
    parameter interpolated into a phrase does **not** work. Getting single-
    utterance "what's my schedule Friday" would need an `AppEnum` of days **plus
    a localized string catalog** for FR matching, which fights this extension's
    plain-Swift/`Locale.current` bilingual pattern and can't be verified off-
    device. So the phrase carries no date ("read my schedule for a day") and
    Siri resolves the `Date` through its own **locale-aware prompt** ("For what
    day?" → "Friday"/"vendredi"/"July 25"). Fully supported, bilingual, no
    catalog. Tradeoff: a two-turn interaction for non-tomorrow days.
  - Maps the resolved date to a `days[]` bucket by local calendar day;
    out-of-window (past or >7 days out → no bucket) answers "I only have your
    schedule for the next 7 days."
- **`SiriStrings.swift`** — added `relativeDay` (today/tomorrow/weekday phrasing),
  `whichDayPrompt`, `outOfWindow`, `emptyDayFor(date:)`, `scheduleIntroFor(date:)`,
  all EN + FR.
- **`ESProShortcuts.swift`** — two new `AppShortcut` blocks (5 phrases each,
  EN + FR).
- **Xcode:** both `.swift` files added to the `SiriIntents` target in
  `project.pbxproj` (all four sections); `plutil -lint` clean.

- **Tests:** no new Dart tests — the snapshot data and its 12+3 Phase-1 tests
  are unchanged, and the Swift intents are device-only (no Swift test harness,
  same as the Phase-1 intents). Verification is the on-device pass in
  `ios/SiriIntents/README.md`.

**Exit:** "what's my schedule tomorrow?" reads tomorrow in one utterance;
"read my schedule for a day" → Siri prompts → reads any in-window day.
*(Code complete; awaiting the device pass.)*

---

## Phase 3 — multi-turn — ✅ BUILT (device pass pending)

Swift-only; no data change. Code-complete 2026-07-19.

- ⚠️ **Divergence — App Intents has no free-form conversation session.** This
  plan (and the design doc) imagined "and tomorrow?" / "read me the third one"
  as continuation results that keep a Siri session open across separate
  invocations. App Intents doesn't offer that — there's no SiriKit-style
  `INInteraction` session; the one in-session multi-turn primitive is
  **parameter follow-up** (Siri asks for a missing `@Parameter`, the caller
  answers, all in one exchange). "And tomorrow?" is already served by Phase 2's
  `TomorrowScheduleIntent` as its own utterance, so Phase 3 delivers the
  buildable half: the "read me the third one" follow-up.
- **`NthAppointmentIntent.swift`** — reads one visit from **today's** list by
  1-based position. The position is an `Int` `@Parameter`; like `Date`, an `Int`
  can't be interpolated into a spoken phrase (AppEnum/AppEntity only), so the
  phrase ("read a specific appointment") triggers the intent and Siri asks
  "Which appointment? Say its number" — the prompt→answer→read exchange **is**
  the multi-turn beat. Out-of-range / empty-day answers degrade cleanly.
- **`SiriStrings.swift`** — `whichPositionPrompt`, `nth(position:)` (ordinal
  words 1-10 EN+FR, "number N"/"numéro N" beyond), `nthOutOfRange(count:)`, all
  role-scoped (you / the team).
- **`ESProShortcuts.swift`** — one new `AppShortcut` (5 phrases, EN+FR); six
  intents total now.
- **Xcode:** added to the `SiriIntents` target in `project.pbxproj` (all four
  sections); `flutter build ios` clean, App Intents metadata compiler accepted
  all six intents.
- **Tests (device):** "read a specific appointment" → Siri prompts → "3" reads
  the third of today; out-of-range and empty-day paths; EN + FR. No Dart/Swift
  unit tests (device-only intents, same as Phases 1-2).

**Exit:** "read a specific appointment" → Siri asks which → reads that visit,
in-session, both languages. *(Code complete; awaiting the device pass.)*

---

## Phase 4 — write actions ⚠️ inflection point

**This is the first phase that puts an authenticated Firebase client inside the
extension** — a real security-surface + App-Review change (design doc:
Architecture + Privacy). Ship it as its own reviewed increment.

> **Architecture chosen 2026-07-20: direct writes from the extension** (full
> hands-free). The two paper blockers are now **resolved on paper**, and a
> third — an App-Check-vs-Auth tension this section missed — was surfaced. The
> complete resolution + Mac runbook + reference Swift live in
> [`2026-07-20-siri-phase4-write-actions.md`](./2026-07-20-siri-phase4-write-actions.md).
> **TL;DR of the newly-found catch:** App Attest forces the extension onto its
> **own** Firebase app (bundle-id-bound App Check), but Firebase Auth's
> keychain sharing only auto-restores the user on the **same** Firebase app —
> so the extension needs a **custom-token handoff** (a new `mintSiriExtensionToken`
> callable + keychain-stored short-TTL token), unless a 30-min on-device App
> Check test proves a same-app config works (unlikely). Nothing is landed in the
> repo yet — the entitlement/SPM/2nd-app pieces would break the green build until
> the console/portal work is done in the same session.

### Dart
- **No Dart work for credential sharing.** An earlier draft had the Dart auth
  service writing the Firebase credential into a shared Keychain Access Group —
  `firebase_auth` exposes no such Dart API. The real mechanism is **native and
  automatic**: call `Auth.auth().useUserAccessGroup("$(AppIdentifierPrefix)net.vogas.scheduling")`
  in `AppDelegate.swift` **and** in the extension's bootstrap; Firebase Auth then
  syncs its own state through the keychain and Dart does nothing. See the Mac
  steps below — this is a Swift task, not a Dart one.
- No new write repository — Siri writes must go through the **same** appointment
  repository methods the app uses, so status normalization
  (`AppointmentStatus.fromRaw(...).raw`) and `firestore.rules` apply unchanged.
  The Swift side calls Firestore directly, so the invariant to enforce in review
  is *field-shape parity* with the Dart repository writes.

### Swift
- `FirebaseExtensionBootstrap.swift` — minimal Firebase app in-extension,
  restore auth from the shared keychain group, activate App Check (App Attest).
- `CancelAppointmentIntent`, `CompleteJobIntent`, `RescheduleIntent`,
  `BookAppointmentIntent` — resolve target by snapshot `id` (booking by client
  name), `requestConfirmation` reads the change back, then commit. Booking lands
  last (needs client resolution + duration default).

### Mac steps (Phase 4)
- ⚠️ **Resolve App Attest's bundle-ID binding BEFORE starting this phase.** App
  Attest keys are bound to a bundle ID, and `SiriIntents` gets a different one
  from `net.vogas.scheduling`. So the extension cannot simply inherit Runner's
  attestation: it likely needs its **own Firebase iOS app registration + its own
  App Check provider config in the console**, or its Firestore calls are
  rejected at the App Check gate with an opaque `permission-denied`. Decide this
  on paper first — discovering it mid-session on the Mac burns the session.
- Add `keychain-access-groups` to **`ios/Runner/Runner.entitlements`** (it has
  `appattest-environment`, `aps-environment`, and app groups today, but **no
  keychain sharing** — this entitlement does not exist yet) and to the extension
  entitlements; group `$(AppIdentifierPrefix)net.vogas.scheduling`.
- Call `Auth.auth().useUserAccessGroup(...)` in `AppDelegate.swift` and in the
  extension bootstrap (see Dart § — this replaces the credential-writing step).
- App Attest capability + `appattest-environment` entitlement on the **extension**
  target (Runner already has it).
- Add `firebase-ios-sdk` (Auth, Firestore, AppCheck) to the extension via SPM;
  keep linked products minimal (extension memory budget).

### Phase 4 tests
- Device (not Dart — the keychain sharing is native, see above): sign-out wipes
  the snapshot **and** drops the shared keychain credential, so a Siri write
  attempted after sign-out fails closed.
- Device: confirm-then-commit happy path; offline write → spoken retry, **no
  partial commit**; ambiguous-target disambiguation; role scoping (employee
  can't mutate another's job); Siri-unlock gate before commit.

**Exit:** cancel / complete / reschedule (then book) by voice, confirmed,
role-scoped, rules-enforced.

---

## Phase 5 — live data

- **Swift:** `LiveScheduleClient.swift` — direct Firestore read (reuse Phase-4
  bootstrap) when the snapshot is stale/missing; **fall back to snapshot on
  network failure** (never regress below Phase 1).
- **Functions/Dart:** silent-push snapshot refresh — reuse the push plan's
  `content-available` path (`fcm_background_handler.dart` already rewrites the
  *widget* payload in a background isolate; extend it to also rewrite the
  snapshot key, or add a sibling handler). Keep the isolate dependency-light per
  the existing background-handler invariant.
- **Tests (device):** live query when snapshot stale; snapshot fallback on
  network fail; silent-push refresh.

---

## Phase 6 — proactive & other surfaces (à la carte, Mac-only)

Independent, ship-when-wanted: intent **donations** (`IntentDonationManager`)
after in-app views → Siri Suggestions; interactive `SnippetView` cards; CarPlay
scene; Spotlight `CSSearchableItem` indexing; Apple Watch companion; Action
button. Each is its own small increment; none blocks the others.

---

## Cross-cutting

- **Localization:** all Siri phrases + responses ship EN + FR (matching
  `AppLocalizations.supportedLocales`); response language follows the device's
  Siri language. Add ARB keys only if any string surfaces in-app (the Swift
  string catalogs are separate from `gen_l10n`).
- **Snapshot data-protection class — ✅ decided and applied in Phase 1.** Siri
  answers while the device is locked, so the App Group payload stays readable
  when locked, putting everything in it at a weaker protection class than the
  rest of the app's data. The widget already accepts this for 2 days of one
  employee's jobs; the snapshot widens it to **7 days and, for admins, the whole
  business**. The mitigation this section asked for **was taken**: the payload
  carries only the fields the intents actually speak — `id`, start/end millis,
  client name, address, status. **Never** notes, phone, pictures, or materials.
  The builder's doc comment records why; keep it that way when adding a field.
- **Privacy review gate:** Phase 4 is where the extension stops being
  Firebase-free — flag for security-review/App-Review as a conscious change, not
  drift (design doc, Privacy §). Note the snapshot itself adds **no new App
  Privacy data type** — everything in it is already declared (Name, Physical
  Address, Other User Content); see `docs/plans/APP_STORE_SUBMISSION.md` Part 8.
- **CLAUDE.md updates when phases land:** ✅ deployment target (Phase 1 — landed
  as 18.0, see Mac steps) and the Siri App Intents invariant note (snapshot key,
  `activeUserIdentityProvider` routing, `currentDayProvider` rollover, the
  hand-mirrored Dart↔Swift pair, the id-drop rule) are both in CLAUDE.md today.
  Still to add when Phase 4 lands: the Firebase-in-extension boundary.

## Suggested sequencing

Phases **1, 2, and 3 are built** — only their (shared) on-device Siri pass
remains. **Phase 4 is the next unbuilt milestone** — treat it as a standalone
reviewed increment (the
Firebase-in-extension inflection, and still blocked on the two paper decisions
in its Mac steps). **5–6** are opportunistic follow-ups. Android stays out
(design doc).
