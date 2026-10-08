# 0168. Analytics events: success branch only; three parameters absent on purpose

**Date:** 2026-09-07, 2026-09-13 (`overdue_review_applied`) · **Rules file:** `.claude/rules/analytics.md`

## Context
The `Busy` members of the sealed outcomes are the reentrancy guard's no-op and wrote nothing; counting one
reports jobs and clients that never existed (the same reason they surface no notice). `job_completed`'s
`has_notes` would read the parent `fieldNotes` string, the LEGACY path (crew notes live in a
subcollection), so it would read near zero. `search_used` fires at the debounce commit, the one place that
knows a search ran, before results are fetched. `contact_action` fires from the shared launch helpers,
which by construction don't know the calling screen.

## Decision
Events fire on the sealed success branch (`AddEventSubmitted`, `EventDetailsSaved`, `EventDetailsActionOk`,
`ClientSaved`, `EmployeeAccountCreated`, `OverdueReviewApplied`). `has_notes`, a `search_used` result count
and a `contact_action` `source` stay absent. `overdue_review_applied` (2026-09-13) carries `action`
(`AnalyticsOverdueReviewActions.complete` / `not_done`) and a bucketed `count`, a new `allParams` key.

## Consequences
`note_added` already answers how often notes are written. A later result count would be a second event
for one search. Threading a surface into the launchers puts a display concern in a launcher. A new
parameter shows in GA reports only after it is registered as a custom dimension.
