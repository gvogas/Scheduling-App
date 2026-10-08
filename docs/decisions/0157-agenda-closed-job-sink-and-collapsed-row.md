# 0157. Agenda sinks closed jobs; the collapsed row keeps avatars and a time line

**Date:** 2026-08-08 (sink + collapse), 2026-09-11 (option B restoration) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
2026-08-08 gave `_agendaOrder` an open-before-closed tier and collapsed closed rows. The collapse dropped the
avatar stack and put the time in a `Row` beside the client, landing near 64px against a full card's ~110; the row
read as shrunken rather than finished, which got reported. That `Row` gave `Flexible(time)` and
`Expanded(label)` equal flex, so the time was capped at half the row and a multi-day
`"9:00 AM – 5:00 PM · Day 3 of 5"` was ellipsised. Owner call 2026-09-11 (option B) restored avatars and put the
time on its own line (~90px). Rejected: dropping `collapseWhenClosed` (finished work takes full height again) and
padding alone (likely wouldn't resolve the complaint). The multi-day counter stays on collapsed rows, deviating from
the approved mockup, because a closed job renders on every day of its run.

Known, deliberately unfixed: `successContainer` (collapsed-Done tint) and `StatusChip`'s "Complete" fill both
resolve to `AppColors.greenFill` in light (contrast 1.00, the capsule disappears); dark double-composites at 16%
alpha, so it is light-only and was never caught. Light `secondaryContainer` is also `greenFill`, so a selected
card and a collapsed Done card match.

## Decision
`_agendaOrder` reads stored status via `AppointmentRecord.isClosed`, never `displayStatus`, so it stays clock-free. `isClosed` is the model-layer mirror of
`AppointmentStatus.isTerminal`, so a pure module can ask without pulling Material in through `status_chip.dart`;
it reads the raw `done`/`completed`/`cancelled` set (`terminalStatusRawValues`, ADR-0044), and `displayStatusAt`
calls it rather than re-spelling it. (The old rules called `isClosed` the owner of that triple; since the terminal
set was unified it delegates to `isTerminalStatusRaw`.) `collapseWhenClosed` is passed only by
`AgendaSliverList`; only the tint is gated on `isDone`. `_kClosedMinHeight` (48) is a `minHeight` clearing
Material's minimum for the full `InkWell`.

## Consequences
If the contrast defect is taken, tint the card with something that is not the chip's fill; never touch
`StatusPill` (shared by the detail header, day-off strip, History filter chips and `UserStatusChip`).
