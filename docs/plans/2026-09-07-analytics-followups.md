# Firebase Analytics — remaining work

**State: verified on a device 2026-09-10; what remains is off-repo** — an App
Store Connect action, a release step, or a reporting-window wait. Nothing here
blocks development. Item 6 blocks an App Store submission.

The device pass was NOT purely off-repo in the end: it found that iOS reports a
`screen_view` of its own, now disabled by `FirebaseAutomaticScreenReportingEnabled`
in `ios/Runner/Info.plist` (the reasoning is in `.claude/rules/analytics.md`).

Built 2026-09-07. Implementation notes live in `.claude/rules/analytics.md` and
the Analytics section of `docs/ARCHITECTURE.md`; the current state of the code
is those two, never this file.

**Verified at build time:** `flutter analyze` → `No issues found!`;
`flutter test` → **3547 passed**, exit 0.

---

## What already exists, so nobody re-does it

- `firebase_analytics ^12.5.0` is in `pubspec.yaml`, and it is **SPM-safe**
  (`ios/firebase_analytics/Package.swift`) — no Podfile was introduced and none
  is needed.
- `ios/GoogleService-Info.plist` already exists at the `ios/` **root** and is
  already bundled into Runner's resources (`project.pbxproj:462`). Firebase is
  still configured from `--dart-define` through `lib/firebase_options.dart`.
  **`flutterfire configure` was NOT run and must not be** — it rewrites that
  file into the literal-values style and breaks the define-based setup.
- `ios/Runner/PrivacyInfo.xcprivacy` already declares **Product Interaction**
  (added with this work). Item 6 is about App Store Connect, which is a
  *separate* declaration that has to agree with it.
- `ANALYTICS_DEBUG` is in `dev/firebase.local.example.json`. Copy it into your
  own `dev/firebase.local.json` (gitignored) if you want it there rather than
  spelled on the command line.

---

## 1. Enable Google Analytics on the Firebase project — DO THIS FIRST

Firebase Console → *Project settings → Integrations → Google Analytics*, and
confirm the iOS app (`net.vogas.scheduling`) is linked to a GA4 property.

**Without this the SDK ships, runs, and reports nothing.** There is no error
and no warning anywhere — in the app, in the console or in the logs. It looks
exactly like an app nobody is using, which is the one failure mode that could
survive a whole release unnoticed.

- [x] Google Analytics enabled on `schedulingapp-88727`
- [x] The iOS app appears under the linked GA4 property's data streams

## 2. Register custom dimensions (or the parameters are invisible in reports)

Firebase Console → *Admin → Custom definitions → Create custom dimension*.

Custom **event parameters are collected immediately but are not queryable in
reports until registered.** They will show in DebugView and in the raw event
count either way, so this is easy to assume is working when it is not.

**The allowlist collects 25 parameters, not the 10 this doc listed until
2026-09-10** — and 9 of them are numeric, which is the *Custom metrics* tab, a
different form. Registration is also NOT retroactive: whatever is missing when a
release ships is unqueryable for that entire reporting window.

Event-scoped **dimensions**, the 16 text parameters:

| Parameter | Values it sends |
|---|---|
| `source` | `calendar`, `clients_tab`, `client_detail`, `inline_add_client`, `dashboard`, `history`, `day_route`, `employees`, `notification`, `notice` |
| `surface` | `clients`, `history`, `appointment_form`, `field_record` |
| `status` | an appointment status, AND the new employee status |
| `scope` | `single`, `series` |
| `repeat` | `none`, `fourMonths`, `sixMonths`, `oneYear` |
| `view_mode` | `day`, `week` |
| `direction` | `today`, `picked`, `week_strip`, `day` |
| `filter_name` | `none`, `type`, `building`, `archived`, `sort`, `year`, `employee`, `status` |
| `filter_value` | the chosen type / sort / status slug |
| `setting_name` | `app_lock`, `live_activity`, `theme`, `text_scale`, `language` |
| `setting_value` | `on`/`off`, theme mode, a 2-dp text scale, locale code |
| `action` | `call`, `email`, `directions`, `link`, AND `archive`/`unarchive` |
| `period` | `today`, `week`, `month` |
| `role` | `admin`, `employee` — the event-scoped twin of `user_role`, on `login` |
| `method` | `password` — the only value today, lowest value to register |
| `feature` | nothing yet; `logFeatureUsed` has no call site |

Event-scoped **dimensions**, the 8 numeric ones — they belong on the dimensions
tab, NOT metrics. `bucketCount` maps 6-10 to `10` and 100+ to `500`, so a metric
would sum and average bucket CEILINGS; a dimension gives the distribution the
bucketing exists to produce. The 1/0 flags likewise segment better than they sum.

