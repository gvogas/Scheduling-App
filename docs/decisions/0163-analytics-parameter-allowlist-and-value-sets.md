# 0163. Analytics parameters: a key allowlist, closed value sets, bucketed counts

**Date:** 2026-09-07 (module added), 2026-09-10 (value sets completed) · **Rules file:** `.claude/rules/analytics.md`

## Context
The app holds client phone numbers, street addresses, job notes and employee emails. None of them leaks
by a deliberate decision; one leaks through a single call site passing a convenient
`'client_name': record.name`, or a domain model `toString()`-ed onto the wire. On 2026-09-10 ~22
`direction`/`filter_name`/`setting_name`/`action` values were still bare literals across eight files while
the module header claimed to own "every event name, parameter name and parameter value"; nothing rejects an
undeclared value, so `'app_lock'` vs `'applock'` becomes a second console row nobody notices until a report
is wrong. An exact `result_count` of 4173 describes one business on one day, and a client search is a
surname or phone number by definition. Firebase drops a malformed event name silently: it never appears in
the console, found weeks into a reporting window.

## Decision
`sanitizeAnalyticsParams` drops (and in debug asserts on) any key absent from `AnalyticsParams.allParams`,
and passes only `num`, `bool` (1/0 — Firebase has no boolean parameter) and `String`. Every value comes
from a closed set in `analytics_events.dart` (`AnalyticsDirections`, `AnalyticsArchiveActions`,
`AnalyticsFilters` and `AnalyticsSettings` were the four added 2026-09-10); the employee-status value is
`UserStatus.active.name`, because that vocabulary already had an owner. Counts go through `bucketCount`,
queries only as `bucketQueryLength`. `analytics_events_test.dart` walks every name through
`AnalyticsNames`, which encodes the 40-char event cap and the shorter 24-char user-property cap.

## Consequences
Adding a parameter to the set first is the moment someone decides it is safe to transmit. A second copy of
a value vocabulary drifts from what the doc stores. A name valid as an event can be too long as a property.
