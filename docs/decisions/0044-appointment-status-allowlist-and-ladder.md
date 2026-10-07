# 0044. Appointment status: four stored values, one display ladder, one terminal set

**Date:** 2026-07-09 (`confirmed` retired), 2026-08-08 (terminal set), dashboard ladder collapse · **Rules file:** `.claude/rules/appointments.md`

## Context
`confirmed` was retired 2026-07-09 when the picker collapsed to three states; legacy `confirmed`/unknown
docs still exist, and an unchanged status is re-written verbatim, so a raw re-serialization failed the
whole save or series update with `permission-denied`. The dashboard carried a hand-copied "mirror" of the
display ladder that drifted: it lacked the `isPersonal` carve-out, so a past personal block read
"Scheduled" on its card while sitting in the Attention list as overdue. An earlier note justified that
carve-out by claiming personal jobs had no mark-done flow; they do (`DetailsActionBar` has no
`isPersonal` branch). "Terminal" as raw strings had four definitions until 2026-08-08, and History's had
dropped `completed`, so such a doc rendered Done on its card and was invisible in History and history
search, with no error.

## Decision
Store only `pending`/`in_progress`/`done`/`cancelled`. `overdue` is display-only and its `.raw` throws.
`AppointmentRecord.displayStatusAt(now)` is the one ladder; `terminalStatusRawValues` the one raw
terminal set; `AppointmentStatus.storedRaw` normalizes every re-serializing write.

## Consequences
A second ladder or terminal set drifts silently. Don't use `fromRaw(x).raw` (throws on `overdue`, keeps
legacy values).
