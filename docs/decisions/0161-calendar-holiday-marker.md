# 0161. Holidays: computed, display-only, a rule inside the day token

**Date:** 2026-08-29 (design: `docs/archive/2026-08-29-calendar-holidays.md`) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
A bundled holiday table was rejected: whatever range it covered, the calendar would stop marking holidays the year
after with no error. A marker in the token's `fill` is erased by selection, which wins the fill. On a selected day
every candidate hue muddies against the primary-blue fill (Greek flag blue, the first pick, was nearly invisible),
so the rule goes `onPrimary`; the agenda row below carries colour and name. Whitening on `InlineMonthCalendar`,
which has no agenda row, dropped the category at the moment a date is chosen. The dark construction hue was
`darkAmber`, which IS dark crew amber, so the rule and the crew dot ~7px below (`_kRuleInset` 4 + `_kDotGap` 3) painted the same colour until
2026-08-29. "`core/` must not import a feature type" was once given as a reason for plain palette fields; that rule
does not exist here.

## Decision
`domain/holidays.dart` derives the dates by arithmetic. All three `calendarDayCircleDecoration` callers take the
marker; the picker matters most, since it is the one surface where the marker can prevent a mis-booking rather than
report one. `calendarDayTokenWithRule` paints a 2px rule 4px above the
token's bottom and resolves its own colour; the number is never recoloured (owner call). `keepHueWhenSelected`
lifts rather than whitens (only `InlineMonthCalendar`), clearing 3:1 and no further (the 3:1 floor is pinned in `holiday_marker_test.dart`; for off-month only "faded", alpha < 1, is pinned), since each step past that pulls
the three hues toward the same white. Off-month alpha is 0.45, so the rule fades with the faint number — the NORMAL case for the construction
shutdown, whose run crosses the July/August boundary every year. Hues are three `AppPalette` fields (the same shape as `crewColorOf`
reading `palette.crewOverride`): `lerp` interpolates a `Color` field but can only snap a map at the midpoint, and
`holidays.dart` imports `l10n.dart` for its label resolvers, so taking `HolidaySet` would drag `AppLocalizations`
into `core/theme/`, which has zero feature imports.

## Consequences
A surface handed a colour could render a token and forget the marker, compiling clean. A hue sharing a crew colour
twins with the dot beneath it; check `_darkCrewOverride`'s values, not just `crewPalette`.
