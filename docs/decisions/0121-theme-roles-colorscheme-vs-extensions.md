# 0121. Theme roles: `ColorScheme` only for Material's implicit consumers

**Date:** 2026-07-30 (redesign) · **Rules file:** `.claude/rules/frontend.md`

## Context
The redesign split several Material slots in two. `colorScheme.primary` became the saturated fill blue
(FilledButton, FAB, app bar) while `palette.primaryAccent` is the text/icon blue; `colorScheme.error` is the
lifted foreground red (input error text/borders) while `palette.dangerFill` is the destructive fill, so a
destructive filled button on `scheme.error` was unreadable in dark. The four `ThemeExtension`s (~40 fields
each plus `copyWith`/`lerp`) had made `design_tokens.dart` 965 lines, so they moved to
`core/theme/extensions/`; every `theme.palette`/`theme.statusColors` getter resolves through the token
file's re-export. `google_fonts` was removed for bundled families. `AppMonoType.light`/`.dark` cannot be
`const`: a const initializer cannot build a `TextStyle` from a constructor parameter, so the `extensions:`
lists in `themes.dart` are non-const. A mode toggle reading `themeMode == ThemeMode.dark` mis-read the
default `system` mode on a dark phone and needed two taps.

## Decision
A role goes on `ColorScheme` iff Material reads that slot implicitly; everything else on a
`ThemeExtension`, imported only via `design_tokens.dart`. Appearance never branches on brightness;
mode-selection UI resolves effective brightness through `isDarkMode`/`toggledThemeMode`.

## Consequences
Don't "restore" `const` on the mono type, import an extension file directly, or style a destructive fill
from `scheme.error`.
