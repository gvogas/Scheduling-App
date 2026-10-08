# 0159. `AppointmentCard` is the one card; crew bar bands every assignee

**Date:** 2026-07-31 (P2) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
P2 replaced `AppointmentTile` (deleted with `colorFromMap` and `resolveAssigneeNames`). The crew bar followed the
first assignee alone; the pre-redesign grey-for-multi-crew was doubly wrong, since grey reads as unassigned. The meta
line was a single avatar plus `Theo +1 · Client` (`calendar_crewAndClient`, deleted). `alwaysShowChip` was not
ported (every call site passed `true`); cancelled dims to 0.6, not 0.75.

## Decision
`crewFor` feeds `crew:`; `_crewBarDecoration` bands every assignee up to `_kMaxCrewShown` (4), the same cap as the
overlapped avatar stack. The card uses `IntrinsicHeight` to stretch the bar.

## Consequences
Nothing under the card may use `LayoutBuilder`, `AutoSizeText` or `FittedBox`; `_CrewAvatars` computes its own
width for that reason.
