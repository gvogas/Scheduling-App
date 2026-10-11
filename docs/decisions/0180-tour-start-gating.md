# 0180. Start a tour only on rendered targets of a settled, ready page

**Date:** 2026-09-04, 2026-09-13 · **Rules file:** `lib/features/feature_tour/CLAUDE.md`

## Context
showcaseview 5.x's `Showcase` does not forward its key to the element tree, so `GlobalKey.currentContext`
is always null and cannot say whether a target exists. An ungated start against a loading body found zero
survivors and, before per-step flags, permanently showed nobody anything; LiveMap hit it, since its targets
(the team sheet's header and the recenter tile since 2026-09-13, FABs before) live in the map stack, absent
during the presence-data load. A partial start (some targets missing) was the same bug and easier to miss.
Clients and History are paginated, so they have no `AsyncValue` to gate on. A fast tab switch during
auto-start left `_started` true and wedged the tab's tour shut for the session.

## Decision
`FeatureTourHost` awaits `tourSeenProvider.ready` and `_routeTransitionSettled()`, re-checks visibility and
`ready` post-frame (resetting `_started` on that early return), and starts only the steps
`isTargetRendered` finds. Data-dependent hosts pass `ready:`; paginated ones gate on `onFirstPageSettled`.

## Consequences
Since 2026-09-04 a partial start is no longer permanent (only steps that ran are marked), but the gate still
stops a tour opening on a skeleton.
