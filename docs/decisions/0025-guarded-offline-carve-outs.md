# 0025. `guardedOffline` and its exactly-three carve-outs

**Date:** 2026-08-02 (`guardedOffline`), 2026-08-04 (notices lose the support tag), 2026-08-11 (stale carve-out fixed), 2026-08-15 (Wave carve-out named), 2026-09-29 (`ChangePasswordScreen`) · **Rules file:** `CLAUDE.md`

## Context
The widget-layer offline block (read `isOfflineProvider`, push the standard notice, return) was
copy-pasted at six sites, so it became `guardedOffline` (`core/errors/error_cause.dart`). It takes no
`tag`: notices carry no support code since 2026-08-04, so a tag lives only in the `logger.warn` label at
the same site.

The carve-out list is meant to be exact, and a stale entry is what once made it read as drift: it named
"the two `accept_invite_*` screens" until 2026-08-11, both deleted by P4c, so the rule pointed at
nothing; the Wave carve-out existed unnamed until 2026-08-15.

## Decision
Three carve-outs: `AccountSetupScreen` and `ChangePasswordScreen` surface offline through their own
banner (`_bannerError`), and `WaveSettingsSection._blockedOffline` surfaces
`WaveNetwork().toLocalizedMessage`, because the typed-`Failure`-branch-first rule gives it a better
sentence than the generic cause vocabulary. Controller-layer guards return a typed failure instead.

## Consequences
A new carve-out is added to the list in the same change, or the list stops being exact.
