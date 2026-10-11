# iOS (ios/)

Loaded when working under `ios/`. Root context: `../CLAUDE.md`. Native build, run and Crashlytics dSYM upload need a Mac; full runbook `docs/plans/APP_STORE_SUBMISSION.md`.

## Config and packages

- Never re-run `flutterfire configure` — `lib/firebase_options.dart` builds the iOS options from `--dart-define` values (`IOS_API_KEY`, `IOS_APP_ID`, `MESSAGING_SENDER_ID`, `PROJECT_ID`, `STORAGE_BUCKET`, `iosBundleId: net.vogas.scheduling`), and a re-run rewrites it into literals.
- Carry the gitignored `GoogleService-Info.plist` to the Mac out-of-band and put it at the `ios/` ROOT, not `ios/Runner/` — the Xcode fileRef and the extensions' `-gsp` both point there.
- Keep the project SPM-only: no Podfile, ever, and ignore notes about `pod install` or `${PODS_ROOT}`. Xcode resolves `firebase-ios-sdk` from `Package.resolved`. Vet any new iOS plugin for SPM support before adding it. (ADR-0169)
- Keep `google_maps_flutter` on the `google_maps_flutter_ios_sdk9` endorsed SPM override (Maps SDK 9.x, iOS 15+) and `saver_gallery` (ships a `Package.swift`) for Save to Photos; never fall back to `google_maps_flutter_ios` or switch to the more popular `gal` — both are CocoaPods-only and would force a Podfile back. (ADR-0169)

## Build settings (`project.pbxproj`)

- Keep the Crashlytics dSYM Run Script (`"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"`) on ALL THREE code-bearing targets: Runner (bundled plist), plus ScheduleWidgetExtension and SiriIntents, which are Firebase-free and so pass `-gsp "${PROJECT_DIR}/GoogleService-Info.plist"`. (ADR-0170)
- Keep `ENABLE_USER_SCRIPT_SANDBOXING = NO` (project-wide and on the widget target) — re-enabling it makes the extension upload fail silently. Keep Release Debug Information Format `DWARF with dSYM` at project level; never add a per-target `dwarf` override. (ADR-0170)
- Keep the deployment target at iOS 18.0 on every Xcode target — the returnable `OpenURLIntent` on the Live Activity Directions button needs 18. The floor lives only on the targets; `ios/Flutter/AppFrameworkInfo.plist` pins no `MinimumOSVersion`. (ADR-0171)

## App Check (App Attest)

- Keep App Attest, not DeviceCheck: `AppleAppAttestProvider` in `main()` for non-debug builds (`kDebugMode` picks `AppleDebugProvider`), the entitlement `com.apple.developer.devicecheck.appattest-environment` = `production`, and App Attest enabled in Firebase Console → App Check (no `.p8` key). The console provider MUST match the code or attestation is rejected; never lower the target below 14, where attestation silently fails. (ADR-0171)
- Verify App Attest on real hardware only; it fails on the Simulator. Debug builds use `AppleDebugProvider`: take the token from the Xcode console (or `GACAppCheckDebugToken` in the simulator app's preferences plist) and register it under Manage debug tokens; it is per-install, so re-register after a reinstall or new simulator. An unregistered token fails writes and uncached reads with `permission-denied` while cached reads succeed, so it looks collection-specific. Walkthrough: `docs/IOS_MAC_BUILD.md` Phase E. (ADR-0171)

## AppDelegate

- Register native channels from `didInitializeImplicitFlutterEngine` (`AppDelegate` conforms to `FlutterImplicitEngineDelegate`), taking the messenger from `engineBridge.applicationRegistrar.messenger()`; never from `application(_:didFinishLaunchingWithOptions:)` — under the implicit engine the window has no root yet, so the channel never registers and the Maps key never reaches `GMSServices`. (ADR-0172)
- The same method captures the messenger into `FlutterMessengers` and registers `CarPlayBridge` beside the native-config channel; `main()` still awaits the send before `runApp`. (ADR-0172)

## CarPlay (`ios/Runner/CarPlay/`, Runner target)

- Keep CarPlay a native scene: `Info.plist`'s `UIApplicationSceneManifest` has `CPTemplateApplicationSceneSessionRoleApplication` as a SIBLING array in `UISceneConfigurations`; leave the Flutter `UIWindowSceneSessionRoleApplication` / `FlutterSceneDelegate` entry byte-for-byte untouched and `UIApplicationSupportsMultipleScenes` `false` (it governs iPad multi-window, not CarPlay). (ADR-0173)
- Prefix `UISceneDelegateClassName` with `$(PRODUCT_MODULE_NAME).` (`$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`) — a bare class name doesn't resolve and the scene silently never connects. (ADR-0173)
- Keep the CarPlay key (`com.apple.developer.carplay-driving-task`) in `Runner.entitlements` (`RunnerCarPlay.entitlements` is gone). Under automatic signing the order is App ID capability → key in the file → device build with `-allowProvisioningUpdates`; "refresh profiles first" deadlocks. Archive once to prove distribution signing before shipping. (ADR-0173)
- In the Simulator build against the entitlements file; never `codesign --entitlements` the CarPlay key into a built app — SpringBoard refuses the launch (`SBMainWorkspace`). No Apple grant is needed there; the `Info.plist` scene manifest is what puts the app on the CarPlay dashboard. (ADR-0173)
- Render only from the App Group `schedule_snapshot`, never the Flutter engine, Firestore or network — that independence is what made it safe to ship; the method channel is a freshness path only. Payload (schema v4): `.claude/rules/notifications.md`; design: `docs/ARCHITECTURE.md`. (ADR-0173)
- Lead every row with the 12-hour time for both roles; only an ADMIN row gets an image (the crew avatar). Don't re-add a technician time tile — the time is already in the row text, so it would show twice. Show an all-day block NO clock time — `CarPlayStrings.startedAt` returns `String?` so the Now header can't say "Started 12:00 AM", and the detail's When row drops a start-only tail. (ADR-0177)

## Info.plist and privacy manifests

- `Info.plist` declares `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription` and `LSApplicationQueriesSchemes`.
- Keep `NSLocationAlwaysAndWhenInUseUsageDescription` on purpose although the app never requests Always — `geolocator_apple` compiles `requestAlwaysAuthorization` in (`PermissionHandler.m:68,77`), so without it every upload draws ITMS-90683; it can't prompt, since the plugin checks `NSLocationWhenInUseUsageDescription` first. (ADR-0174)
- Give each extension its OWN `PrivacyInfo.xcprivacy` declaring `CA92.1` for `UserDefaults(suiteName:)`, or upload draws ITMS-91053. `ScheduleWidget` is a `PBXFileSystemSynchronizedRootGroup`, so its empty Resources phase is correct; `SiriIntents` is a plain `PBXGroup` and needs an explicit fileRef + build file + Resources entry, as would any new non-synchronized extension. (ADR-0175)

## Deep links

- Keep the `homeWidget` query item on `esproschedule://appointment?id=…&homeWidget` in all three producers (`ScheduleWidget.swift`, `LiveActivitiesAppAttributes.swift`, `SiriIntents/ScheduleSnapshot.swift`) — two plugins watch the same openURL, and the item decides which owns the tap: `home_widget`'s `isWidgetUrl` claims it, and `classifyDeepLink` (`lib/core/deep_links/deep_link_target.dart`) skips it, so the sheet opens once. Retire the item and the `home_widget` tap channel together. Verify on a Mac: widget row / Live Activity tap → appointment sheet. (ADR-0176)
