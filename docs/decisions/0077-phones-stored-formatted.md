# 0077. Phone numbers are stored formatted

**Date:** 2026-08-02 (owner call) · **Rules file:** `.claude/rules/employees.md`

## Context
`PhoneInputFormatter` masks every phone field as typed, so `phone`, `emergencyPhone` and each contact phone persist
as `(514) 555-1234`. Two pass-throughs are load-bearing: anything with `+` is untouched (an international number has
no fixed 10-digit shape), and digits past the tenth are appended so an extension survives. `Uri` percent-encodes the
brackets and space into a `tel:` path some dialers reject. `ClientSearchPolicy.digitsOnly` already normalized both
sides, so phone search was unaffected. Legacy and Wave-imported docs were NOT formatted, which stayed invisible until
a person's `name` became their phone verbatim and Wave's list mixed "(514) 234-0818" with "4506220931". At the old
`TextLimits.phone` of 15 the pass-throughs were unreachable: `LabeledTextField` appends the `LengthLimitingTextInputFormatter` AFTER
the mask, a NANP number typed with its leading 1 formats to 16 chars, so the 11th digit could never be entered and
every keystroke re-truncated with no error.

## Decision
Store formatted; `launchPhoneCall` strips to digits (keeping a leading `+`). `TextLimits.phone` is 24, never sized
to the 14-char happy path. `functions/scripts/backfill-client-phone-formatting.js` (idempotent, `--dry-run`)
formats only NANP: ten digits with no `+`, or eleven beginning with 1, whose country code is dropped — narrower than
`formatPhoneNumber`, whose progressive mask renders eleven digits as "(151) 455-5123 4" and would rewrite a
half-entered number into a shape claiming to be complete.

## Consequences
The `+` bar on the ten-digit branch is load-bearing: "+49 30 123456" is also ten digits.
