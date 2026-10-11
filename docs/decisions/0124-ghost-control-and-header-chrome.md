# 0124. `GhostControl` owns the tap floor; header pair and drawer rows

**Date:** 2026-09-11 · **Rules file:** `.claude/rules/frontend.md`

## Context
Six hand-spelled ghost tiles put the 48px box AROUND the gesture, so three reserved the layout and tapped
at 38 (the clients Filter button measured 38x34, its chips 35 tall). The tile is `Ink`, not a nested
`Material`, so the splash paints over the fill while the larger `InkWell` takes the tap. Tones: `ghost`
(`scheme.surface` fill, 1px `scheme.outlineVariant` border, `scheme.onSurface` glyph, `AppRadius.rFull`),
`accent` (primary border and glyph, the Filter button), `GhostTone.selected` (`onSurface` fill, page-colour
label, a picked filter chip), `active` (`primary` fill, `onPrimary` glyph, the crew filter). The header
pair's pill keeps its calendar glyph alone in `scheme.primary`. A pill's bare
`Center` filled the `Flexible` it was handed in `AppTopBar`'s controls row, and the Calendar pill's tile
floated 84px from the hamburger; `app_header_pair_test.dart`'s `AppBar` harness does not reproduce that.
Screens once held a `GlobalKey<ScaffoldState>` to open the drawer. A drawer row's leading became a 28px
tinted chip so colour is never the only cue; `sp12` row padding would have grown the drawer past the 48px
minimum. A closed drawer's child is never built, so an "is open" flag buys nothing.

## Decision
`GhostControl` with four `GhostTone`s is the only ghost control; the pill's `Center` takes
`widthFactor: 1`; the header pair resolves its host via `Scaffold.of`; drawer rows use an icon chip and
`sp8` padding.

## Consequences
Pin the pill assertion in `ghost_control_test.dart`/`app_top_bar_test.dart`. Don't restore `sp12`, a
scaffold key or an open flag.
