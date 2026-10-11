# 0172. Register native channels from didInitializeImplicitFlutterEngine

**Date:** 2026-09-06 · **Rules file:** `ios/CLAUDE.md`

## Context
`AppDelegate` registered the `net.vogas.scheduling/native_config` channel in
`application(_:didFinishLaunchingWithOptions:)` through `window?.rootViewController as? FlutterViewController`.
Under the implicit engine that runs before the window has a root, so the guard took its failure branch,
logged "Native config channel unavailable" and registered nothing; the Maps key never reached `GMSServices`
and the live map stayed blank with that one log line as the only clue.

## Decision
`AppDelegate` conforms to `FlutterImplicitEngineDelegate`; `didInitializeImplicitFlutterEngine` takes the
messenger from `engineBridge.applicationRegistrar.messenger()`, captures it into `FlutterMessengers`, and
registers the native-config channel and `CarPlayBridge` on it. The Dart side still awaits the send before
`runApp`.

## Consequences
Don't restore a `didFinishLaunchingWithOptions` override to register a channel.
