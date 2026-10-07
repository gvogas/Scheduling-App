# 0033. Resolve the logger and every post-await provider before the first await

**Date:** by 2026-08-14 (rule first committed); `composeErrorNoticeFor` 2026-09-05 · **Rules file:** `.claude/rules/error-handling.md`

## Context
Two rules fought each other: log BEFORE any `if (!mounted) return;` so the log survives unmount, and
read the logger from `ref`. Under Riverpod 3 `ref.read` on an unmounted consumer throws a `StateError`
(`flutter_riverpod/lib/src/core/consumer.dart`, `_assertNotDisposed` — an unconditional throw, not a
debug assert, guarding `read`/`watch`/`listen`/`invalidate`/`refresh`). So
`ref.read(loggerProvider).warn(...)` above a mounted guard threw exactly in the case the guard exists
for. In `address_autocomplete_field.dart` that escaped a `Debouncer` timer callback into the zone
handler as a FATAL, every time an address lookup failed after its sheet was dismissed.

`context` has the same problem: `composeErrorNotice` takes a `BuildContext` only to reach
`context.l10n`, and a notice ACTION runs after its surface may be gone — the mark-complete Undo fires
from a timer callback with the sheet already popped. `composeErrorNoticeFor(l10n, ...)` takes the
`AppLocalizations` instead, a plain object with no element behind it.

## Decision
`final logger = ref.read(loggerProvider);` (and `noticeServiceProvider`, a repository, the `l10n`) is
read before the first `await`; nothing touches `ref` or `context` after it. A `ref.read` inside a
braced `catch` body or after the `{` of a `.catchError(` callback fails CI (`tool/check_rules.dart`,
`ref-read-in-catch`); the before-first-await half, and an arrow `.catchError((e) => ref.read(...))`,
are not checked.

## Consequences
If it regresses, a failure after the surface is dismissed throws a `StateError` from inside the
`catch`, which replaces the real error and reaches the zone handler as a FATAL from a sheet that
merely failed (the address-lookup crash).
