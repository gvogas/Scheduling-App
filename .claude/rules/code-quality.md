---
alwaysApply: true
---

# Code Quality

## Anti-defaults (counter common Claude tendencies)

- No premature abstractions. Three similar lines beats a helper used once.
- Don't add features beyond what was asked.
- No dead code or commented-out blocks. Git has history.
- Comments: one line max, only where intent isn't obvious from the code.
  **This is enforced, not aspirational** (owner call, 2026-09-03). The rationale
  comments in `firestore.rules` were deleted deliberately and the same trim was
  applied across the codebase; a comment block explaining WHY a guard has its
  shape belongs in these rules files as the invariant plus at most ONE inline
  clause of reason (kept wherever the obvious "fix" is wrong), because that is
  what a new session reads. Dates, incidents and longer rationale go in an ADR
  under `docs/decisions/`, cited from the rule as `(ADR-NNNN)` (owner call,
  2026-10-07). Don't restore a deleted block, and don't file its absence as a
  finding — check whether the fact is recorded in the rules or an ADR first,
  and add it if it is not.
- **Two exceptions, both mechanical.** Analyzer and linter directives
  (`// ignore:`, `// ignore_for_file:`, `// eslint-disable*`, `@pragma`) are
  code, not commentary. And `functions/` runs eslint's `require-jsdoc` +
  `valid-jsdoc`, so every function there MUST carry a JSDoc block with a
  `@param` per parameter and a `@return`: keep the skeleton and a one-line
  description, and trim only the prose.

## Naming (Dart conventions)

- Files: `snake_case` (`user_profile.dart`, `app_routes.dart`, `auth_service.dart`).
- Classes/enums/extensions: `UpperCamelCase`.
- Methods, variables, parameters: `lowerCamelCase`.
- Private members: leading underscore (`_controller`, `_initStreams`).
- Constants: `lowerCamelCase` for `const` values; `SCREAMING_SNAKE` only for top-level legacy constants.
- Booleans: `is` / `has` / `should` / `can` prefix. Functions: verb-first (`getUser`).
- Abbreviations only when universally known (`id`, `uid`, `api`, `auth`).

## Code Markers

`TODO(author): desc (#issue)` for planned work — the `(#issue)` suffix is
optional here, because this repo has no issue tracker; where a marker's work is
owned by a rule or plan doc, cite that doc instead of inventing a number. `FIXME(author): desc (#issue)` for known bugs. `HACK(author): desc (#issue)` for workarounds (explain the proper fix). `NOTE: desc` for non-obvious context. Never `XXX`, `TEMP`, `REMOVEME`.

## File Organization

- Imports: `dart:` SDK imports first, then `package:` imports, then relative imports. Blank line between groups.
- Save `.dart` files as UTF-8 **without a BOM**. An editor that writes "UTF-8 with BOM" prepends `EF BB BF` to line 1; Dart still compiles, but it pollutes every diff and spreads on each re-save (scan with `head -c 3 file | od -An -tx1`; strip with `tail -c +4`). This has bitten the repo before.
- One class or widget per file.
- Public API first, then private helpers in call order.
- Keep `build()` methods under ~60 lines. Extract sub-widgets or builder methods when larger.
