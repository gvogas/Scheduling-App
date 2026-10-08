# 0137. Business-time primitives: dependency-free leaves, calendar-day offsets, hoisted formatters

**Date:** 2026-08 (multi-day work) · **Rules file:** `functions/CLAUDE.md`

## Context
`time_utils.js` is shared by `notification_utils.js`, `live_activity_utils.js` and
`widget_payload_utils.js` so a push and the Live Activity card can't drift on how they render one
instant; those consumers sit on a `notification_utils` → `live_activity_dispatch` → `live_activity_utils`
require chain. The `businessMidnight(...businessYmd(x), d + n)` spelling was written out at four sites
(`day_slice_utils` twice, `widget_payload_utils`, `notification_policy`) — the shape behind the
documented DST bug. Constructing an `Intl.DateTimeFormat` costs ~100x a `.format()`; once
`day_slice_utils.js` reached `businessYmd`/`businessOffsetMs` ~18 times per `sliceForDay` and
`buildWidgetPayload` probed every record against every day, a busy tech's 200-doc window paid about a
second of CPU per push. `resolveWindow` runs `businessMinutesOfDay` twice through `Intl`, so the
record-taking chain `sliceForDay` → `dayCountOf` → `lastWorkDayMs` resolved the same window three times
per probe; hoisting `dayCountOf(c)` into a local in `travel_utils.js` charged every reminder-only and
undelivered candidate for a value it discards.

## Decision
`time_utils.js` requires nothing. `businessDayStartMs(instant, offsetDays)` owns "business-local
midnight, n days out", applied as a CALENDAR day with the zone offset re-resolved. `YMD_FORMAT` and
`OFFSET_FORMAT` are module-scope. `day_slice_utils.js` (hand-mirror of `appointment_day_slice.dart`)
requires only `time_utils.js`, re-exports `MAX_APPOINTMENT_SPAN_DAYS`, and threads a resolved window
through `lastWorkDayOfWindow`/`dayCountOfWindow`. `travel_utils.js` asks `dayCountOf(c)` last in
`kind === "leaveNow" && delivered > 0 && dayCountOf(c) <= 1`.

## Consequences
A require in `time_utils.js` closes a cycle. `n * 86400000` is an hour wrong on a shift day (jest pins
the 23- and 25-hour days). A formatter moved back inside a function is a CPU regression, not tidiness.
`day_slice_utils`' jest cases reuse the Dart suite's worked examples, so change both sides together.
