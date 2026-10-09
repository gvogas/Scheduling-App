# 0185. Employee setup requires a password; the legacy setup path is retired

**Date:** 2026-10-09 · **Rules file:** `.claude/rules/employees.md` · **Supersedes:** the legacy-setup halves of ADR-0064 and ADR-0066

## Context
`completeEmployeeSetup` accepted a payload without `newPassword` for builds that changed the password through
Auth before calling it; re-provision stamped `setupRequiresPassword` so such a setup could not activate a reset
invitation (`setup-upgrade-required`, ADR-0066). The client mapped that refusal and the retired
`email-not-verified` message to `AuthFailureSetupNotAvailableYet` (ADR-0064), for a backend rolled back under a
shipped build. On 2026-10-09 the owner confirmed every phone runs 1.63.0+93 or newer; that build always sends
`newPassword`, and no deployable backend still raises `email-not-verified`.

## Decision
`newPassword` is required (`requireString`, 128, then `isStrongPassword`); a missing one is
`invalid-argument / invalid-newPassword`. The no-password branch, the `setupRequiresPassword` read and the
re-provision stamp are gone. The client drops both mappings, `AuthFailureSetupNotAvailableYet` and
`error_setupNotAvailableYet`; either message would now fall to `AuthErrorMapper.map` (`AuthFailureUnknown`).
The payload allowlist is unchanged.

## Consequences
`setupRequiresPassword` stays on both `/users` denylists: the field persists on old docs and must stay
server-owned. Rolling the backend back to a pre-simplified-auth commit is no longer degraded gracefully by the
app; it would surface as an unknown setup failure.
