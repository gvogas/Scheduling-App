# 0069. Employee form busy state is keyed per doc id

**Date:** 2026-08-02 (P4c roster) · **Rules file:** `.claude/rules/employees.md`

## Context
`EmployeeFormActivity` is app-wide, but the roster can show several expanded `PendingInviteTile`s at once, each
with its own Reset and Remove. A single boolean made every row claim to be busy when any one was, and made
`_save`'s reentrancy guard refuse a DIFFERENT employee's action, which `EmployeeSaveBusy` then dropped with no
spinner and no notice.

## Decision
Busy state is `savingIds` / `deletingAccountIds`; `_save` takes a `docId` and guards per key. Rows ask
`isSavingId` / `isDeletingAccountId` through a Riverpod `select`, so each rebuilds only when its own state flips.
`isSaving` survives as an aggregate for the two modal person sheets; `isDeletingAccount` has no in-app caller (the
sheets have no delete affordance; `PendingInviteTile` asks the id-keyed form). A brand-new person keys on `''`,
which is correct because the invite sheet is modal.

## Consequences
Collapsing back to booleans, or patching a busy bug with a call-site flag, silently drops a second row's action.
