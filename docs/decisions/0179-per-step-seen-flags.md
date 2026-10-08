# 0179. Seen flags per step, migrated once through a frozen snapshot

**Date:** 2026-09-04 · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
Seen flags were per scope (`tour_seen_tabs`). A release adding a step to an already-toured screen could not
show it, and a tour that dropped a step because its target hadn't rendered still marked the whole scope
seen, losing the dropped step for good (the partial-start bug).

## Decision
Store per-step flags in `tour_seen_steps` (device-local SharedPreferences). `TourSeenController._load`
seeds them once from `tour_seen_tabs` through the frozen 1.57 snapshot `kLegacyTourSteps`; the absence of
`tour_seen_steps` is the migration marker. `markSteps` records only the ids that ran. `resetAll` writes an
empty list and leaves `tour_seen_tabs` alone.

## Consequences
A new id added to `kLegacyTourSteps` is marked seen on upgrade and never shown on an existing device. A new
id left out of it is offered everywhere. Deleting the key instead of writing an empty list would re-run the
migration and re-mark the old steps seen.
