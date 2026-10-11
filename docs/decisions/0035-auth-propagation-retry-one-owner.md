# 0035. Auth-propagation retry: one predicate, one delay ladder

**Date:** by 2026-08-14 (predicate default), 2026-08-15 (`kAuthPropagationDelays`) · **Rules file:** `.claude/rules/error-handling.md`

## Context
A Firestore read fired right after sign-in can return `permission-denied` until the new token
propagates. The `retryWhen` predicate for that was copied byte-identically into three repositories;
two carried a "keep in sync" comment naming only ONE twin, so neither author knew there were three.
`retryAsync` had no predicate at all, so it retried a genuine rules rejection three times before
surfacing it. A hand-rolled `_retryOnAuthPropagation` (`catch (FirebaseException)`-then-delay) sat
under a rule that named it as the reference use of the shared helper it did not call; it is gone.

## Decision
`isAuthPropagationDenied` and `kAuthPropagationDelays` (`lib/core/utils/retry.dart`) are the defaults
on `retryAsync` and `retryStream`. No local predicate, no inline retry, no per-site delay budget.

## Consequences
A second copy of either drifts silently; a site that names `kAuthPropagationDelays` does so only to be
explicit.
