# 0073. `users.name` is composed, never abandoned

**Date:** 2026-08-01 (P4 first/last split), 2026-08-19 (dash regression) · **Rules file:** `.claude/rules/employees.md`

## Context
P4 added `firstName`/`lastName`, but `name` stayed the field lists sort and display on, and an `orderBy('name')`
excludes docs missing it, so a user whose `name` went empty could vanish from a list. (The old text said
`watchAllUsers()` orders by `name`; it no longer does — see ADR-0072 — but the fallback still guarantees a sortable,
displayable value.) A 2026-08-19 cleanup flattened the `'—'` fallback (EM dash) and the working-hours EN dash to
plain hyphens and rewrote the tests to match, so the tests pinned the regression rather than catching it. The
four-argument display unpack had been spelled at four render sites.

## Decision
Every write path composes `name` through `composeEmployeeName`, falling back to the stored name and then
`kUnnamedEmployee`. Rendering reads `EmployeeRecord.displayName` (mirroring `ClientRecord.displayName` →
`ClientNamePolicy.displayFor`). The edit sheet seeds First from the whole stored `name` when both halves are
empty, so a legacy single-name doc round-trips unchanged. `EmployeeFormValidator` takes the halves, since a
composed value cannot express "last name missing"; the invite demands both halves, the edit leaves the last name
optional.

## Consequences
A mechanical non-ASCII sweep over `lib/` changes shipped strings, not comments.
