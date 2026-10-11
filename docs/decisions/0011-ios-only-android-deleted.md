# 0011. iOS is the only platform; `android/` deleted and ignored

**Date:** 2026-07-08 (App Store only), 2026-08-05 (`android/` deleted; other platform dirs stay), 2026-08-08 (`/android/` ignored), 2026-09-04 (`DefaultFirebaseOptions.android` removed) · **Rules file:** `CLAUDE.md`

## Context
The app ships to the App Store only (decision 2026-07-08). Android had only ever been the dev/test
harness that gave the original Windows dev box something runnable, and was never published to Play.
Once development moved to a Mac and iOS could build and run locally, `android/` was DELETED (owner
call, 2026-08-05), along with Play-release work (keystore, Data Safety, Play Integrity).

A merge (`33715f82`) then silently resurrected the tree, bringing `android/local.properties` with it,
which carries a live `MAPS_API_KEY` — a committed secret. `flutter` regenerates that directory on any
Android-touching command, so deleting the files alone does not stop a second resurrection; `/android/`
went into `.gitignore` (2026-08-08) and that entry is load-bearing.

`DefaultFirebaseOptions.android` survived only because the shared `FIREBASE_API_KEY`/`APP_ID` pair fed
it; it went with the `dev/.env` retirement (2026-09-04, ADR-0012), and `currentPlatform` now throws
`UnsupportedError` on Android rather than handing back options nothing builds.

One Android remnant survives deliberately: the `platform: 'ios' | 'android'` field on `fcmTokens` docs.
The CURRENT build writes it — `push_registration_controller.dart` stamps
`Platform.isIOS ? 'ios' : 'android'` — so on an iOS-only fleet the value is always `'ios'`, but the
write is live code, not a legacy row. An earlier note credited the 1.37.1 App Store build for it; that
was wrong even then, and retiring the shim on 2026-08-08 changed nothing about this field.

`web/`, `windows/`, `linux/` and `macos/` STAY (owner call, 2026-08-05, asked and answered when
`android/` went): untouched `flutter create` boilerplate for platforms nothing targets or builds.

## Decision
iOS only. `/android/` stays in `.gitignore`; recover the tree from git history if it is ever genuinely
needed. The other platform directories are left alone.

## Consequences
Don't re-add `android/`, Play-release work, `DefaultFirebaseOptions.android` or an Android branch to
"fix" an iOS-only assumption, and don't remove the ignore entry to "restore" a build. Don't clean up the
`fcmTokens` `platform` write as dead code. The presence of `web/`, `windows/`, `linux/`, `macos/` is not
evidence that those platforms are supported; `macos/Podfile` is scaffold, not a CocoaPods setup, and
does not contradict the SPM-only rule in `ios/CLAUDE.md`. The loose callable-response cast also started
as an Android-only problem (ADR-0028).
