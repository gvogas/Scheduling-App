# 0036. Sealed action outcomes; a reentrancy skip is `Busy`, never an exception

**Date:** by 2026-08-14 (rule first committed) · **Rules file:** `.claude/rules/error-handling.md`

## Context
`EventDetailsController`'s status setters returned `Object?` with `null` = success, so a write skipped
by the reentrancy guard was indistinguishable from one that committed: the sheet announced "marked as
complete" and closed having written nothing. Separately, all three save controllers returned
`XSaveFailed(SocketException('in-flight'))` for a reentrancy skip, and `_classifyError`
(`error_cause.dart`) keys on the `SocketException` TYPE — so a double-tap rendered "Couldn't save … —
you appear to be offline" while online, with the real save succeeding behind the error.

## Decision
A multi-state action returns a sealed outcome (`EventDetailsActionOutcome`: `Ok` / `Busy` /
`Failed(error)`, beside `EventDetailsSaveOutcome`); a skip is a `Busy` member (`EventDetailsActionBusy`,
`EmployeeSaveBusy`, `ClientSaveBusy`) that surfaces nothing. The client controller's
`SocketException('offline')` sentinel is correct and stays — there the offline classification is the
intended one.

## Consequences
A sealed family makes the compiler force the third branch at every call site; a sentinel compared with
`identical()` does not.
