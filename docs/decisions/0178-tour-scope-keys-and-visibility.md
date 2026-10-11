# 0178. Tours keyed on a sealed TourScope; storage key is the bare name; gate chosen by type

**Date:** 2026-08-04 (`TourScope`), 2026-09-15 (hub-tab route gate) · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
Tours were keyed on `AppDestination`, so a walkthrough of a create sheet ("how do I create an appointment")
was not expressible. Devices already held seen flags under each destination's bare `.name`. The first
visibility gate keyed on a null `HubShellScope`, which is ambiguous: it also describes a hub screen hosted
standalone in a test, and Settings and History (pushed routes) would have had `currentOf == null` and never
started. On 2026-09-15 a page pushed over the hub hid the calendar tab without switching it, and the calendar
tour started underneath the team-map page.

## Decision
Key on the sealed `TourScope`: `DestinationTour` (screen) or `FormTour` (sheet). `storageKey` is a
destination's bare `.name` or `sheet_<form>`; it is both the showcase scope name and the `kLegacyTourSteps`
key. The sealed type picks the gate: a `HubTab` needs `HubShellScope.currentOf` AND its hosting route
current; a `PushedDestination` and a `FormTour` share `ModalRoute.of(context)?.isCurrent`.

## Consequences
Prefixing a destination key, or renaming a `HubTab`/`PushedDestination`/`TourForm` member, replays or
orphans tours on every installed device. Gating on a null scope again breaks the standalone-test case.
A form tour starts the instant a test pumps its sheet, hence `markFormToursSeen()`.
