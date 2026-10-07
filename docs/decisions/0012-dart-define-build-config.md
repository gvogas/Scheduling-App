# 0012. Build config is `--dart-define`; `dev/.env` retired

**Date:** 2026-09-04 · **Rules file:** `CLAUDE.md`

## Context
`dev/.env` (loaded by `flutter_dotenv`) shipped inside the IPA as a readable asset, so every key in it
was extractable from the binary with no tooling. The file, the package and the asset entry were retired
and replaced by build-time `--dart-define` values (`--dart-define-from-file=dev/firebase.local.json`),
which are compiled in. `AppDelegate` used to parse the Maps key natively from that asset; it now
receives `IOS_MAPS_API_KEY` from `main()` over the `net.vogas.scheduling/native_config` MethodChannel
and calls `GMSServices.provideAPIKey` in `AppDelegate.registerNativeConfigChannel`.

`String.fromEnvironment` is a CONST expression, so a define cannot be read by a runtime string.
`_requireDefine` therefore looks the five Firebase keys up in a `const` map of literals; a key read only
through the map's argument resolves to `''` and fails fast at startup, which is the intended shape.

## Decision
All client config comes from defines. The Maps key call is awaited before `runApp` on purpose, so the
key is installed before any map widget can be constructed; a missing or blank key leaves the live map
blank rather than crashing.

## Consequences
A restricted client key is still recoverable from a binary by someone who tries, so the Google Cloud
Console restriction (bundle ID + API restrictions) is still what makes `IOS_MAPS_API_KEY` safe — the
change removed the trivially greppable copy, not the need to restrict. Server-side or unrestricted keys
(Stripe, OpenAI, admin tokens, `GOOGLE_MAP_API_KEY`) live in Google Secret Manager and are read from a
Cloud Function — never in a define. Don't build a define name dynamically (it silently yields empty),
and don't reintroduce an asset read in `AppDelegate`. `GOOGLE_MAP_API_KEY` was never in `dev/.env`.
