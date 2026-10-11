# 0182. Audit tour copy and coverage when a toured surface changes

**Date:** 2026-09-05 · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
Two step descriptions had gone stale with nothing failing: `apptDetails` still listed "Address" after the
job address moved into the WHO section, and `historyFilter` said "date range" where the filter only ever
offered a YEAR. 1.57 shipped the clients sort and 1.58 the job-address block with no step at all; they are
`clientsSort` and `apptJobAddress` now.

## Decision
A step's copy is part of the surface it points at: re-read it whenever that surface changes shape, and add a
step for a new control. Keep the count assertions in `tour_definitions_test.dart`.

## Consequences
Nothing catches stale copy mechanically (the target exists, the string resolves). Adding an id is safe (it is
absent from `kLegacyTourSteps`), which is why the counts are what make growing a catalog deliberate.