| Parameter | What it sends |
|---|---|
| `assignee_count` | bucketed: 1-5, 10, 25, 50, 100, 500 |
| `photo_count` | same buckets |
| `query_length` | bucketed: 0, 2, 5, 10, 20 — never the text |
| `has_photos` · `is_personal` · `is_all_day` · `is_day_off` · `is_multi_day` | 1/0 |

Event-scoped **metric** — `delay_minutes`, unit **Minutes**. The one raw,
unbucketed number, so the only genuine metric.

Register as **user-scoped** dimensions:

| Property | Answers |
|---|---|
| `user_role` | **the admin-vs-employee comparison — the headline ask.** Without it, every "which features do admins use?" question is unanswerable in the console even though the data is being collected. |
| `app_locale` | EN vs FR usage |
| `build_env` | lets you EXCLUDE debug traffic from reports |

Limits are 50 event-scoped dimensions, 25 user-scoped and 50 metrics, so this
uses roughly half the event budget.

- [x] 24 event-scoped dimensions registered (owner, 2026-09-10)
- [x] 3 user-scoped dimensions registered (owner, 2026-09-10)

## 3. Mark key events as conversions (optional)

Firebase Console → *Analytics → Events → toggle "Mark as key event"*.
Candidates: `appointment_created`, `job_completed`, `client_created`. This only
changes how prominently they are reported; nothing in the app depends on it.

- [ ] Decided (fine to skip)

## 4. Verify events on a device or simulator (Mac-gated)

Both halves are needed. Only having one is why "DebugView shows nothing" is the
usual first result — the define decides whether events are **collected**, the
launch argument decides whether they **stream live**.

```bash
flutter run --dart-define-from-file=dev/firebase.local.json --dart-define=ANALYTICS_DEBUG=true
```

…and in Xcode: *Product → Scheme → Edit Scheme… → Run → Arguments → Arguments
Passed On Launch* → add `-FIRDebugEnabled`.

Then Firebase Console → *Analytics → DebugView*, pick the device top-left.

Verify one of each shape rather than every event — if these four work, the
plumbing is right and the rest is the same code path:

- [x] A **screen view**: switch hub tabs, confirm exactly ONE `screen_view` per
      tab arrival. Then reach Clients from the drawer instead — still one.
      (This is the observer/hub-shell split; a double here is the one real
      regression risk in the design.)
- [x] A **parameterised custom event**: create an appointment, confirm
      `appointment_created` carries `repeat`, `assignee_count`, `has_photos` etc.
- [x] A **user property**: DebugView → the device card → *User properties* →
      `user_role` reads `admin` or `employee`.
- [x] **No PII anywhere** in the payloads — every parameter on all 11 observed
      event types scanned for `@`, any 7+ digit run and address words: clean.
      Every value was a slug or a bucketed number.
- [ ] The four spot-checks item 4 names by hand are still UNOBSERVED, because
      that pass exercised no search, photo, note or contact action:
      `search_used` (no query text), `note_added` (no note), `photo_added` (no
      filename), `contact_action` (no phone number). The signatures make them
      structurally safe — `logSearchUsed` takes an `int`, `logContactAction` a
      slug — but that is an argument from types, not an observation.

**Turn it back off when finished** — remove `-FIRDebugEnabled` from the scheme,
or that device keeps streaming every session into DebugView.

- [x] Debug streaming turned back off (the scheme flag was never enabled —
      `simctl launch ... -FIRDebugEnabled` passed it, then `-FIRDebugDisabled`
      cleared it; `flutter run` cannot pass an iOS launch argument at all)

## 5. Confirm the debug/production split actually holds

Cheap, and it is the thing that protects the numbers for the rest of the
product's life:

- [x] Run **without** `ANALYTICS_DEBUG` and confirm nothing is collected —
      verified 2026-09-10 on the simulator: `Analytics collection disabled`
      and zero events logged.
- [ ] **Consider `FIREBASE_ANALYTICS_COLLECTION_ENABLED=NO` in `Info.plist`.**
      That verification also exposed a ~0.8 s hole in the split.
      `setAnalyticsCollectionEnabled` PERSISTS natively in `NSUserDefaults`, so
      the SDK starts each launch on the PREVIOUS run's setting and only obeys
      this build at `setCollectionEnabled` — the clean build logged
      `collection enabled` at 22:19:06.175 and `collection disabled` at
      22:19:07.011. Anything the SDK fires in that window (`session_start`,
      `user_engagement`) is collected under the old setting, so a debug session
      on a previously-debug-enabled device can still put a session into the
      production property. The Info.plist key makes the SDK start disabled and
      ignore the persisted value, which closes it; release builds lose nothing
      real, since `!kDebugMode` enables collection a second into launch and
      `session_start` then fires normally.
