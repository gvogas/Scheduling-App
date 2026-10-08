# 0122. Token placements that look arbitrary, and the off-scale inset exemption

**Date:** 2026-09-05 (inset exemption, owner call) · **Rules file:** `.claude/rules/frontend.md`

## Context
The rungs: `AppSpacing` `sp4`/`sp8`/`sp12`/`sp16`/`sp24`/`sp32`; `AppRadius` `r8`/`r12`/`r16`/`r20`/`r24`/`rFull`.
`AppColors.crewDefault` outside `crewPalette` would also fall outside the dark-theme override map (taking
the generic HSL lift instead of its designed counterpart), and no picker would offer it. The nine `nav*`
drawer hues equal crew hues but stay separate because `crewPalette` is the ASSIGNMENT pool: reordering it, a
normal change, would repaint the drawer. `decorativeHueRing` is a spectrum, not a semantic colour; it lives
in the token file only to keep `lib/` free of literal colours, and its last stop repeats the first so the
sweep closes. Unused `AppRadius` rungs (`r24`) were flagged for pruning; `rCard`/`rPanel`/`rSheet`/`rDialog`
are the design's named surfaces. Every audit since 2026-08 re-found off-scale `EdgeInsets` (1–3, 5, 7, 9–15, 18, 20, 25, 30, 48 and spN ± 2), some mixed with tokens in one `fromLTRB`
(`inline_month_calendar.dart`, `calendar_month_grid.dart`, `app_nav_drawer.dart`).

## Decision
Keep those four placements. Any off-scale optical nudge is an accepted, open exemption, not a backlog: optical nudges with
no unambiguous token, and adding those steps to `AppSpacing` would destroy the scale.

## Consequences
Don't prune an unused rung, merge the nav hues into the crew pool, or file the off-scale insets as an
audit finding. Everything else still reaches for a token first.
