# 0181. One tourWrap parameter per multi-step widget

**Date:** 2026-09-05 · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
`AppointmentFormFields` had the single-callback shape first. `DetailsViewBody`, `DetailsActionBar` and
`NotificationsSettingsCard` grew twelve `wrap<StepName>` parameters and two copies of the same `?? child`
helper between them before converging on it.

## Decision
A widget hosting more than one step takes one `Widget Function(TourStepId, Widget)? tourWrap`, wired as
`tourWrap: _tour.stepIf` (a tear-off of `TourSteps.stepIf`).

## Consequences
A new step costs a call at the target, not a parameter threaded through two or three widgets and their tests.
