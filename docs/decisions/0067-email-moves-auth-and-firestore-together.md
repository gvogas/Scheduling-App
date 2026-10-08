# 0067. An email edit moves Auth and Firestore together

**Date:** 2026-08-04 (`changeEmployeeEmail`), 2026-08-10 (P5 self branch) · **Rules file:** `.claude/rules/employees.md`

## Context
The email field had been read-only since P4c. A Firestore-only change would leave the person signing in at the
old address while every admin surface showed the new one, and desync the two stores `createEmployeeAccount`
joins on. `changeEmployeeEmail` (2026-08-04) joins them; `updateEmployee` is its only caller, so "an email edit
always moves Auth too" is a property of the one save path. P5 (2026-08-10) opened a SELF branch through the pure
`resolveEmailChangeCaller`. Its freshness gate was first keyed on `isSelf`; an admin editing their OWN roster row
is `isSelf` but arrives through `updateEmployee`, which has no re-auth step, and since `_changeAuthEmail` runs
before the Firestore write the whole edit (name, phone, colour, availability) died as an opaque `stale-auth`
five minutes after sign-in. The budget dropped to 5/hour (from the 20 it shared with account creation).

## Decision
Auth first, then Firestore, with a revert of Auth on failure; the transaction re-checks the previous email and
uniqueness (`email-changed` on a concurrent edit, surfaced as the same "try again" as the client's own guard).
`resolveEmailChangeCaller` returns separate `isSelf` (routes the notification) and `isAdmin` (gates freshness)
fields; `assertFreshReauth` (shared with `deleteAccount`) applies to non-admins only, rejecting an `auth_time` over 5 minutes old. `SelfEmailService`
re-authenticates before calling — an unattended unlocked phone changing the sign-in address is the
account-takeover primitive — the same way `completeAccountSetup` orders password before activation.

## Consequences
An unattended ADMIN session can still rewrite a colleague's address, bounded by `assertAdmin` and the budget;
closing it needs a re-auth prompt on the admin save path first. `verifyBeforeUpdateEmail` is not the answer: it
flips Auth outside the callable with no trigger to reconcile `users.email`. The push notices are courtesies, not
guarantees (no live FCM token, no notice). An admin editing their own row is a self change and must not be pushed
a notice about it.

## Functions side
A doc with no `uid` is refused `account-has-no-auth` (no-uid docs take the direct client write). The admin-edit
notice goes to `TIMED_RECIPIENT_ROLES`, not the change set: the change set is employees-only because an admin
normally makes those edits, and here the admin is a different person from the one whose sign-in moves. Both pushes
run after the commit and swallow failures, since the change is already durable in both stores.
