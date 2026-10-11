# 0027. One `Debouncer`, `onError` required, built through `Debouncer.tagged`

**Date:** 2026-08-19 (`onError` required; `SettingsSaveDebouncer` deleted), 2026-08-22 (`Debouncer.tagged`), 2026-09-01 (`DebouncedPagedSearch`) · **Rules file:** `CLAUDE.md`

## Context
`Debouncer`'s `onError` was optional and five of the six call sites omitted it. The action runs from a
`Timer` callback, so a throw inside a debounced search had no caller left to catch it and the search
just returned nothing, with nothing logged and nothing in Crashlytics. Requiring it made `Debouncer` a
strict superset of `SettingsSaveDebouncer`, which was deleted: a second wrapper whose `onError` stayed
OPTIONAL voids exactly the guarantee the change buys. Its interval survives as `kSettingsSaveDebounce`
beside `settings_providers.dart`, a different cost dial from `kSearchDebounce`. Intervals had already
split 300 ms / 250 ms across four call sites.

Requiring `onError` could not close *where the logger is resolved*: the handler can fire after dispose,
and Riverpod 3 `ref.read` on an unmounted consumer throws (`.claude/rules/error-handling.md`). Prose
could not enforce reading it at construction; a required `AppLogger` parameter can, because an argument
is evaluated at the construction site — hence `Debouncer.tagged(duration, logger:, tag:)`. Five of six
sites carried a restatement of that rule as a comment, and the sixth, which deviated
(`address_autocomplete_field.dart`), shipped a FATAL. All sites use `tagged` now (six until
`DebouncedPagedSearch` merged two).

`DebouncedPagedSearch` (2026-09-01) replaced a block that was byte-identical in `ClientsListView` and
`AppointmentHistoryView`. `kAddressLookupDebounce` (700 ms) sits beside `kSearchDebounce` because every
address lookup is a BILLED Places call behind a per-uid rate limit, where a client search spends a
Firestore read the app already pays for. `kSearchDebounce` lives in `core/` rather than on
`ClientSearchPolicy` because its callers span features — the appointment sheets debounce a CLIENT
search, History an APPOINTMENT one.

## Decision
`Debouncer` is the only debounce wrapper; build it with `Debouncer.tagged` in `initState`; intervals
are named dials, compared in one place.

## Consequences
Don't add a second wrapper, a raw `Timer`, a lazy `late final` logger touching `ref`, or a re-spelled
interval at a call site.
