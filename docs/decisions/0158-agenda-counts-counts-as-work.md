# 0158. Agenda header, Done rule and dots share `countsAsWork`

**Date:** 2026-08-08 ("Done" label), 2026-08-25 (cancelled dropped) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
`calendar_closedCount` read "Closed" until the owner chose "Done" (2026-08-08); a cancelled visit sinks into the same
block, so the label is deliberately looser than the set. The header read `1 JOB · 1 DONE` for a day holding one
called-off visit — wrong twice — and disagreed with the dots, which had dropped cancelled since 2026-08-17. There
were four spellings of the predicate, and the header's was the odd one out.

## Decision
`countsAsWork` ("not cancelled, not time off", `appointment_day_slice.dart`) is the one owner: `_jobLabel`, the
`_ClosedRule` count (re-filtered over the closed tail, never `length - index`), `dottedJobsOn` and
`countsAsLoadOn` (it + `runsOn`). Only counts are filtered; cards still render. The `Done · N` rule is suppressed
at zero.

## Consequences
A fifth spelling lets header, rule and dots disagree about what a job is; an unsuppressed rule draws `Done · 0`
over a day of cancellations.
