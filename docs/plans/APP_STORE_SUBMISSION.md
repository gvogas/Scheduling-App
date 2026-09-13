# App Store Submission — ES Pro

`net.vogas.scheduling` · team **H5XWLU87AX** · branch `redesgin` · scope
**App Store only** (iPhone + iPad). **The version lives in `pubspec.yaml`, not
here** — it was pinned at 1.45.0+72 in this line until 2026-08-15 and had gone
two releases stale (1.46.0+73, then 1.46.1+74); read `pubspec.yaml` and
`CHANGELOG.md` for what is cut.

> ## ⚠️ THE APP IS LIVE — this is no longer a launch runbook
>
> **Recorded 2026-08-11 on the owner's report:** ES Pro was **accepted by Apple**
> and is on the App Store; **1.45.0+72 is the 4th update** since that first
> release. Read every "first store cut" / "first upload" instruction below as
> **history**, not as a pending task.
>
> **Part 13's list has not been reconciled against four shipped submissions** —
> items like "confirm the app record", "pricing = Free", "add the French
> localization", "upload screenshots" and "attach the reviewed build and submit"
> were almost certainly done during the first release, but nobody ticked them
> here, so the count is not trustworthy. Treat an unticked box as *unknown*,
> not as *outstanding*. The genuinely recurring parts of this file are the **Mac
> build runbook** (Parts 2–5), the **ASC copy blocks** (Part 11), and the
> **device checks** (Part 6).

Single source of truth for shipping this app: the Mac build runbook, the
material that gets typed into App Store Connect (ASC), and the remaining
checklist. **Merged 2026-07-19** from `IOS_APP_STORE_HANDOFF.md`,
`APP_STORE_CONNECT_SUBMISSION.md`, and `APP_STORE_SUBMISSION_CHECKLIST.md`,
which contradicted each other in several places — the conflicts are resolved
inline and flagged with **[was contradictory]** so you can see what changed.

Legend: `[x]` done/verified · `[ ]` to do · ⚠️ blocker

Ordered: Part 1 happens on the Windows box, Parts 2–6 on the Mac, Parts 7–12 in
a browser. **Part 13 is the short list of what's actually left** — start there
if you just want to know what's blocking.

Server-side work is done and verified live: App Check is **enforced on every
callable** in production, and the deployed Firestore/Storage rules match the
repo. A misconfigured iOS App Check provider therefore does **not** degrade
gracefully — **every callable fails** — so the App Attest steps are the critical
path.

