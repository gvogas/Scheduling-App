# 0041. A guard fails closed on missing input

**Date:** by 2026-08-14 (rule first committed) · **Rules file:** `.claude/rules/security.md`

## Context
`if (req.auth.token && req.auth.token.<claim> !== true) throw` reads as a check but lets a caller
through by presenting no token at all. That the platform always populates the claim today makes the hole
unreachable, not correct: the guard is what the written risk assessment leans on, so it has to hold on
its own terms. The rule's first worked example was `completeEmployeeSetup`'s `email_verified` check;
that guard was removed 2026-08-21, when the starting password became a random per-account secret, so
don't go looking for it.

## Decision
Copy `assertFreshReauth` (`functions/security.js`): it reads
`auth && auth.token ? auth.token.auth_time : undefined`, and `isReauthStale` treats any non-number as
stale, so a caller with no claim can never read as recently re-authenticated. Write
`if (!req.auth.token || ...)`.

## Consequences
A test passing `token: {}` does not catch the inverse shape; only a test that omits the key does.
