# 0059. The dashboard window is one live listener plus one `.get()`

**Date:** 2026-08-10 (`newClientsProvider` archived filter, owner call) · **Rules file:** `.claude/rules/appointments.md`

## Context
Held as one range, the dashboard was a 70-day business-wide live listener capped at `_rangeStreamLimit`
(3000), so above ~42 jobs/day the 8-week trends, busiest weekday and Attention list were computed over a
silent prefix. Splitting into the live week (`liveRangeAround`: this ISO week through next Monday / the
3-day pending horizon) and seven settled weeks read once (`historyRangeAround`) fixed it; each half reaches
back to its own `fetchStart`, so they overlap by a fortnight. All three periods fit in the fetched window,
so a period that widened the live listener would undo the split. A source that had failed was once masked
by a sibling still loading. An archived client is one the owner decided not to look at (2026-08-10); a
server `.where('archived', ...)` would need an `(archived, createdAt)` composite and a deploy.

## Decision
Watch the live half, read the history half once, merge by id; periods and availability conflicts stay
in-memory on the live window; `_firstFailure` prefers an error.

## Consequences
A reducer needing older data widens the history half only. A conflict beyond the live window surfaces when
the window reaches it.
