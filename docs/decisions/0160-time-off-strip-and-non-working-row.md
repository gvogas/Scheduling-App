# 0160. Time-off strip: the reason leads; shared non-working-time ground

**Date:** 2026-08-25 (strip), 2026-08-29 (shared row) · **Rules file:** `lib/features/calendar/CLAUDE.md`

## Context
An unnamed personal block saves the localized `calendar_personal` placeholder, not blank (`add_appointment_sheet.dart`,
`details_edit_body.dart`). The title is written in the author's locale and read in the reader's, so a single
`context.l10n.calendar_personal` test misses a French admin's "Personnel" on an English screen (and the reverse) and
promotes it to the headline. The dashed rail reverses an earlier call that a day off shows its colour only as the
avatar. `neutralContainer` resolves to `AppColors.paper`, also `scaffoldBackgroundColor`. The day-off strip and the
holiday row were hand-written copies that had already disagreed on the caption gap before the holiday row shipped.

## Decision
`_DayOffStrip` always fills the headline (reason, else `<name> is off`); `dayOffReason` matches
`personalTitlePlaceholders` across every locale, and `_DayOffBody` uses the same helper. The `colorScheme.outline` border lives in the shared
`nonWorkingTimeDecoration`. `non_working_time_row.dart` shares four things — `nonWorkingTimeDecoration`,
`NonWorkingTimeText`, `kNonWorkingRowMinHeight`, `kNonWorkingRailWidth` — and each row keeps its own layout (the day off positions a
dashed rail in a `Stack` to avoid forcing intrinsic layout and carries an avatar; a holiday belongs to nobody, so its
rail is an ordinary child). `dayOffReason` returns null when the block has no subject (`hasSubject` false): the
title is already the sentence's subject.

## Consequences
Without the border neither row has a visible container in light. A second placeholder spelling drifts. A new locale
must join `personalTitlePlaceholders`.
