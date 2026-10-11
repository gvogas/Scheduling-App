# 0075. `workingDays` is Sunday-indexed with one conversion owner

**Date:** 2026-08-01 (P4 availability), 2026-08-11 (`sundayIndexOf` made the one owner), 2026-08-15 (`maxJobsLabel`) · **Rules file:** `.claude/rules/employees.md`

## Context
`weekStartForLocale` and `weekdayLabelsForLocale` read intl's Sunday-indexed `NARROWWEEKDAYS`; storing
Monday-first would put a `% 7` at every read and write, and one missed conversion shifts a whole roster by a day.
`sundayIndexOf` was private to `month_grid.dart` and had grown three more hand-spellings (the dashboard capacity
reducer, `availability_conflict_policy.dart`, the daily-load chart labels), each restating "DateTime.sunday is 7".
The dashboard's Attention list and My details each carried an identical private day-name joiner. The Team sheet
and My details offer the same `maxJobsPerDay` field; this rule once claimed the picker, option list and label
were all extracted while only the option list was — `maxJobsLabel` was added 2026-08-15 to make it true, replacing
a `noCap` ternary re-spelled at three sites (the same drift the `AvailabilityPanel` extraction had ended).

## Decision
Convert only through `sundayIndexOf`; write back through `orderedWorkingDays`' `storedIndex`; `formatWorkingDays`
takes unrotated `labels` because it indexes them by `storedIndex`; `joinWeekdayNames` resolves its own labels so the
unrotated rule can't be got wrong at a call site. `showMaxJobsPicker`, `kMaxJobsOptions` and `maxJobsLabel` are
shared. (The old text placed these in one file; the pickers are in `work_schedule_pickers.dart` and the option list,
label and `formatWorkingDays` in `work_schedule_policy.dart`.)

## Consequences
A display-ordered label list silently mislabels every day. The read-only detail omits an uncapped person's row
(a read-only body omits empty sections), so it doesn't call the label helper.
