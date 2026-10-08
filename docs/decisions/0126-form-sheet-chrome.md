# 0126. Form-sheet chrome: `FormSheetFrame`, `SheetPanel`, measured header slots

**Date:** P2–P4 (2026-08), 2026-09-11 (fresh bar) · **Rules file:** `.claude/rules/frontend.md`

## Context
`FormSheetScaffold` was retired once P3/P4 migrated the last client and employee sheets, and
`EntityFormHeader` (and `AuthBrandHeader`, P4b) went with them; for a long time the rules still said
"`FormSheetScaffold` survives" and told readers to build on it. Only a tombstone comment in
`form_sheet_frame.dart` remains. Three private `SheetPanel` copies appeared in one release (selected-client
card, picker result panel, previous-address list) and drifted on corner radius (`r12` beside an `r16`
sibling); one compared row VALUES against `rows.first` and would drop a divider between equal rows.
`SheetPanelRow` was private to `edit_person_sheet.dart` until My details needed the same AVAILABILITY panel
(P5, 2026-08-10). `ListTile` asserts when its background sits inside a `DecoratedBox`. `SheetHeaderBar`'s
`flex: 3/4/3` left the title 40% of the bar and truncated "New Appointment" on the widest iPhone at default
text size; the measured slots (`measureTextWidth`, each capped at 34%) centre the title by construction,
and the cap prevents overflow at large scale. Since 2026-09-11 the bar has no band or divider (it sits on
the sheet's `surfaceContainerLowest`), a `headlineLarge` title, and ghost-styled Cancel/verb that stay
`TextButton`s so the disabled-verb assertion holds; they reach the 48px floor through the button's default
padded tap target (the old text said `tapTargetSize.padded`; the code sets no explicit value), and the verb
label keeps `palette.primaryAccent` (`textMuted` disabled). The stale `add_client_sheet_test.dart` comment
naming the retired scaffold now reads `FormSheetFrame`.

## Decision
Build every form sheet on `FormSheetFrame`, every divided panel through `SheetPanel`, and keep the measured
slots.

## Consequences
Treat a mention of a retired class as documentation to correct. `sheet_header_bar_test.dart` pins equal
tiles AND the title taking the remainder.