- [ ] After a real release, confirm `build_env` reports `release` for the fleet

## 6. App Store Connect privacy labels — SUBMISSION BLOCKER

`ios/Runner/PrivacyInfo.xcprivacy` now declares **Product Interaction** (Usage
Data), `Linked: false`, `Tracking: false`. **The App Store Connect answers are a
separate declaration and must agree with it.**

App Store Connect → the app → *App Privacy* → add **Usage Data → Product
Interaction**, purpose *Analytics*, not linked to identity, not used for
tracking.

**Device ID needed `Analytics` adding too** (2026-09-10). It was declared
App Functionality only, for the FCM push token, but Analytics also collects a
vendor / app-instance identifier and Firebase's own Apple-label guidance lists
Device ID under Analytics — so the manifest was still describing the
pre-analytics app. `Linked` stays `true` there: that is the FCM token mapping to
a `users` doc, not anything analytics does. The counter-argument (the
app-instance id is app-scoped, not device-level) was heard and rejected — the
cost of disclosing is a checkbox, the cost of under-disclosing is a rejection or
a post-ship label correction.

The "not linked" answer for Product Interaction rests on two facts about the
code, **both re-verified 2026-09-10**: `setUserId` has zero call sites (the only
occurrence in `lib/` is a comment in `analytics_identity_listener.dart` saying
so), and no analytics parameter carries a name, email, phone, address, note or
filename — enforced by the allowlist in `AnalyticsParams.allParams`, not by
convention. The device pass also scanned every payload across 11 event types for
`@`, 7+ digit runs and address words: clean.

**Do NOT add Advertising Data or IDFA, and keep tracking `No` everywhere.** That
answer is only true while release builds carry the item-7 flag.

- [ ] **Owner has read and agreed** with the `PrivacyInfo.xcprivacy` entries
- [ ] App Store Connect: **Usage Data → Product Interaction**, purpose
      Analytics, not linked, not tracking
- [ ] App Store Connect: **Identifiers → Device ID** purposes now include
      Analytics alongside App Functionality

## 7. Build releases with the ad-id dropped — RELEASE STEP

```bash
FIREBASE_ANALYTICS_WITHOUT_ADID=true flutter build ios --release --dart-define-from-file=dev/firebase.local.json
```

The plugin's `Package.swift` reads that env var and links `FirebaseAnalyticsCore`
instead of `FirebaseAnalytics`, which removes IDFA / advertising-identifier
collection. This app sells no ads and needs no attribution, so the ad id buys
nothing and costs a heavier privacy disclosure and a possible ATT prompt.

**Dropping this flag is what would put App Tracking Transparency back on the
table** — that is why it is a documented release step and not a preference.
Recorded in `docs/IOS_MAC_BUILD.md` Phase G step 2.

- [ ] Release build uses the flag
- [ ] `PrivacyInfo.xcprivacy` still declares `NSPrivacyTracking: false`

## 8. Wait for the reporting window before judging anything

Custom events appear in **DebugView within seconds** but in **standard reports
after ~24 hours**, and Retention/Cohort reports need days of data. An empty
Events page on release day is expected, not a bug — check DebugView instead.

- [ ] Re-check the Events page ~48h after the release

---

## Open decisions (no action needed, recorded so they aren't re-litigated)

- **`app_version` is deliberately NOT a user property.** Firebase reports app
  version, device model and OS version as automatic dimensions, so declaring one
  would spend a slot on data the console already has. Ask if you want it anyway.
- **Sign-out does not call `resetAnalyticsData`.** That would mint a new app
  instance id and destroy retention measurement, which is an explicit goal. The
  accepted cost: two people signing in on one handed-over device share an
  instance id. Nothing identifying is attached to it, and `user_role` is cleared
  on sign-out.
- **`search_used` carries no result count.** The only place that knows a search
  ran is the debounce commit, and the results have not been fetched there; a
  count reported later would be a second event for one search.
- **`job_completed` carries no `has_notes`.** The parent `fieldNotes` string is
  the legacy write path (crew notes live in a subcollection since 2026-09-06),
  so reading it would under-report to near zero. `note_added` already answers
  how often notes are written.
- **`logFeatureUsed()` has no call site.** It exists because the spec asked for
  it, and it is the extension point for the next feature; every meaningful
  action today got a named event instead. A two-line delete if you would rather
  not carry an uncalled method.
