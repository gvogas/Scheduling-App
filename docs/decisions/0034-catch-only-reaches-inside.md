# 0034. A catch only reaches what is inside it

**Date:** 2026-08-31 (three fatals in one release); 2026-09-05 (`ValueChanged`); 2026-09-19 (`setState`) · **Rules file:** `.claude/rules/error-handling.md`

## Context
Three fatals shipped in one release from catches that existed, looked right and did not cover the
throw:
- `_loadClientIfNeeded` (`event_details_controller.dart`) awaited `currentUserDocProvider.future`
  above its try inside a discarded `Future.microtask`, and `PushRegistrationController._syncGuarded`
  awaited `_refreshSub.cancel()` above its own. A `hasError` guard covers a settled error, not one
  arriving during the await; the throw reached the zone handler as an app-level FATAL from a sheet that
  merely failed to prefill a name. `PresenceSyncController` already kept its awaits inside, which is
  how the drift was visible.
- `WaveSettingsSection` caught only `WaveFailure`, so any other throw escaped with no notice: the admin
  tapped Sync and nothing visibly happened.
- The photo picker's preload relied on `loadAll` swallowing its own per-image failures — true, but not a
  guarantee (an OOM decoding a large batch, or one refactor there).

Later, the same shape twice more. The client recents row's `void` `onSelectRecent` handler awaited a
Firestore read, and the controller writes on the far side would throw "used after being disposed" into
the zone if the sheet was dismissed meanwhile (that row has since been removed). And
`personal_block_clash_dialog.dart`'s `_write`: the dialog is barrier-dismissible and its callers
`setState` on `true`; in release `setState`'s lifecycle check is an assert, so an unmounted State falls
through to `_element!.markNeedsBuild()` as a FATAL, which `use_build_context_synchronously` cannot see.
It returns `false` when unmounted even though the write committed.

## Decision
Every await a guard is for goes inside its `try`; a typed catch has a generic branch behind it; a
future nobody awaits keeps its whole body inside the guard; an async handler behind a `ValueChanged`
checks `mounted` / `context.mounted` after its await; `setState` after an await checks `mounted` even
on success.

## Consequences
If it regresses, a routine failure (a prefill read, a token-refresh cancel, a Wave sync) throws
inside an unawaited future, which has no caller, so Crashlytics files it as an app-level FATAL; a
narrowed catch instead fails silently, with no notice shown.
