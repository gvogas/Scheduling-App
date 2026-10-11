# 0166. `AnalyticsService` returns `void`, never throws, resolves Firebase lazily

**Date:** 2026-09-07 · **Rules file:** `.claude/rules/analytics.md`

## Context
Most call sites are inside an `async` widget handler. A `Future<void>` API would make each either `await` a
round trip in the middle of a user action or wrap it in `unawaited(...)`, and `unawaited_futures` is on.
`Firebase.apps.isEmpty` is the normal state of a widget test: resolving `FirebaseAnalytics.instance` in the
constructor makes merely reading `analyticsServiceProvider` throw, so all ~20 instrumented widgets would
need a provider override, and the first suite that forgot one would fail with a Firebase error pointing
nowhere near the analytics call.

## Decision
Every method is `void`; every send is wrapped and a failure is a `logger.warn` under `ANALYTICS`. The
instance resolves lazily and is null when Firebase is uninitialized, and a null sends nothing.

## Consequences
Returning null rather than throwing-and-catching keeps the suite quiet (a throw would `warn` from every
instrumented widget). No existing test needed an analytics override. The laziness covers sends only:
`navigationObserver` resolves `FirebaseAnalytics.instance` eagerly, safe only because
`analyticsObserverProvider` is read solely in `main.dart`'s `build` and no test pumps it.