Contacts: George Vogas — george@vogas.net (also the "person in charge of
personal information" for the privacy policy).

---

## Part 0. What the app collects — ground truth for everything below

Confirmed by reading `lib/`, `functions/`, `ios/Runner/Info.plist`, and
`pubspec.yaml`. Everything is stored in **Firebase** (Firestore / Storage /
Crashlytics / Cloud Messaging). There are **no advertising or analytics SDKs**
(no `firebase_analytics`, no AdMob, no third-party trackers) — verified against
`pubspec.yaml`. `NSPrivacyTracking = false` is correct.

| What | Where in code | Sent off device? |
|---|---|---|
| Account email, display name, phone, role | `users/{id}` Firestore doc | Yes (Firestore) |
| Firebase auth UID / users-doc id | `users/{id}`, `usersByUid/{uid}` | Yes |
| Client contact records (name, business, phone, mobile, email, street/city/province/postal/country, contacts array) | `clients/{id}`, entered by admins | Yes |
| Appointment content (date/time, assignees, status, notes, address) | `appointments/{id}` | Yes |
| Appointment photos | Storage `appointments/*/images/*` (JPEG/PNG, validated) | Yes |
| **Precise location**, while the app is open, of active staff and admins who turned on Staff map location | `users/{docId}/presence/location` (`geolocator` foreground stream; latest position only) | Yes |
| FCM push token + per-device locale | `users/{docId}/fcmTokens/{token}` | Yes |
| APNs Live Activity tokens | `users/{docId}/liveActivityTokens/{token}` | Yes |
| Crash diagnostics | Firebase Crashlytics | Yes |

**Contacts is NOT a collected data type.** `flutter_contacts`
(`contact_export_launcher.dart`) only **writes** a client the admin already has
into the device address book, and reads back **only the single contact it
created** to keep it in sync. It never harvests the address book and never
uploads device contacts. So the app **accesses** the Contacts API (needs
`NSContactsUsageDescription`, already present) but does **not collect** Contacts
for App Privacy purposes. Do not declare Contacts on the nutrition label.

**No** financial info, health, browsing history, search history, or purchases
leave the app. Wave Accounting runs entirely server-side (Cloud Functions); the
app never reads Wave client-side, so no accounting data is collected by the app.

The **Siri snapshot** and **home-screen widget** write a schedule payload into
the App Group `group.net.vogas.scheduling`. That stays on-device and carries
only what the intents speak (client name, times, address, status) — never notes,
phone, or photos — so it adds no new collected data type.

---

## Part 1. Before leaving the Windows box

- [x] **Commit + push the branch** so the Mac clone has the current tree.
- [x] **CLAUDE.md is gitignored** (`.gitignore:20`) — committing it needs
  `git add -f CLAUDE.md`. (`.claude/` rules/skills are also ignored at
  `.gitignore:151` and will NOT be on the Mac unless force-added too.)
- [x] **Carry these gitignored files out-of-band** (AirDrop/USB — not email):
  - `dev/.env` → `dev/.env` (all 8 keys incl. `IOS_API_KEY` / `IOS_APP_ID` /
    `IOS_MAPS_API_KEY`; it's a bundled asset — the app won't boot without it)
  - `ios/GoogleService-Info.plist` → `ios/` **root** (NOT `ios/Runner/` — the
    Xcode project references it at the root group and it's already in the
    Resources build phase)
  - (`android/app/google-services.json` used to be listed here as "skip". The
    whole `android/` tree was deleted on 2026-08-05 — iOS is the only platform.)

## Part 2. Mac environment

- [x] **Xcode** — latest stable (Firebase iOS SDK 12.x requires Xcode 16.2+).
  Sign into the Apple ID for team **H5XWLU87AX**; Developer Program membership
  must be active.
- [x] **Flutter 3.44.1 stable** — match the Windows box version to avoid
  `Package.resolved`/codegen churn. `flutter doctor` until clean.
- [x] **No CocoaPods.** The project uses **Swift Package Manager** — there is no
  Podfile and never will be. Ignore any older notes mentioning `pod install` or
  `${PODS_ROOT}`. Xcode resolves `firebase-ios-sdk` (pinned in
  `Package.resolved`) on first open.
- ⚠️ **Flutter SPM iOS-floor bug — patch the local SDK (redo after every
  `flutter upgrade`).** Flutter hardcodes the generated
  `FlutterGeneratedPluginSwiftPackage/Package.swift` to `.iOS("13.0")`
  (`packages/flutter_tools/lib/src/darwin/darwin.dart`, `deploymentTarget()` →
  `ios => Version(13, 0, null)`), **ignoring** the app's real target. The build
  then fails fast (~30s, before real compile) with `Target Integrity … requires
  minimum platform version … but this target supports 13.0` for every Firebase
  product + `home-widget`. Fix: edit that switch arm to **`Version(18, 0, null)`**
  to match the app's floor, then `rm bin/cache/flutter_tools.{stamp,snapshot}`
  and run any `flutter` command to force a tool rebuild (source edits alone
  don't rebuild the snapshot). Verify with
  `grep iOS ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift`
  → must show `.iOS("18.0")`. `flutter upgrade` reverts the edit — reapply it.
  **[was contradictory]** The old runbook said patch to `15.0`; the deployment
  target moved to 18.0 on 2026-07-19, so 15.0 would now under-declare it.
- [x] **Do NOT run `flutterfire configure`.** `lib/firebase_options.dart`
  already builds iOS options from `dev/.env` with
  `iosBundleId: net.vogas.scheduling` — re-running rewrites the file into the
  literal-values style and breaks the env-based setup.
- [x] **First Xcode open resolves the SPM packages** — `firebase-ios-sdk`,
  `google_maps_flutter_ios_sdk9` (Maps SDK 9.x), `live_activities`,
  `saver_gallery`. No Podfile; same SPM flow throughout.

## Part 3. Clone, restore, first run

- [x] `git clone` → checkout the release branch → drop the two carried files
  into place (Part 1).
- [x] `flutter pub get`. l10n regenerates automatically on build
  (`generate: true`; `lib/l10n/.gen/` is gitignored — `flutter gen-l10n` runs it
  manually if the IDE complains before the first build).
- [x] **Smoke run on the Simulator is fine at this stage** — debug builds use
  `AppleDebugProvider`. On first run the console prints an App Check **debug
  token**: register it in Firebase Console → App Check → apps → iOS app → Manage
  debug tokens. (Unregistered-token symptom: every callable and non-cached
  Firestore read fails `permission-denied` while cached reads work — looks
  collection-specific, isn't.)

## Part 4. Xcode project state — verify, don't redo

Open `ios/Runner.xcworkspace`.

> **All items below are already DONE in the committed project** (verified
> 2026-07-11, extended 2026-07-19). Kept as reference so you can confirm rather
> than repeat them.

- [x] **App Attest capability** — `Runner.entitlements` has
  `com.apple.developer.devicecheck.appattest-environment = production`, wired
  via `CODE_SIGN_ENTITLEMENTS` on all three configs. (A `development` value
  breaks attestation on TestFlight/App Store builds.)
- [x] **Crashlytics dSYM upload Run Script** — Build Phases, **last** phase,
  "Based on dependency analysis" unchecked. SPM path (not the CocoaPods one):

  ```
  "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
  ```

  Input files:
  ```
  ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}
  ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}
  ${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist
  $(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/GoogleService-Info.plist
  $(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)
  ```
- [x] **Release + Profile `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`**
  (Debug = `dwarf`).
- [x] **Signing** — automatic, team H5XWLU87AX, bundle `net.vogas.scheduling`.
- [x] **Push Notifications capability** — `aps-environment = production` so
  TestFlight/App Store builds hit the production APNs gateway.
- [x] **App Groups** `group.net.vogas.scheduling` on Runner **and** both
  extensions.
- [x] **Deployment target iOS 18.0** on all targets (bumped from 15.0 on
  2026-07-19 — the Siri extension needs 16 and the Live Activity Directions
  button's returnable `OpenURLIntent` needs 18, so the whole app moved to an
  18.0 floor and iOS 15–17 users are dropped). Well above App Attest's 14+
  requirement. **[was contradictory]** the old runbook recorded 15.0 in three
  places, including "extension deployment target set to iOS 15.0".
- [x] **`ScheduleWidget` extension** — hosts the home-screen widget and the
  `JobLiveActivity` Live Activity in one `WidgetBundle`.
- [x] **`SiriIntents` App Intents extension** — created + embedded in Runner
  2026-07-19, bundle id `net.vogas.scheduling.SiriIntents`, entitlements
  `SiriIntentsExtension.entitlements` sharing the App Group.
- [x] **iPad: KEEP (decided 2026-07-08).** `TARGETED_DEVICE_FAMILY = "1,2"`
  stays — the app ships for iPhone **and** iPad. Consequences: the listing needs
  an iPad screenshot set, App Review will test on iPad, and Part 6 verification
  should include one. The `isSplitLayout` nav-rail + two-pane chrome is what
  iPad users get.

## Part 5. Firebase Console (any browser)

- [x] App Check → apps → **iOS app → App Attest registered** as the attestation
  provider. No `.p8` key — that's DeviceCheck, which this app does not use. The
  console provider MUST match the code (`AppleAppAttestProvider` in `main()`).
- [x] **APNs Auth Key** created; `.p8` uploaded to Cloud Messaging for the iOS
  app (2026-07-11). Key ID / Team ID noted.
- [x] Keep the debug-token registrations for the Simulator/dev devices.
- [x] **Firestore TTL policies** — **VERIFIED IN CONSOLE 2026-07-20.** Exactly
  two policies exist, both `Serving`: `appointmentReminders` and
  `appointmentOverduePrompts`, each on `expiresAt` with a 7-day expiration
  offset. Ledger docs self-delete ~7 days after creation.
  **[was contradictory]** `docs/CLOUD_FUNCTIONS.md` and CLAUDE.md both listed
  this as still outstanding; the runbook recorded it done 2026-07-11. The
  console now settles it — and confirms the 2026-07-19 indexes deploy's "2 field
  overrides" message was reporting exactly these two policies.
- [x] **TTL on the other `expiresAt` collections — added 2026-07-20.**
  `liveActivityTokens`, `rateLimits`, and `signupCodes` now have policies on
  `expiresAt`. All are also swept in-code, so this is storage housekeeping.
- [ ] **`liveActivityCards` TTL — can't be created yet.** Firestore only offers
  collection groups that already contain documents, and no card marker has ever
  been written (the feature has never run on a device). **Add it after the first
  on-device Live Activity test** creates the collection: field `expiresAt`,
  offset `0`.
  > **Offset must be `0` on every TTL policy in this project.** The code bakes
  > the full lifetime into `expiresAt` itself (`LEDGER_TTL_MS` 7d,
  > `INVITE_CODE_TTL_MS` 14d, `CARD_TTL_MS` 12h, the limiter's window), so
  > `expiresAt` *is* the deletion instant. A non-zero offset adds to it and
  > silently doubles retention. All five policies were normalized to `0` on
  > 2026-07-20 — `signupCodes` (was 14d on top of 14d → ~28) and both ledgers,
  > `appointmentReminders` / `appointmentOverduePrompts` (were 7d on top of 7d
  > → ~14). Retention now matches what the code and the privacy policy state.
  >
  > **An offset is immutable once set** — changing one means delete → wait for
  > the policy to fully disappear from the list → recreate. Recreating too soon
  > fails with `400: Cannot modify TTL offset`.
  >
  > Shortening the ledgers is safe and cannot cause duplicate pushes: a ledger
  > only guards an *eligible* job, and eligibility ends far sooner than 7 days
  > (the reminder sweep needs `startTime > now`, the overdue sweep looks back
  > 48h). Expect a one-time burst of deletions as docs older than the new
  > threshold become eligible.
  > ⚠️ **Never run `firebase deploy --only firestore:indexes --force`** on this
  > project. TTL policies are stored as *field overrides*; `--force` deletes any
  > override not declared in `firestore.indexes.json`, which would silently
  > remove them.

## Part 6. Verify on real hardware — App Attest does NOT work on the Simulator

> **Re-confirmed passing 2026-09-09 (owner-reported), with ONE exception: the
> Siri phrases box below is still unrun.** Every other check here was already
> ticked and was reported passing again on hardware that day. Recorded on the
> owner's word, with no console capture behind any individual box, so a later
> contradiction means "re-run that check" rather than "a regression against a
> known-good baseline". Siri Phases 1–3 are code-complete and have never been
> exercised by voice — see `2026-07-19-siri-app-intents-implementation.md`.

- [x] `flutter run --release` on a physical iPhone.
- [x] Sign in, then **exercise a callable end-to-end** to prove attestation —
  type an address in the appointment form (`placesAutocomplete`) or open
  Settings → Wave as admin (`waveGetConnection`). If App Attest is
  misconfigured these fail while plain Firestore reads may still work.
- [x] Device-only feature sweep (never covered by the test harness): camera
  capture, photo-library picker, contacts save-flow, Face ID app-lock, map
  launch, phone/email launchers.
- [x] Both locales: flip the device to French and spot-check.
- [x] Push: employee sign-in writes `users/{docId}/fcmTokens/{token}`, sign-out
  deletes it; assign/reschedule/cancel/unassign each deliver the correct
  localized push with the app **killed**; reminder fires ~28 min out and writes
  its ledger doc; digest and overdue prompts fire; FR device gets French text.
- [x] **iPad pass** — split/master-detail layouts at tablet width.
- [x] **Admin live staff map renders + resolves addresses.** `AppDelegate`
  parses `IOS_MAPS_API_KEY` from the bundled `dev/.env` and calls
  `GMSServices.provideAPIKey(...)`; a missing key means a blank map plus a
  console line, never a crash. Backend is live. Grant location, confirm your own
  pin plus other staff appear with a fresh timestamp and a resolved address.
- [x] **Routes API — VERIFIED IN CONSOLE 2026-07-20.** The API is enabled on the
  project, and the server-side Maps key's API restriction lists all four it
  needs: Geocoding API, Places API, Places API (New), **Routes API**. So the
  travel-time leave-now reminders are not silently falling back to fixed 30-min
  timing. (Cloud Functions logs corroborate: zero `travel:` warnings in 8 days,
  and any misconfiguration would log a 403 on every attempt.)
- [x] **Notification tap deep-link** — tapping a push opens the specific
  appointment's detail sheet (not just the calendar root).
  **[was contradictory]** the old runbook listed deep-linking as a known
  deferral; it was implemented and taps now resolve `data.appointmentId`.
- [x] **Home-screen widget** — add in all three sizes, today's jobs render, a
  job rolls off the small widget once it starts, sign-out clears the widget.
- [x] **Wake-on-push widget refresh** — with the employee's app **fully closed**,
  have an admin move a job for later today. The widget updates **without opening
  the app** (`content-available` wakes `firebaseMessagingBackgroundHandler`,
  which rewrites the App Group payload). The visible push still shows alongside.
  iOS throttles background wakes under Low Power Mode — allow a short delay.
- [x] **Live Activity card** (new in 1.34, deployed 2026-07-19) — with a job
  scheduled, confirm the "time to leave" card appears on the Lock Screen and in
  the Dynamic Island, the Directions button opens Maps, it flips to "On site" at
  the start time, and it clears when the job is marked complete. Confirm the
  Settings → **Live job card** toggle ends a showing card. The two composite
  indexes it needs were **verified `READY` 2026-07-20** — while they were still
  building the sweep logged `liveActivity: on-site query failed`; that stopped
  once they finished, so the server side is ready for this test.
- [ ] **Siri phrases** (Phase 1) — "what's on my schedule today", "what's my
  next appointment", and the job-count phrase, per
  `ios/SiriIntents/README.md`.
- [x] **Time Sensitive Notifications entitlement** — needed for the `leaveNow`
  interruption level. Confirm it's on the Runner target.

## Part 7. Archive + upload

- [ ] Clean baseline for the first store cut: `flutter clean && flutter pub get`,
  then Xcode → **Product → Clean Build Folder** (⇧⌘K).
- [ ] `flutter build ipa` (or Xcode → Product → Archive → Organizer →
  Distribute). Upload via Organizer or Transporter.
- [ ] **TestFlight internal testing first.** TestFlight builds are store-signed,
  so App Attest works there. Do **NOT** use Firebase App Distribution for iOS —
  sideloads can't mint verified App Check tokens and are blocked by design.
- [ ] Post-upload: Crashlytics console shows the build's dSYMs processed (**no
  "Missing dSYMs" banner**) — that proves the Part 4 Run Script works.
- [ ] Smoke-test the TestFlight build on device: sign in + one callable.

---

## Part 8. ASC → App Privacy nutrition labels

Answer the ASC flow as **Yes, we collect data**, then declare exactly these
types. For **every** type: **Used for tracking = No** (no tracking across apps
or websites). "Linked to identity" is Yes wherever the data sits under a
signed-in user's account.

| Data type (Apple category) | Collected | Linked to identity | Tracking | Purpose | Notes |
|---|---|---|---|---|---|
| **Name** (Contact Info) | Yes | Yes | No | App Functionality | Account display name + client names entered by admins |
| **Email Address** (Contact Info) | Yes | Yes | No | App Functionality | Sign-in email + client emails |
| **Phone Number** (Contact Info) | Yes | Yes | No | App Functionality | Account phone + client phone/mobile |
| **Physical Address** (Contact Info) | Yes | Yes | No | App Functionality | Client street/city/postal + job addresses |
| **Precise Location** (Location) | Yes | Yes | No | App Functionality | Background GPS for time-to-leave reminders + admin live staff map; active staff and assigned admins only |
| **Photos or Videos** (User Content) | Yes | Yes | No | App Functionality | Photos attached to appointments |
| **Other User Content** (User Content) | Yes | Yes | No | App Functionality | Appointment notes / job details |
| **User ID** (Identifiers) | Yes | Yes | No | App Functionality | Firebase auth UID / users-doc id |
| **Device ID** (Identifiers) | Yes | Yes | No | App Functionality | FCM push token (per-device, for job notifications) |
| **Crash Data** (Diagnostics) | Yes | No | No | App Functionality | Firebase Crashlytics |

Notes:
- Precise Location is the one type most likely to draw a follow-up. It is **App
  Functionality**, **not** tracking or advertising. It is **foreground-only**:
  the `location` background mode was removed 2026-07-27 after a guideline 2.5.4
  rejection. Justification is in the Part 12 review notes.
- Crash Data is declared **not linked to identity** — the app does not call
  Crashlytics `setUserId` with PII. No Performance Data is declared (no Firebase
  Performance SDK ships).
- If ASC asks required vs optional: account and client data are required;
  location is optional (the app degrades gracefully when denied or limited to
  "while using").

⚠️ **This is the one open compliance item.** The questionnaire was completed
2026-07-11, but background GPS presence landed 2026-07-13 — *after* — so the
live declaration is **missing Location**. Update it to the table above before
submitting. The privacy *policy* webpage already covers this (section 2.4,
updated 2026-07-13); only the ASC questionnaire is stale.

**[was contradictory]** the old checklist also claimed
`PrivacyInfo.xcprivacy` had an empty `NSPrivacyCollectedDataTypes` "left as-is
on purpose". That is no longer true — the manifest was populated and verified
2026-07-19 (Part 9). The two now agree, which matters because Apple
cross-checks them.

## Part 9. iOS Privacy Manifest (`PrivacyInfo.xcprivacy`)

The repo tracks two manifests. `ios/Runner/PrivacyInfo.xcprivacy` **already
matches the block below** (verified 2026-07-19) — its
`NSPrivacyCollectedDataTypes` array is fully populated and matches Part 8, so
**no code change is required**. This is the authoritative reference; diff it
against the on-disk file if you need to confirm. The required-reason API entries
(UserDefaults `CA92.1` for `shared_preferences`, File Timestamp `C617.1` for
`path_provider` / `flutter_cache_manager`, System Boot Time `35F9.1`) are
present and correct — keep them.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<!-- Contact Info: Name -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeName</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Contact Info: Email Address -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeEmailAddress</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Contact Info: Phone Number -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePhoneNumber</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Contact Info: Physical Address -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePhysicalAddress</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Location: Precise Location -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePreciseLocation</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- User Content: Photos or Videos -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePhotosorVideos</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- User Content: Other User Content (appointment notes/details) -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeOtherUserContent</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Identifiers: User ID -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeUserID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Identifiers: Device ID (FCM push token) -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeDeviceID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<!-- Diagnostics: Crash Data -->
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeCrashData</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<false/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>35F9.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

**Widget manifest** (`ios/ScheduleWidget/PrivacyInfo.xcprivacy`): leave as-is.
The widget only reads the shared App Group payload via `UserDefaults` (already
declared with `CA92.1`) and collects nothing of its own.

Note: `NSPrivacyCollectedDataTypePhotosorVideos` is Apple's exact spelling (no
camel-case on "or") — do not "correct" it or manifest validation fails.

## Part 10. Store metadata — paste into ASC

Character limits are Apple's hard caps: App Name 30, Subtitle 30, Promotional
Text 170, Keywords 100, "What's New" 4000, Description 4000. Counts below were
verified with `wc -m` on 2026-07-19 — **re-verify in the ASC field before
saving**; ASC hard-rejects an over-limit value.

The app is bilingual: ASC needs **English (Canada)** as primary and **French
(Canada)** as a localization. Provide both for every text field.

### English (Canada) — primary

**App Name** (≤30) — 6 chars
```
ES Pro
```

**Subtitle** (≤30) — 29 chars
```
Schedule plumbing jobs & crew
```

**Promotional Text** (≤170) — 158 chars; editable any time without a new build
```
Book a job, send it to the right plumber, and the whole crew sees the change on their phone. Photos, client history, and traffic-timed reminders come with it.
```

**Keywords** (≤100, comma-separated, no spaces) — 99 chars
```
plumber,plumbing,scheduler,appointments,dispatch,crew,jobs,fieldservice,technician,calendar,clients
```

**Description** (≤4000)
```
ES Pro runs a plumbing business from one screen. Book a job, assign the right plumber, and everyone on the crew sees their day the moment it changes.

Made for the field:
- See your appointments by day, week, or month.
- Put one or more plumbers on a job. Each person sees only the work that is theirs.
- Keep every client's name, phone, address, and past visits in one place, and add a new client without leaving the booking screen.
- Snap photos on a job straight from the camera so the office sees the work that was done.
- Get a reminder when it is time to leave, timed to the real traffic between your last stop and the next one.
- Open a live map of where the crew is during the day.
- Mark jobs in progress and complete, and get a nudge when one runs past its end time.

Works where plumbers work:
- Book and edit jobs in a basement with no signal. Changes sync once you are back online.
- Get a push the moment a job is assigned, moved, or cancelled, even with the app closed.
- Add today's jobs to your home screen and see your next stop without opening the app.

In French and English:
- Switch languages any time. Every screen, notification, and reminder is bilingual.

ES Pro is built for a plumbing crew by the company that runs one. Sign-in is by invitation from your administrator, so the whole team stays on one shared schedule.
```

**What's New in This Version** — v1.46.2+75 (2026-08-16)
```
• Pick a date on a real calendar. Tapping a date row drops the whole month down
  underneath it, instead of a spinning wheel that showed three days at a time
  and covered the form. Start and end dates each get their own row, and days you
  can't book are greyed out.
• Job photos are checked against your account every time they're shown, and the
  permanent web links older versions created no longer keep working for someone
  whose account has been switched off. Photos now need a connection to load, and
  signing out clears them from the phone.
• Client edits reach Wave in seconds instead of minutes. Settings › Wave shows
  how many are still queued and how many failed, and Retry failed now reports
  what actually went through rather than what it queued up again.
• A client's typed name is kept. Saving a client could replace it with their
  phone number, and clients that already happened to are recovered.
• The 6 p.m. "tomorrow's jobs" notification no longer goes quiet for everyone
  once enough finished-but-never-closed jobs build up.
• Fixes throughout: photos vanishing from a job, a cancelled job being marked
  complete, saves rejected outright for a long name or address, one bad record
  blanking a whole screen, and a smoother scroll and search through a long
  History.
```

> **Covers three releases, because 1.46.0+73 and 1.46.1+74 were built but not
> separately submitted.** If either did go to ASC on its own, trim this block to
> what landed since — users only ever see the newest note, so it must describe
> the cut being uploaded, not the whole gap.

> **Write this block fresh for every update — it is per-version and users only
> ever see the newest one.** Name features with the wording the app actually
> uses (check `lib/l10n/app_en.arb` / `app_fr.arb`), or the note points at
> something nobody can find on screen: the copy above uses *My details*,
> *Time-to-leave alerts*, *Dashboard*, *Complete* and *Cancelled* for exactly
> that reason. Keep the FR block in step — it is a shipped store locale, not a
> nice-to-have.

<details>
<summary>Superseded: the first-release copy (kept for history)</summary>

```
First release of ES Pro on the App Store.

- Day, week, and month schedule for the whole crew
- Assign plumbers to jobs and keep client history in one place
- Job photos from the camera
- Traffic-timed "time to leave" reminders and a live crew map
- Push notifications when a job changes, plus a home-screen widget
- Works offline and syncs when you reconnect
- Full French and English
```
</details>

**Support URL** (required)
```
https://gvogas.github.io/es-pro-legal/support.html
```
**[was contradictory]** the materials doc called this a placeholder pointing at
the privacy-policy host; the checklist recorded a real `support.html` set in ASC
and live since 2026-07-11. The dedicated support page wins.

**Marketing URL** (optional) — leave blank or reuse the support URL.

**Privacy Policy URL** (required)
```
https://gvogas.github.io/es-pro-legal/
```
Source: `docs/legal/privacy-policy.html`, published as the Pages repo's
**index** — which is why the other legal pages link to it by absolute URL
rather than a relative `privacy-policy.html` that would 404.

**Terms of Service URL** (optional in ASC — App Information → "License
Agreement" if you want it on the product page; **not optional to the app**)
```
https://gvogas.github.io/es-pro-legal/terms-of-service.html
```
Source: `docs/legal/terms-of-service.html` — **published** to the `es-pro-legal`
Pages repo beside `support.html`, verified byte-identical 2026-08-11. The app
links to this URL in two places (`AppUrls.termsOfService`): the account-setup
consent checkbox, whose tick stamps `termsAcceptedAt`, and the Settings › Legal
row. **If the repo drifts from `docs/legal/`, every employee is accepting terms
that say something else** — republish it whenever that file changes, the same
discipline as the accessibility page below.

**Accessibility URL** (optional, App Store Connect → App Accessibility →
Accessibility Nutrition Labels → "Manage the accessibility URL"; shown on the
product page on every device except Apple TV)
```
https://gvogas.github.io/es-pro-legal/accessibility.html
```
Source lives at `docs/legal/accessibility.html` — publish it to the
`es-pro-legal` Pages repo beside `support.html`. It documents support for the
nine nutrition-label features (VoiceOver, Voice Control, adjustable text size,
dark interface, differentiate without colour alone, sufficient contrast,
reduced motion, captions, audio descriptions) plus known limitations. **Keep it
in sync with what you actually declare in the nutrition labels** — the two are
read side by side on the product page.

**Primary Category:** Business. **Secondary Category:** Productivity.

**Copyright:** `2026 Plombier Eau Secours`

### French (Canada) — localization

**Nom de l'app** (≤30)
```
ES Pro
```

**Sous-titre** (≤30) — 29 chars
```
Planifiez chantiers et équipe
```

**Texte promotionnel** (≤170) — 169 chars (an earlier "et rappels" wording was
171, over the cap)
```
Créez un rendez-vous, envoyez-le au bon plombier, et toute l'équipe voit le changement sur son téléphone. Photos, historique client, rappels selon la circulation inclus.
```

**Mots-clés** (≤100, séparés par des virgules, sans espaces) — 95 chars
```
plombier,plomberie,horaire,rendezvous,repartition,equipe,chantier,technicien,calendrier,clients
```

**Description** (≤4000)
```
ES Pro gère une entreprise de plomberie à partir d'un seul écran. Créez un rendez-vous, assignez le bon plombier, et toute l'équipe voit sa journée dès qu'elle change.

Pensé pour le terrain :
- Consultez vos rendez-vous par jour, par semaine ou par mois.
- Assignez un ou plusieurs plombiers à un chantier. Chacun ne voit que ses propres tâches.
- Gardez le nom, le téléphone, l'adresse et les visites passées de chaque client au même endroit, et ajoutez un nouveau client sans quitter l'écran de réservation.
- Prenez des photos sur le chantier directement avec l'appareil photo pour que le bureau voie le travail réalisé.
- Recevez un rappel au moment de partir, calculé selon la circulation réelle entre votre dernier arrêt et le suivant.
- Ouvrez une carte en direct de la position de l'équipe pendant la journée.
- Marquez les chantiers en cours et terminés, et recevez un rappel lorsqu'un chantier dépasse son heure de fin.

Fonctionne là où travaillent les plombiers :
- Créez et modifiez des chantiers dans un sous-sol sans réseau. Les changements se synchronisent une fois de retour en ligne.
- Recevez une notification dès qu'un chantier est assigné, déplacé ou annulé, même l'app fermée.
- Ajoutez les chantiers du jour à votre écran d'accueil et voyez votre prochain arrêt sans ouvrir l'app.

En français et en anglais :
- Changez de langue à tout moment. Chaque écran, notification et rappel est bilingue.

ES Pro est conçu pour une équipe de plomberie par l'entreprise qui en exploite une. La connexion se fait sur invitation de votre administrateur, pour que toute l'équipe partage le même horaire.
```

**Nouveautés de cette version** — v1.46.2+75 (2026-08-16)
```
• Choisissez une date sur un vrai calendrier. Toucher une ligne de date déroule
  le mois complet en dessous, au lieu de la roulette qui affichait trois jours à
  la fois et masquait le formulaire. Les dates de début et de fin ont chacune
  leur ligne, et les jours non réservables sont grisés.
• Les photos de chantier sont vérifiées avec votre compte à chaque affichage, et
  les liens web permanents créés par les versions précédentes ne fonctionnent
  plus pour une personne dont le compte a été désactivé. Les photos ont
  maintenant besoin d'une connexion pour s'afficher, et la déconnexion les
  efface de l'appareil.
• Les modifications de clients atteignent Wave en quelques secondes plutôt qu'en
  quelques minutes. Paramètres › Wave indique combien sont en attente et combien
  ont échoué, et Réessayer indique maintenant ce qui est réellement passé plutôt
  que ce qui a été remis en file.
• Le nom saisi pour un client est conservé. L'enregistrement pouvait le
  remplacer par son numéro de téléphone; les clients déjà touchés sont rétablis.
• La notification de 18 h « chantiers de demain » ne cesse plus d'être envoyée à
  tout le monde lorsque trop de chantiers terminés mais jamais fermés
  s'accumulent.
• Corrections diverses : photos qui disparaissaient d'un chantier, chantier
  annulé pouvant être marqué terminé, enregistrements refusés à cause d'un nom
  ou d'une adresse trop longs, une seule fiche erronée qui vidait tout un écran,
  et un défilement et une recherche plus fluides dans un long Historique.
```

<details>
<summary>Remplacé : le texte de la première sortie (conservé pour l'historique)</summary>

```
Première version d'ES Pro sur l'App Store.

- Horaire par jour, semaine et mois pour toute l'équipe
- Assignation des plombiers aux chantiers et historique client centralisé
- Photos de chantier depuis l'appareil photo
- Rappels « heure de partir » selon la circulation et carte de l'équipe en direct
- Notifications quand un chantier change, plus un widget d'écran d'accueil
- Fonctionne hors ligne et se synchronise au retour du réseau
- Entièrement en français et en anglais
```
</details>

## Part 11. Screenshots

| Device slot | Pixel size (portrait) | Required? |
|---|---|---|
| iPhone 6.9" (16 Pro Max / 15 Pro Max) | 1320 × 2868 | **Required** — ASC's baseline iPhone set |
| iPhone 6.5" (11 Pro Max / XS Max) | 1242 × 2688 | Optional; ASC can reuse the 6.9" set. Provide if a 6.5" simulator is handy, else skip. |
| iPad 13" (iPad Pro M4) | 2064 × 2752 | **Required** — the app ships for iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) |

Landscape variants are optional; portrait is enough for approval. Capture from a
device/simulator signed into the **demo account** (Part 12) so no real customer
data shows. Capture each shot **twice**, once with the device in English, once
in French, and upload to the matching ASC localization.

Up to 10 per size. Recommended set of 7 (order = story):

| # | Screen to capture | EN caption | FR caption |
|---|---|---|---|
| 1 | Calendar — month grid + day agenda (tablet/landscape split shows both) | Your whole crew's day, week, and month | La journée, la semaine et le mois de votre équipe |
| 2 | Appointment detail sheet (client, address, assignees, photos) | Every job detail in one place | Tous les détails d'un chantier au même endroit |
| 3 | Add / edit appointment with employee picker | Assign the right plumber in seconds | Assignez le bon plombier en quelques secondes |
| 4 | Live staff map with pins + roster sheet | See where the crew is, live | Voyez où est l'équipe, en direct |
| 5 | Admin dashboard (counts / charts) | Know the day at a glance | Ayez un aperçu de la journée |
| 6 | Client list / search | Client history, always at hand | L'historique client, toujours à portée |
| 7 | A "time to leave" push / reminder (or notification settings) | A reminder timed to real traffic | Un rappel calculé selon la circulation |

The login screen is optional as a shot; it shows little and reviewers reach it
anyway. For an 8th, use the home-screen widget showing today's jobs ("Today's
jobs on your home screen" / "Les chantiers du jour sur l'écran d'accueil"), or
the new Live Activity card on the Lock Screen. Avoid App Attest / permission
dialogs in shots.

## Part 12. Age rating, demo account, App Review notes

### Age rating questionnaire (ASC → Age Rating) — completed 2026-07-11

Answer **None / No** to every content question. Result: **4+**. Kept as
reference in case it needs re-answering.

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Sexual Content or Nudity | None |
| Graphic Sexual Content and Nudity | None |
| Contests | None |
| Unrestricted Web Access | No |
| Gambling (real) | No |
| Made for Kids | No |
| Age Assurance / age verification used | No |
| In-app purchases | No |

(Location collection and account sign-in do not raise the content rating.)

### App Review Information (ASC → App Review Information)

- **Sign-in required:** Yes.
- **Contact:** George Vogas · george@vogas.net · (phone as required by ASC).

**Demo account** — created 2026-07-14. There is no self-registration — an admin
creates each account in the app and hands over a generated starting password —
so Review cannot sign up on its own. Still to do at submission: **paste the
email + password into ASC → App Review Information → Sign-In Required.**
Credentials live there, **not in this repo**.

**[was contradictory]** the materials doc still carried unfilled placeholder
blocks (`demo-admin@vogas.net` / `__________`) as if the account didn't exist;
the checklist recorded it created 2026-07-14. Deliberately not recording the
credentials here — a repo is the wrong place for them.

Seed the demo tenant with a few fake clients/appointments so the app isn't empty
and no real customer data is exposed. The admin role shows the full app
(dashboard, live map, Wave section, client management); if you supply only one
account, supply the admin. An optional employee demo account shows the
field-worker view.

**Review notes (paste into the Notes field)** — v1.61.0+90 (2026-09-12), 3,857 of 4,000 chars by `wc -m`:
```
This app is for unlisted distribution. ES Pro is a private scheduling tool for a Quebec plumbing company and its staff, so there is no public sign-up — the sign-in screen offers only sign in and forgot password. An administrator creates each employee account in the app and hands the person their email and a starting password in person. On first sign-in the app makes them choose their own password, enter their name and phone, and accept the terms and location consent before the account works. Please use the demo credentials above.

Roles: an admin manages the schedule, clients, team, live map, dashboard and job history. An employee sees only the jobs assigned to them. The demo account is an admin, so it shows everything.

Location: collected only while the app is open on screen. There is no location background mode — iOS suspends updates when the app is backgrounded — and we ask only for "While Using the App", never "Always". It does two things: times a "time to leave" alert using live traffic to the next job, and shows the crew on an admin-only map. That is App Functionality, not tracking or advertising. We keep only the latest position (one record per user, no history), deleted when the account is disabled or deleted. Settings › "Staff map location" turns it off, and "Clear and pause location" deletes the stored position. If location is denied the app still works: the alert falls back to the drive from the previous job's address, or a flat 30-minute heads-up.

Contacts: requested only when an admin taps "Save to contacts" on a client, to create and keep that one contact up to date. We never read or upload the address book.

Camera and Photos: only to attach photos to a job, and to save a job photo back to the device ("Save to Photos"). Optional.

Face ID: an optional "App Lock" in Settings. Nothing biometric leaves the phone.

App Check uses Apple App Attest, which only issues valid tokens on real hardware. Client search, history search and the booking conflict check run through our Cloud Functions, so on the Simulator they may fail or return nothing. Please test on a device; this build is store-signed, so App Attest works there.

Deleting an account: Settings › "Delete account". The user re-enters their password, then a server function removes the account and its data. It is immediate and permanent: a deleted demo account cannot sign in again.

Notifications: asked only when the user turns on Settings › "Notifications". They cover jobs assigned, moved or cancelled, "time to leave" alerts and a daily summary. Only the "time to leave" alert is sent as Time Sensitive, so a departure alert is not held behind Focus. Optional, as is the home-screen widget.

Siri: read-only shortcuts for today's schedule, tomorrow's, a chosen day, the next appointment, an appointment by number and today's count. They read the signed-in user's own jobs from an on-device snapshot; nothing leaves the device.

Live Activity: an optional "time to leave" card on the Lock Screen / Dynamic Island near a job, showing travel and on-site status. Settings › "Live job card".

CarPlay (Driving Task): the signed-in user's own jobs in a Today tab (next job first) and a Week tab. A job offers Directions (handed to the car's navigation app), Start job, Mark complete and Call. It reads the same on-device schedule as Siri. Sign in on the iPhone first; signed out, CarPlay shows "Sign in on your iPhone".

Analytics: Firebase Analytics and Crashlytics record screen and feature usage counts and crash reports. No name, phone, address or note is sent, no user ID is set, and the app is built without the advertising identifier. No tracking, so no ATT prompt.

Wave, in Settings for admins only, links the company's own accounting service. It is already set up and needs nothing from you.

The app is fully localized in English and French.
```

---

## Part 13. What's actually left

Everything below is owner-only. Compliance items are ordered first because they
block submission regardless of the build.

**Compliance — blocks submission**
- [ ] ⚠️ **ASC → App Privacy: add Precise Location** and reconcile the whole
  declaration against the Part 8 table. This is the one known blocker.
- [ ] Paste the demo account's email + password into ASC → App Review
  Information → Sign-In Required, plus the Part 12 review notes and a contact
  phone.
- [x] **Publish `docs/legal/terms-of-service.html`** to the `es-pro-legal`
  Pages repo. **DONE** — verified 2026-08-11: all four pages return HTTP 200
  and are **byte-identical** to `docs/legal/` (`terms-of-service.html`,
  `accessibility.html`, `support.html`, and the privacy policy served as the
  repo's `index`). The app links to the terms URL from the account-setup
  consent checkbox and Settings › Legal, so re-verify this whenever any file in
  `docs/legal/` changes — republishing is part of that edit, not a follow-up.

**ASC content**
- [ ] Confirm the app record (ES Pro, `net.vogas.scheduling`, Business /
  Productivity, copyright).
- [ ] Add the **French (Canada)** localization; paste EN + FR name, subtitle,
  promo text, keywords, description, What's New from Part 10. Verify each
  field's count in-field.
- [ ] Upload screenshots: iPhone 6.9" (EN + FR) and iPad 13" (EN + FR).
- [ ] Pricing = Free; availability = Canada at minimum.

**Build + device**
- [ ] Clean build, `flutter build ipa`, upload, TestFlight internal test.
- [ ] Confirm no "Missing dSYMs" banner in Crashlytics after the first upload.
- [ ] The remaining Part 6 device checks: iPad pass, live map + Routes API,
  notification-tap deep link, widget + wake-on-push refresh, **Live Activity
  card**, **Siri phrases**, Time Sensitive entitlement.

**Then**
- [ ] Attach the reviewed build and submit.

Export Compliance needs no action: `ITSAppUsesNonExemptEncryption = false` is in
`Info.plist`, so there's no upload prompt.

## Part 14. Parked / intentionally not here

- **Account deletion** requirement is already satisfied (`deleteAccount`
  callable + in-app ACCT-DEL flow) — mention in Review notes if asked.
- **`functions/` transitive npm advisories** — all transitive through
  `firebase-admin`; nothing reachable on a call path, nothing shipped in the
  app. Do **not** force `firebase-admin@14`. Re-check on the next admin-SDK
  minor.
- **Android / Play** — moot. `android/` was **deleted** on 2026-08-05 and iOS
  is the only platform, so keystore, Data Safety, Play Integrity, the monochrome
  icon and the R8 smoke test are all off the table (as is the old caveat that
  FCM shows no foreground banner on Android). Recover the tree from git history
  if a Play release is ever revisited.
- **Series bulk edits** write N appointment docs → N pushes. Accepted for v1
  (each is a real change).
- The remaining audit work lives in `docs/audits/` — the latest snapshot is
  `CODEBASE_AUDIT_2026-09-07.md`, with the rolling owner-only list in
  `AUDIT_FOLLOWUPS.md`. (The single rolling `CODEBASE_AUDIT.md` this line used
  to name is gone; snapshots are written to dated filenames now.) Nothing
  there blocks the steps above.

## Part 15. Assumptions the owner must verify

1. **Character counts** were verified 2026-07-19 with `wc -m`: App Name 6, EN
   subtitle 29, EN promo 158, EN keywords 99, FR subtitle 29, FR promo 169
   (fixed down from an over-cap 171), FR keywords 95 — all within caps. The
   4000-cap Description / What's-New fields were not machine-counted; they are
   well under. Still worth a glance in-field.
2. **Category choice** (Business primary, Productivity secondary) is a
   recommendation for a field-service scheduling tool; change if you prefer.
3. **Diagnostics not linked to identity** assumes Crashlytics is never
   configured with `setUserId` carrying PII. No such call exists today —
   re-check before ticking "not linked" if user-scoped crash reporting is added.
4. **Copyright holder / seller name** is shown as "Plombier Eau Secours" from
   the privacy policy — confirm it matches the legal entity on the Apple
   Developer account.
5. **Region availability / pricing** is a business decision not derivable from
   code; Canada-at-minimum is assumed given the Quebec audience.
