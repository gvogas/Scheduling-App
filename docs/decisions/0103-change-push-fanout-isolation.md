# 0103. Change-push fan-out: no retry, per-recipient isolation, reachability first

**Date:** 2026-08 · **Rules file:** `.claude/rules/notifications.md`

## Context
`notifyAppointmentChanges` is registered WITHOUT `retry: true` (a duplicate push is worse than a rare
missed one), so a transient failure escaping the per-recipient loop is retried by nothing: one bad first
assignee threw out of the handler and recipients 2..N were dropped permanently, in silence. Five sibling
fan-outs already carried the guard. Separately, claiming a ledger before asking whether the recipient
could be reached cost 2 writes + 2 reads per unreachable (job, assignee) on every run (~48 of each across
the overdue window), and the digest paid a 200-doc read plus a payload build per unreachable employee daily.

## Decision
Every per-recipient loop isolates its recipient in a try/catch. `_loadRecipient` + `_canReachRecipient`
run before any work: above the series claim and `fetchEmployeeWidgetWindow` in `handleAppointmentWrite`,
above the window read in the digest, above the ledger `create()` in `_deliverRecipientOnce`. Both reads
share the per-sweep `cache`.

## Consequences
"No ledger written" is indistinguishable from "written then released", so the late-token retry still
works. The series-claim ORDERING is unchanged: a send that throws after `claimSeriesNotice` committed still
suppresses the sibling for its window.
