# 0070. The deep-link dispatcher skips `homeWidget`; the route observer tracks Route identity

**Date:** 2026-08-02 (P4c reduced the dispatcher), 2026-08-19 (B4, `didRemove`) · **Rules file:** `.claude/rules/employees.md`, `lib/core/navigation/CLAUDE.md`

## Context
The `app_links` dispatcher is the single consumer of incoming URLs, but once it listens, both it and
`home_widget` observe the same `openURL`, so every widget, Live Activity and Siri tap opened the appointment
sheet twice. `FlutterDeepLinkingEnabled` is false because that is the correct setting for `app_links` (Flutter's
handler would consume the URL first). `TopRouteObserver` stayed registered on `MaterialApp.navigatorObservers`
after the invite branch went. Without a `didRemove` override it stayed stuck on a route that no longer existed,
because `hub_shell.dart` calls `nav.removeRoute(this)` on its `HubTabRedirectRoute` shim while that shim is the
top route (post-frame, after handing off). A name-based guard was wrong too: `pushNamedAndRemoveUntil` (the
account-disabled path) pushes before it removes, so a removed older route sharing the new route's name (two
`/login` entries) overwrote the top with whatever sat beneath it.

## Decision
`classifyDeepLink` returns `IgnoredLink` for any URI carrying `homeWidget`. `didRemove` reacts only when the
removed route is `identical` to the tracked top `Route`; `currentRouteName` is derived from that object. Pinned by
`test/core/navigation/top_route_observer_test.dart` ("removing the current top route falls back to the route
beneath", "removing a lower route does not overwrite the current top route", "pushNamedAndRemoveUntil keeps the
just-pushed name even when a removed route shares it").

## Consequences
The `homeWidget` param and the `home_widget` tap channel retire together, later (`ios/CLAUDE.md`); dropping
either alone re-breaks widget taps.
