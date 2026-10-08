# 0110. The "Be on the team map" page is the in-context location step

**Date:** 2026-09-15 · **Rules file:** `.claude/rules/notifications.md`

## Context
The no-prompt rule (ADR-0101) asks for an explicit in-context step. The first build skipped sharing-on
accounts without recording anything, so the page appeared the moment they switched sharing OFF in
Settings, the one moment it must not. It also used to wait for the calendar tour.

## Decision
`ShareLocationAskScreen`, pushed by `LocationShareAskGate` from the calendar, shows ONCE PER APP BUILD to
every active real account: `LocationShareAskStore` records the `version+buildNumber` per device per uid,
marked BEFORE the push so a killed page stays final. `isLocationShareAskDue` ignores
`locationSharingEnabled`. `locationShareAskVariant` picks Turn on (iOS can still prompt), Open Settings
(`permanentlyDenied` or Location Services off, where Turn on changes nothing), or a confirmation with Done
for someone already sharing. Turn on runs `saveLocationSharing`, which issues the single prompt; the page
reads `LocationPermissionService.currentStatus`, which never prompts. Nothing on a sync path
ever pushes the page. The gate hands the calendar `holdsTour` until the page is decided and while the
person's own record is still loading, so it comes BEFORE the calendar tour.

## Consequences
Swapping in `ensureLocation` spends the one iOS prompt by opening the page. Pinned by
`location_share_ask_gate_test.dart` and `share_location_ask_screen_test.dart`.
