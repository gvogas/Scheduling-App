# 0125. One platform-adaptivity seam; capability gates are injected

**Date:** 2026-08-22 (`defaultIsIosPlatform` dedupe), P2 (series-scope exception) · **Rules file:** `.claude/rules/frontend.md`

## Context
`context.isCupertino` reads `Theme.of(context).platform`, so tests force the look with
`ThemeData(platform:)`; scattered `Platform.isIOS`/`defaultTargetPlatform` cannot be forced. `flutter test`
runs on the host, where a bare `Platform.isIOS` returns early and leaves everything after it untestable on
the only platform that ships, hence the injected `defaultIsIosPlatform`. It lives in `core/` because two
callers import each other; `widget_sync_service.dart` carried a private copy until 2026-08-22.
The shared adaptive widgets leave Android unchanged: `showAdaptiveActionSheet` is a `CupertinoActionSheet`
on iOS, and `AppScrollBehavior` (on `MaterialApp.scrollBehavior`) gives vertical scrollables a `CupertinoScrollbar` instead of the Material
`Scrollbar`. `showSeriesScopeDialog` puts a consequence line ("12 remaining visits through 26 Jan") under each option,
which an action sheet cannot render. The `.adaptive` constructors in use: `Switch.adaptive`/
`SwitchListTile.adaptive` (with `activeTrackColor: scheme.primary`) and `RefreshIndicator.adaptive`.

## Decision
Branch look on `context.isCupertino`; gate real logic on an injected `defaultIsIosPlatform`; the series
scope dialog is the single Cupertino exception.

## Consequences
Don't re-declare a private iOS check, or cite the dialog to drop other Cupertino branches.
