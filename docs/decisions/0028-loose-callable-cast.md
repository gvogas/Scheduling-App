# 0028. Callable responses are cast loosely

**Date:** 2026-08-05 (kept after Android went), 2026-10-07 (enforced by `tool/check_rules.dart`) · **Rules file:** `CLAUDE.md`

## Context
`as Map<String, dynamic>?` on a callable response started as an Android-only `TypeError`: that plugin
returned nested objects as `Map<dynamic, dynamic>`. With Android gone (ADR-0011) it can no longer bite.

## Decision
Cast with `(value as Map?)?.cast<String, dynamic>()` anyway: it costs the same and doesn't depend on a
plugin's choice of map type. `tool/check_rules.dart` (strict-map-cast) fails CI on the strict form.

## Consequences
Don't "simplify" back to the strict cast because Android is gone.
