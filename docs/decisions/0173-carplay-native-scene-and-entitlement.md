# 0173. CarPlay is a native scene in Runner, entitled through Runner.entitlements

**Date:** 2026-09-09 (entitlement granted), 2026-09-10 (two-file gating retired) · **Rules file:** `ios/CLAUDE.md`

## Context
CarPlay (`ios/Runner/CarPlay/`) went into a shipping app as a native scene in the Runner target, not a
Flutter surface or a new extension. A bare Swift class name in `UISceneDelegateClassName` does not resolve
from a plist, and the scene then silently never connects. `UIApplicationSupportsMultipleScenes` governs iPad
multi-window; Apple's prose is ambiguous on whether one-scene-per-role applies across roles, and committed
plists from shipping CarPlay apps keep it `false`.
Before the grant the key lived in a separate `RunnerCarPlay.entitlements`. On 2026-09-10 the capability went
on the `net.vogas.scheduling` App ID, a device build signed carrying the key, and that file was deleted.
Under automatic signing "refresh profiles, then move the key" deadlocks, because Xcode requests only an
entitlement it already sees in the file. Hand-signing the key into a simulator build with
`codesign --entitlements` makes SpringBoard refuse the launch (`SBMainWorkspace`); app-groups and
get-task-allow alone launch fine.

## Decision
Add `CPTemplateApplicationSceneSessionRoleApplication` as a sibling of the untouched Flutter
`UIWindowSceneSessionRoleApplication` entry, delegate `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`. The
key lives in `Runner.entitlements`; the working order is App ID capability, move the key, device build with
`-allowProvisioningUpdates`. CarPlay renders from the App Group `schedule_snapshot` with no engine, Firestore
or network; the method channel is only a freshness path. Row anatomy: ADR-0177.

## Consequences
Distribution signing was unproven on 2026-09-10 (that Mac held only an Apple Development certificate):
archive once before shipping. A CarPlay path that needs the engine, Firestore or network loses the property
that made it safe to add to a shipping app.
