# FlutterFire 5 / Firebase Apple SDK 13 package upgrade

**Status (2026-10-21): BUILT AND GREEN ON WINDOWS, uncommitted; iOS build and device checks not done.**
Rides PR #80 (release 1.66.0+98) unless split out. Push-token follow-up: `2026-10-21-fcm-fid-migration-plan.md`.

## What changed

- **FlutterFire majors** (`pubspec.yaml`): `firebase_core` 5, `cloud_firestore` 7, `firebase_auth` 7,
  `firebase_storage` 14, `firebase_app_check` 0.5, `firebase_crashlytics` 6, `cloud_functions` 7,
  `firebase_messaging` 17, `firebase_analytics` 13, `firebase_remote_config` 7. They pin
  `firebase-ios-sdk` **exactly 13.0.0**.
- **Everything else** at its newest resolvable version (`flutter pub upgrade`), plus
  `connectivity_plus` 7.3.2 (iOS multi-engine callback fix, relevant to CarPlay).
- **Held back, on purpose:** `geolocator` stays 14.0.1. 14.0.3+ pulls `geolocator_linux` → `dbus` 0.7,
  while `connectivity_plus` 7.3.2 needs `nm` 0.6 → `dbus` 0.8. Both are Linux-only; the newer
  `geolocator` releases change only the README and the Android example, and `geolocator_apple` 2.4.2
  (the iOS implementation) is already the newest either way. Revisit when either side moves its `dbus`
  bound (`flutter pub outdated`). `cross_file`, `material_color_utilities`, `test_api` are held by the
  Flutter SDK, not by us.
- **SPM pins** (both `Package.resolved` files, hand-written on Windows from the git tags, ranges
  cross-checked against each package's own `Package.swift`): `firebase-ios-sdk` 13.0.0,
  `googleappmeasurement` 13.0.1, `app-check` 12.0.0, `abseil-cpp-binary` 1.2025051202.0, `grpc-binary`
  1.83.1, `googleutilities` 8.1.5. The two files also disagreed on `googleappmeasurement` (12.19.0 vs
  12.19.2); both now match. Maps stays on `ios-maps-sdk` 9.4.0 + `google-maps-ios-utils` 6.1.0: the
  `google_maps_flutter_ios_sdk9` plugin caps the SDK below 10, and utils 6.1.1+ needs 10.
- **Code:** only `push_notification_service.dart` — the three deprecated messaging calls stay, behind
  `// ignore: deprecated_member_use` (ADR-0190 explains why they cannot simply be swapped).

Verified on Windows: `flutter analyze` clean, `dart run tool/test.dart` 4441/4441 (the 2026-07 patch wave
once broke test COMPILATION while analyze stayed clean, so the suite was the real check).

## Firebase Apple SDK 13 — what affects this app

- **Xcode 26.2 or newer is required** (Swift tools 6.2.1); older Xcode will not resolve the package.
  CI pins Xcode 26.3 (`ci.yml`, "Verify native toolchain") — fine. The Mac used for archiving must be
  on 26.2+.
- **Minimum iOS 15** — the app's floor is 18.0, no change.
- **CocoaPods distribution ended** — no effect; the project is SPM-only (ADR-0169).
- **Messaging: scene delegates now take priority for automatic deep-link routing.** This app has a
  scene manifest (`FlutterSceneDelegate` + `CarPlaySceneDelegate`), so push-tap routing must be checked
  on a device (step 3).
- **Crashlytics:** the dSYM script path `.../checkouts/firebase-ios-sdk/Crashlytics/run` still exists
  in 13.0.0 (checked in the tag), so the Run Script phases need no change.
- **App Check:** no API change for App Attest; `firebase_app_check` 0.5 removed the deprecated
  `activate()` parameters, which `main()` already did not use.

## Next steps

### 1. Commit and let CI build iOS (blocks the merge)

- `/ship` the upgrade to `dev`. CI's macOS job builds with `-onlyUsePackageVersionsFromResolvedFile`
  and fails if Xcode rewrites either `Package.resolved` — the real proof the hand-written pins are
  consistent.
- If it fails on resolution: on the Mac, run `flutter build ios --config-only`, open
  `ios/Runner.xcworkspace`, File → Packages → Resolve Package Versions, and commit both
  `Package.resolved` files exactly as Xcode writes them.

### 2. Build on the Mac

- Confirm Xcode ≥ 26.2 (`xcodebuild -version`).
- `flutter build ios --config-only --dart-define-from-file=dev/firebase.local.json`, then build Runner
  and both extensions (ScheduleWidgetExtension, SiriIntents) in Xcode. `git status` afterwards must show
  no `Package.resolved` change.
- Archive once and confirm the Crashlytics dSYM upload ran for all three targets (build log).

### 3. Device checks (a real iPhone; App Attest fails on the Simulator)

| Check | Pass when |
|---|---|
| Cold start, sign in | Calendar loads; no `permission-denied` in the console |
| App Check | A callable (client search, Save on an appointment) succeeds on a Release build (App Attest) |
| Push delivery | Assign a job to the device's user: the push arrives once |
| Push tap routing (scene-delegate change) | Tapping that push opens the job, from background AND from killed |
| Widget + deep links | Widget tap opens the right day/job; a `net.vogas.scheduling` link still routes |
| Live Activity | Travel card starts and ends (APNs path, unchanged, but same build) |
| CarPlay | Connects, lists today, status action works (multi-engine fix in `connectivity_plus`) |
| Offline banner | Airplane mode shows it; reconnect clears it |
| Crashlytics | A test non-fatal (Settings debug path or a forced `logger.warn`) appears, symbolicated |
| Remote Config | A kill-switch flip on the Client template is picked up within 60 s |
| Photos | Upload a photo; it appears for an admin (Storage SDK major) |

### 4. Ship order

The upgrade is client-only — no backend dependency of its own. It rides 1.66.0+98 behind the deploy order
already in PR #80 (indexes → `isPersonal` backfill → functions + rules → app build). If device checks
fail, roll back by reverting `pubspec.yaml`, `pubspec.lock` and both `Package.resolved` files together
(never one without the others) and re-run the suite.

### 5. Follow-ups

- Push-token migration step 2 (app registers by FID): `2026-10-21-fcm-fid-migration-plan.md`. The
  deprecated messaging calls are removed in some later FlutterFire major — do step 2 before taking it.
- `geolocator` 14.1.x once the `dbus` conflict clears.
- `docs/plans/APP_STORE_SUBMISSION.md`: note Xcode 26.2+ as the archive floor.
