# 0112. The server widget window queries an overlap, capped

**Date:** 2026-08-13 · **Rules file:** `.claude/rules/notifications.md`

## Context
`fetchEmployeeWidgetWindow` (`notification_utils.js`) used to floor `startTime` at
`todayStart - MAX_APPOINTMENT_SPAN_MS` and let `buildWidgetPayload` drop the rest, because a `startTime`
query alone misses a multi-day run that began earlier but works today. It read ~17 days to render 3,
once per notified assignee on every appointment write. Firestore has supported two inequality fields
since 2023. It was also the last sweep read with no ceiling.

## Decision
Read `endTime >= todayStart AND startTime < end` over `[today 00:00 Toronto, +WIDGET_LOOKAHEAD_DAYS)` on
the existing `(employeeIds CONTAINS, endTime ASC, startTime ASC)` composite, `.limit`ed at
`WIDGET_WINDOW_MAX` (200) with a warn at the cap.

## Consequences
Results arrive ordered by `endTime`; `buildWidgetPayload` sorts each bucket itself. A doc missing either
instant is absent from the index, as `sliceForDay` would have dropped it anyway. The test asserts the
bounds are exactly `WIDGET_LOOKAHEAD_DAYS` apart; don't re-widen the floor. Without the cap a bulk import
ships a PARTIAL widget payload in silence.
