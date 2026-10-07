# 0038. A payload allowlist stays a superset of the deployed one; `#compat-<version>` carve-outs

**Date:** 2026-08-21 (opened) / 2026-08-29 (retired) · **Rules file:** `.claude/rules/security.md`

## Context
`assertPayloadShape` throws `unexpected-field` on the first unrecognised key, so removing a key that a
shipped build still sends breaks that build the moment the backend deploys, with no rollout window.
The worked example is `createEmployeeAccount`'s `isAdmin` (`#compat-1.47.0`). Opened 2026-08-21: the
role was hard-coded `"employee"` server-side while the key stayed accepted-and-ignored, so admin builds
≤ 1.47.0 could still create accounts and reset passwords. Retired 2026-08-29, only once BOTH halves
held: the current client sent no such key, and the owner confirmed the fleet was wholly on 1.53, so no
build at or below 1.47.0 remained. The retirement could not ride along with the 1.48 app build that
stopped sending the field; it needed its own functions deploy (`docs/DEPLOYMENT.md` log, 2026-08-29).

## Decision
Neutralize a field where it is USED (stop reading it; hard-code the safe value), leave it accepted and
ignored in the allowlist, and tag the entry `#compat-<version>`. Retire it only when the current client
sends no such key AND no build at or below that version remains in the fleet, in a deploy of its own.

## Consequences
The fleet half is the one that is easy to assume rather than verify; the superset contract is about
what builds SEND, not what they are numbered. See `docs/DEPLOYMENT.md` §4a.
