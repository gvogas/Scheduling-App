# 0133. `DateFormat` is memoized per locale, in two owners

**Date:** 2026-08-02 · **Rules file:** `.claude/rules/frontend.md`

## Context
Constructing a `DateFormat` verifies the locale and parses a skeleton; the calendar built one per day cell
for a semantics label, 30–90 per rebuild on every day tap and month swipe.

## Decision
`month_grid.dart`'s cache keys on a passed `Localizations.localeOf` (context-bound UI); `DateUtilsHelper`
(`date_utils_helper.dart`) keys on `Intl.defaultLocale` for context-free code.

## Consequences
Don't merge them; the locale sources differ on purpose.
