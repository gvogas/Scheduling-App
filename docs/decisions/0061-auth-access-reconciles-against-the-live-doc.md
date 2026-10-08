# 0061. Auth access reconciles against the live users doc

**Date:** 2026-09-28 (invited docs revoke), 2026-10-07 (S4 re-provision re-enables) · **Rules file:** `.claude/rules/employees.md`

## Context
Firestore trigger events can arrive out of order, so a delayed activation could restore an account that had
since been disabled or deleted; Auth writes cannot join a Firestore transaction. Until 2026-09-28
`reconcileAuthAccess` short-circuited on a live `invited` doc, so an active-to-invited demotion in the
console never revoked the credential. Once it did revoke, an S4 re-provision reset (`resetProvisionedPassword`)
set a password on a still-disabled account, handing over a password nobody could sign in with (owner call
2026-10-07).

## Decision
`bridge_reconcile.js` reads the current profile and bridge rows transactionally, keeps bridge-ownership checks,
and re-checks the live profile after the Auth write, retrying when it changed. Only a uid or bridge-owner
mismatch returns early; anything not `active` computes "revoke". It is called only when
`authAccessChange(before, after)` is non-null, so a newly created invited doc is never disabled and invited
accounts can still complete setup. `resetProvisionedPassword` sends `disabled: false` with the password.

## Consequences
Re-adding an `invited` short-circuit lets a demoted account keep signing in. Dropping `disabled: false`
re-breaks the re-provision of a demoted account.

## Functions side
`bridge_policy.js` (`shouldHaveBridge`, `bridgeBody`, `bridgeMatches`, `classifyBridgeRow`) is shared with
`scripts/backfill.js`, which had byte-identical copies of the first three under a comment calling the duplication
deliberate. `classifyBridgeRow` guards that script's `--prune-orphans` delete: `current` / `retained` / `orphan`. A
`retained` row is a uid claimed by a users doc the run SKIPPED; deleting it locks a live employee out of everything.
