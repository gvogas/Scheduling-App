# Navigation (lib/core/navigation/)

Loaded when working under `lib/core/navigation/`. Root context: `../../../CLAUDE.md`.

- **Navigation (`lib/core/navigation/`, restructured 2026-07-30):**
  `AppDestination` is a **sealed** family — `enum HubTab {calendar, clients,
  employees, liveMap}` (the four `IndexedStack` panes) and
  `enum PushedDestination {dayRoute, history, overdueReview, dashboard, settings}` (plain
  routes above the shell). `overdueReview` (2026-09-13) is admin-only,
  follows History in THE BUSINESS group and has no tour
  (`tour_definitions` returns `const []`), but its `.name` is still a storage
  key, so it is named once. The split makes `select(settings)` a **compile
  error** instead of an `IndexedStack` range crash; that is the whole point —
  never collapse it back to one enum plus a list or an `isHubTab` flag.
  `implements Enum` keeps `.name`/`.values` on the union type, and `.name` is
  load-bearing: it is the showcase scope name AND the key the FROZEN
  `kLegacyTourSteps` migration snapshot is written in (seen flags moved from
  per-scope `tour_seen_tabs` to per-STEP `tour_seen_steps` on 2026-09-04, and
  `tour_seen_tabs` is now read exactly once, by that migration), so
  **renaming a member silently replays or orphans a tour** (that is
  why the member stayed `employees` while its label became "Team" via
  `nav_team`). `navigateToDestination` is the one nav action; a hub tab reached
  from a pushed route goes through `selectAndReveal` (collapse, then switch) —
  the old `pushReplacementNamed` path left the wrong screen on top from a
  2-deep stack. `goHomeToCalendar` is the canonical go-home gesture behind the
  header's Calendar pill. **`_popToShell` targets the shell's captured
  `ModalRoute`, never `isFirst`** — on `_hubRoute`'s fallback branch the shell
  is not route #1, so `popUntil(isFirst)` pops the shell itself and strands the
  user. The **nav rail, `AdaptiveShell`, `AdaptiveDestination`,
  `Breakpoints.expanded` and `isExpanded` are all deleted**; `AppNavDrawer`
  (right-anchored, from `drawerGroups(isAdmin:)`) is the nav surface at every
  screen size, and `AppHeaderPair` sits in every `AppTopBar.actions` — on the
  **calendar only** it is built with `showCalendarPill: false` (a go-home pill
  on the screen it goes home to is dead weight; owner call 2026-07-31), so that
  header carries the day-route button and the hamburger alone.
- **An interface `core/` needs the shell to satisfy lives in
  `hub_shell_scope.dart`, never in the consumer's own file.** Two do:
  `HubTabSelector` (tab switching) and `AppointmentLinkHub` (the
  `isAdmin`/`employeeId`/`showCalendar`/`goHome` slice an inbound push or widget tap
  drives), and `HubShellState` implements both. Declaring one where its
  consumer lives instead forces `routes/hub_shell.dart` to import back into
  `core/app/`, and the mutual dependency gets papered over with a forwarding
  adapter — which is exactly what `AppointmentLinkHub` grew before it moved
  here (2026-08-19). `routes/` already imports this file; `core/` importing
  `routes/` one way is fine, both ways is not.
  `_hubRoute` + `HubTabRedirectRoute` survive at three tab routes — they look
  dead but remain the cold-start fallback. **Both branches are pinned, one test
  each:** `test/routes/hub_shell_test.dart` covers the REDIRECT branch (it
  mounts a live `HubShell` as `home:` before pushing, so `_hubRoute` always
  finds one), and `test/routes/hub_route_cold_start_test.dart` (I2, 2026-08-19)
  covers the FALLBACK branch — no live shell, so `_hubRoute`
  (`lib/routes/app_routes.dart`) must build a fresh `HubShell` with
  `initialTab` set to the tab that was asked for. Before that second file
  `initialTab` appeared nowhere under `test/`, so a push landing on the
  calendar instead of the requested tab (a push-notification tap, or a drawer
  entry taken before the shell exists) would not have failed anything.

