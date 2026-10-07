# 0057. Job templates, Book again and the custom-address owner

**Date:** 2026-09-02 · **Rules file:** `.claude/rules/appointments.md`

## Context
Templates were always display-only quick-fill. `JobTemplate.endMinutesOfDay` was a third spelling of the
end-time clamp and was removed when seeded lengths moved to `AddEventController.setDurationMinutes`, which
the template chip and Book again both call. Book again (`AppointmentPrefill.bookAgain`) is pinned from both
sides so a field added to `AppointmentRecord` that leaks into a duplicate fails a test; the draft saves as an
ordinary `pending` appointment, not a copy. The action is gated on a non-empty `clientId` rather than "not
personal" because `placeholderClient` composes an empty `ClientRecord` and `clientRequired` only checks for
non-null. The edit form's address pill and the prefill used to answer "own address?" separately;
`usesCustomAddress` (see the comment in `custom_address_policy.dart` for why raw `address` is the wrong side)
now owns it. The prefill's "stays behind" list once included the crew signal, removed 2026-09-03
(ADR-0054).

## Decision
Templates seed title and length on add only; Book again carries who and what, never when; one helper owns
custom address.

## Consequences
Collapsing `endTimeFor` (clamps at 23:59) and `defaultEndTime` (wraps) needs a decision on which a bare late
start should get.
