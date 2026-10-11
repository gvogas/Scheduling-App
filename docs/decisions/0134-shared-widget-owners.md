# 0134. Shared widget owners that replaced drifted copies

**Date:** 2026-08 to 2026-09 · **Rules file:** `.claude/rules/frontend.md`

## Context
Each of these replaced hand-built copies that had already drifted. `SkeletonList` was rebuilt per call site
(drifted row gap) and is not scrollable because two callers sit in `infinite_scroll_pagination`'s
`SliverFillRemaining`, which asks for intrinsics and throws on a nested `ListView`. `AppDialogFrame` +
`DialogActionPair` replaced the same twelve lines in the booking-conflict, series-scope and time-off clash
dialogs. `WarningNote`'s copies had drifted their icon to `status.warning`, which fails contrast on the
container fill. `FloatingPill` (scale/fade/`IgnorePointer`, shadow, surface `Material`, `InkWell`) replaced byte-identical
shells in `ScrollToTopButton` and the calendar's
`TodayPill`; `ScrollToTopButton` rides the enclosing `PrimaryScrollController` rather than taking one.
`kFloatingControlsClearance` was the calendar's `kAgendaFloatingControlsClearance` until the
clients list needed it. `measureTextWidth` picks long/short labels (`September`/`Sep`; the agenda title had
ellipsised to "Friday, Septe…"). Six screens copied `TourSteps`' ids/keys/`step()` trio (`keys[id]!`
force-unwraps; `indexOf`/`length` feed "step N of M") and Settings drifted; Clients, History and Team
re-spelled the `bottom:` showcase block. `BrandMark` bundles the 512px derivative, not the 1254px `icon.png` master
(`assets/images/README.md`); auth screens get it from the hero header in `auth_scaffold.dart`, and it is
`decorative` beside a wordmark so a screen reader doesn't read the name twice.

Other shared widgets to check first: `AppointmentCard`, `StatusChip`, `AppAvatar`, `AppEmptyState`,
`AppSearchBar`, `EmployeeColorGrid`, `SectionLabel`, `KeyValuePanel`.

## Decision
Use the shared owner; a third instance composes it rather than copying.

## Consequences
A new hand-built copy will drift the same way.
