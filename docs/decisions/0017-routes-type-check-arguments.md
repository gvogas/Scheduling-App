# 0017. Arg-required routes type-check their arguments

**Date:** 2026-09-05 (rule recorded, `d68422bf`) · **Rules file:** `CLAUDE.md`

## Context
`AppRoutes.onGenerateRoute` had seven `settings.arguments! as T` casts, which red-screened the app on a
malformed or argless push — something a deep link can produce.

## Decision
`_args<T>(settings)` returns null rather than force-casting, and `_invalidRoute` renders
`InvalidRouteScreen`, a screen the user can leave. The HOME route keeps its own, different answer —
least-privilege defaults rather than a recovery screen — because it is reached from every cold start
and back stack; that asymmetry is deliberate and documented at the site.

## Consequences
Don't add a force cast for a new route, and don't "unify" HOME onto the recovery screen.
