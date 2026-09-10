# iOS (ios/)

Loaded when working under `ios/`. Root context: `../CLAUDE.md`.

iOS notes (Phase 0 of clean-architecture restructure):
- iOS native build, run, and Crashlytics dSYM upload require a Mac. **Do NOT
  re-run `flutterfire configure`** — `lib/firebase_options.dart` already builds
  the iOS options from `--dart-define` values (`IOS_API_KEY`, `IOS_APP_ID`,
  `MESSAGING_SENDER_ID`, `PROJECT_ID`, `STORAGE_BUCKET`,
  `iosBundleId: net.vogas.scheduling`); re-running it rewrites the file into the
  literal-values style and breaks the define-based setup. Carry
  `ios/GoogleService-Info.plist` (gitignored) to the Mac out-of-band; it lives
  at the `ios/` **root**, not `ios/Runner/`.
- **The project uses Swift Package Manager — there is no Podfile and never will
  be.** Ignore any older notes mentioning `pod install` or `${PODS_ROOT}`.
  Xcode resolves `firebase-ios-sdk` (pinned in `Package.resolved`) on first
  open. The Crashlytics dSYM upload Run Script from the SPM checkout
  (`"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"`)
  is wired in `project.pbxproj` on ALL THREE code-bearing targets (added
  2026-07-21): Runner (bundled plist), plus ScheduleWidgetExtension and
  SiriIntents — the extensions are Firebase-free so their phases pass
  `-gsp "${PROJECT_DIR}/GoogleService-Info.plist"` (the ios/-root plist) and
  need `ENABLE_USER_SCRIPT_SANDBOXING = NO` (flipped on the widget target;
  don't re-enable it or the upload silently fails). Debug Information Format
  is `DWARF with dSYM` for Release at the project level, which the extension
  targets inherit — don't set a per-target override back to `dwarf`. `google_maps_flutter` uses the `google_maps_flutter_ios_sdk9`
  endorsed SPM override (Maps SDK 9.x, iOS 15+) — never fall back to the
  default CocoaPods-only `google_maps_flutter_ios`. Same rule for save/share:
  the photo viewer's Save-to-Photos uses **`saver_gallery`** (ships a
  `Package.swift`), deliberately NOT the more popular `gal` — `gal` is
  CocoaPods-only and would force a Podfile into this SPM-only project. Vet any
  new iOS plugin for SPM support before adding it.
- Deployment target is **iOS 18.0** (set on all targets in the Xcode project;
  bumped from 15.0 on 2026-07-19 — the Siri App Intents extension needs iOS 16
  and the Live Activity Directions button's returnable `OpenURLIntent` needs
  iOS 18, so the whole app moved to an 18.0 floor and iOS 15–17 users are
  dropped). Well above App Attest's 14+ requirement. App Check uses **App
  Attest** (`AppleAppAttestProvider` in `main()`); don't lower the target below
  14 or attestation silently fails on the runtime device. See
  `docs/plans/APP_STORE_SUBMISSION.md` for the full Mac runbook.
- App Check via **App Attest** (not DeviceCheck) needs, on the Xcode side:
  the **App Attest** capability / entitlement
  (`com.apple.developer.devicecheck.appattest-environment`, set to `production`
  for Release), and App Attest **enabled in the Firebase Console** (Build →
  App Check → the iOS app — no `.p8` key required, unlike DeviceCheck). The
  console provider MUST match the code provider or attestation is rejected.
  App Attest fails on the iOS Simulator — verify on real hardware.
