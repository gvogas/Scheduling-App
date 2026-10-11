# 0014. No client `runTransaction` on routine or concurrent paths

**Date:** 1.34.1 (fatal seen; unfixed upstream as of cloud_firestore 6.7.0), 2026-10-07 (re-run note moved from a code comment, audit I5) · **Rules file:** `CLAUDE.md`

## Context
The cloud_firestore iOS plugin mutates an unsynchronized `NSMutableDictionary` from the transaction
queue (`FLTTransactionStreamHandler` → `_transactions`), so concurrent client transactions can
EXC_BAD_ACCESS; this was seen fatal in 1.34.1. The FCM and Live Activity token repos were moved to plain
get-then-set — a double upsert can only re-stamp `createdAt`, which is cosmetic.

A transaction body can RE-RUN, so state it accumulates for use after the commit must be rebuilt per
attempt: `updateAppointments` clears its `written` map inside the body, or it would name docs an
abandoned attempt touched and this commit did not.

## Decision
Only two client transactions remain — the employee-edit uniqueness re-check and the series update —
both isolated one-at-a-time admin actions.

## Consequences
Don't reintroduce transactions on the token repos, and don't add a transaction call site that can run
concurrently with those two or with each other.
