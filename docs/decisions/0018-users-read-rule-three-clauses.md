# 0018. The `users` read rule has three clauses

**Date:** 2026-08-08 (fourth clause deleted with `#compat-1.37.1`), 2026-08-21 (an unrelated callable guard removed) · **Rules file:** `CLAUDE.md`

## Context
A fourth `email_verified && status == 'invited' && email == token.email` read clause existed only
because the retired invite-code flow left `uid` empty until redemption; it was deleted 2026-08-08 with
the rest of the `#compat-1.37.1` shim. That was a `firestore.rules` READ clause, unrelated to
`completeEmployeeSetup`'s `email_verified` callable guard, which was removed separately on 2026-08-21 —
two different `email_verified` checks, both gone, for different reasons. P4c mints the Auth account up
front, so an invited person reads their own doc through clause 3.

## Decision
Three clauses: admin, `status == 'active'`, or `uid == request.auth.uid`. A new `users` query satisfies
one of them through its WHERE constraints.

## Consequences
Don't re-add an email-matched clause. An ordinary employee still cannot see a pending account, because
clause 2 requires `active`.