- **`AppDelegate` registers the native-config channel from
  `didInitializeImplicitFlutterEngine`, NOT from
  `application(_:didFinishLaunchingWithOptions:)`** (2026-09-06). It conforms to
  `FlutterImplicitEngineDelegate` and takes the messenger from
  `engineBridge.applicationRegistrar.messenger()`. The old shape reached for
  `window?.rootViewController as? FlutterViewController`, which under the
  implicit engine runs BEFORE the window has a root — so that guard takes its
  failure branch, logs "Native config channel unavailable" and never registers
  a handler, and the Maps key then never reaches `GMSServices`, leaving the
  live map blank with only that one log line to say why. Don't "restore" a `didFinishLaunchingWithOptions` override to
  register a channel; take the messenger the bridge hands you. The Dart half is
  unchanged — `main()` still awaits the send before `runApp`.
  `ios/Flutter/AppFrameworkInfo.plist` no longer pins `MinimumOSVersion`; the
  18.0 floor lives on the Xcode targets, which is the only place it was ever
  enforced.
- `Info.plist` already declares `NSCameraUsageDescription`,
  `NSPhotoLibraryUsageDescription`, and `LSApplicationQueriesSchemes`.
- **`NSLocationAlwaysAndWhenInUseUsageDescription` is declared on purpose even
  though the app never requests Always — do NOT "clean it up".** It reads like a
  dead over-declaration (the app calls `Geolocator.requestPermission()`, which
  is when-in-use, and `UIBackgroundModes` carries only `remote-notification`),
  but `geolocator_apple` compiles `requestAlwaysAuthorization` into the binary
  (`PermissionHandler.m:68,77`), so App Store Connect's static scan emails
  **ITMS-90683 "Missing purpose string"** on every upload if the key is absent.
  Removing it buys nothing and costs a warning email per build. It also cannot
  change behaviour: on iOS the plugin tests `NSLocationWhenInUseUsageDescription`
  FIRST and only falls through to Always as an `else if`, so with both keys
  present the Always branch is unreachable — which is what keeps the privacy
  policy's "it only ever asks for 'While Using the App'" true. The purpose
  string itself says the app only uses location while open, so a reviewer asking
  why Always is declared has the answer in front of them. The plist carries a
  comment saying all of this; keep them in sync.
- **Each extension needs its OWN `PrivacyInfo.xcprivacy`, and only one of the
  two gets it for free.** `ScheduleWidget` is a `PBXFileSystemSynchronizedRootGroup`
  (Xcode 16 synchronized folder), so a file dropped in that directory is bundled
  automatically — its empty Resources build phase looks like a bug and is not.
  `SiriIntents` is a plain `PBXGroup`, so its manifest needs an explicit
  fileRef + build file + Resources-phase entry, added 2026-08-05. Both
  extensions read `UserDefaults(suiteName:)` (required-reason API `CA92.1`);
  a missing declaration draws **ITMS-91053**. Adding a third extension means
  adding its manifest by hand unless the group is synchronized too.
- **Deep-link tap URLs must keep the `homeWidget` query item.** The three iOS
  producers (`ScheduleWidget.swift`, `LiveActivitiesAppAttributes.swift`,
  `SiriIntents/ScheduleSnapshot.swift`) emit
  `esproschedule://appointment?id=…&homeWidget`; the `home_widget` plugin's
  `isWidgetUrl` claims a URL only when that query item is present, and nothing
  else consumes the scheme (`FlutterDeepLinkingEnabled` is `false` and
  `AppDelegate` has no `open url` override), so dropping the param silently
  turns taps into plain app launches (fixed 2026-07-29). Retire the param only
  together with the `home_widget` tap channel, when the P4b `app_links`
  dispatcher lands (docs/archive/2026-07-29-redesign-program.md). Swift-side, so
  Mac-only verification: widget row / Live Activity tap → appointment sheet.

App Check simulator setup: debug builds use `AppleDebugProvider` (App Attest is
Release-only and fails on the Simulator), so run the app once → take the debug
token from the Xcode console, or read `GACAppCheckDebugToken` out of the
simulator app's preferences plist → register it in Firebase Console → App Check
→ the iOS app → Manage debug tokens. The token is per-install: re-register after
a full reinstall or a fresh simulator. An unregistered token causes all Firestore
writes and non-cached reads to fail with `permission-denied` while cached reads
still succeed, making the failure appear collection-specific. Full walkthrough:
`docs/IOS_MAC_BUILD.md` Phase E.

