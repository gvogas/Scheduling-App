# 0132. Provider lifetime: tap-handler reads, which stream, combiner retry

**Date:** 2026-09-03 (tap-read, hold), 2026-09-19 (combiner retry) · **Rules file:** `.claude/rules/frontend.md`

## Context
`CrewFilterButton` read an `autoDispose` provider from its tap handler: nothing was subscribed, so the read
built it cold, got `AsyncLoading`, took `?? []` and disposed it; the sheet offered only "All crew", on every
tap, with no log. `employeesStreamProvider` is `autoDispose` so a transient sheet cannot pin a second live
`users` listener; a `HubShell` tab lives all session, and the calendar header already watches
`allUsersStreamProvider`, which also carries invited/disabled users, so a consumer re-applies
`isActive && isAssignable`. `AddEventController.applyPrefill` lacked a hold; the tell was a keep-alive in its
unit test with no production counterpart. Invalidating a combining `Provider.autoDispose<AsyncValue<T>>`
(`_firstFailure`, `liveMapTeamProvider`) recomputes from cached errored sources, and automatic retry is off
app-wide (`main.dart`), so Retry did nothing; Riverpod's test-default retry masked it. `retryDashboardSources` gates each
invalidate on `hasError`; `_retryTeam` does not gate `allPresenceStreamProvider`.

## Decision
Watch in `build` and pass the value in; permanent widgets derive from `allUsersStreamProvider`; a
`Notifier` awaiting one holds it with `ref.listen` closed in `finally`; Retry invalidates the errored
sources.

## Consequences
A widget test of a Retry needs `retry: (_, _) => null` on its `ProviderScope`.
