# 0162. Holiday list precedence, agenda row placement, three date traps

**Date:** 2026-08-29 · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
The two Easters coincide roughly one year in three (2028, 2031, 2034), so one day can carry both Good Fridays. The
holiday agenda row reuses the day-off vocabulary because a holiday is non-working time. Three published date rules
are wrong in the obvious implementation: Patriotes "on or before May 25" is right six years in seven and wrong when
the 25th is a Monday (2026); the first build shifted Canada Day for a Sunday but not Fête nationale, answering the
same legal question two ways in 2029; the widely repeated "Sunday after the third Saturday" for the CCQ shutdown is
right for 2024–2026 and wrong for 2022 and 2023.

## Decision
`holidaysOn` returns a list; `HolidaySet`'s declaration order is the marker precedence (`markerSetFrom`) and the
agenda renders every row. The row (`HolidayAgendaRow`: `neutralContainer`, `outline` border, `r12`, mono all-caps tag) lives in
`AgendaSliverList` (required `day`), above the skeleton and empty state. The week agenda (`weekAgendaSlivers`)
places rows under each day bar via `AgendaSliverList.holidayRows`, and its `inWeek: true` lists skip them, so a
loading week shows a bare skeleton with no holiday rows. Patriotes = Monday strictly before May 25; June 24 and July 1 both move to the next day on a Sunday; CCQ =
the Sunday preceding July's last Saturday. Each is pinned in `holidays_test.dart` against published dates.

## Consequences
"First match" makes the colour depend on build order. A raw nullable `day` lets the holiday row and the job list
describe different days.
