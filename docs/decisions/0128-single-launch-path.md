# 0128. Every external launch goes through `launchExternalUri`

**Date:** 2026-07-13 (route builder), 2026-07-21 (`launchExternalUri`) · **Rules file:** `.claude/rules/frontend.md`

## Context
Hand-rolled `launchUrl` copies had drifted, and one had lost its `try`/`catch`, so a thrown `launchUrl`
reached the zone handler as a FATAL instead of a notice. Google Maps directions URLs take 9 waypoints + 1
destination; Apple Maps has no multi-stop scheme.

## Decision
Phone, map and email helpers delegate to `launchExternalUri` (launch + catch + `logger.warn(tag)` +
notice). Multi-stop runs use `buildGoogleMapsRouteUrl` (`maxRouteStops` 10) and `launchGoogleMapsRoute`.

## Consequences
`AddressMapLauncher.showMapChoices` is the one carve-out (sanctioned SnackBar) and keeps its own `try`.
Stops past 10 are silently dropped, so the caller warns the user.
