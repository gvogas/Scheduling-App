# 0123. `AppTopBar` is not an `AppBar`; `preferredSize` is an upper bound

**Date:** 2026-09-11 ("fresh" redesign) · **Rules file:** `.claude/rules/frontend.md`

## Context
The fresh header paints `theme.scaffoldBackgroundColor` with a `displayLarge` title (`titleLarge` on the
48px controls row when `compact`), ghost controls, no bar and no divider.
Leaving `AppBar` lost three things the framework supplied: the `AnnotatedRegion` overlay style, the
safe-area inset, and the implicit `EndDrawerButton` (which `actions` used to suppress; uniformity is now the
only reason every screen passes `AppHeaderPair`). A title-side `count` was built and removed 2026-09-12 with
no caller. `preferredSize` has no `BuildContext`, so it cannot read the text scaler; it reserves rows at
`Breakpoints.maxTextScale` (2.2, the cap `main()` applies). `Scaffold` adds the top inset itself
(`scaffold.dart`, `_appBarMaxHeight`) and takes `contentTop` from the laid-out height, so over-reserving leaves no gap while
under-reserving clips; the bound also keeps the `Flexible` title row out of an unbounded `RenderFlex`. The
calendar's `CalendarHeaderBlock` (P2) hosts a week strip that collapses, which a fixed-height
`PreferredSizeWidget` cannot. A Material `SegmentedButton` for the agenda day/week toggle painted its
selected half `secondaryContainer` green under the ghost controls. `AppSearchBar`'s `preferredSize` has the
same no-context limit, so it takes the scaler from its call site.

## Decision
Keep the bound at `maxTextScale` and the three reproduced behaviours; the calendar is the one screen
without `AppTopBar`.

## Consequences
A `textScaler` parameter on `AppTopBar` would default to `noScaling` at every call site and clip at 2×.
Don't add the inset to the bound (double-counts) or generalise the calendar exception.
