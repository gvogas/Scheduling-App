# 0130. Layout traps that shipped

**Date:** 2026-08-22 to 2026-09-14 · **Rules file:** `.claude/rules/frontend.md`

## Context
`alignment: Alignment.center` on a chip, meant to centre it in a `minHeight: 44` tap floor, made every
`EmployeePicker` chip take a whole `Wrap` row from 2026-08-22 to 2026-09-12. `LayoutBuilder` (inside
`auto_size_text`'s `AutoSizeText` too) throws during an intrinsic pass, and `AppointmentCard` needs
`IntrinsicHeight` to stretch its employee-colour bar; in release that surfaced as a paint-time
`Null check operator used on a null value` on the enclosing viewport. The live map's team sheet sat under a
conditional `EmptyMapCard` (2026-09-14): the re-slotted sheet's new `initState` attached the controller
before the old `dispose` detached it, so release disposed the NEW sheet's extent and every
`animateTo`/`jumpTo` silently no-oped. Two controllerless primary `ScrollView`s on one route make
`AppScrollBehavior`'s scrollbar throw "attached to more than one ScrollPosition" (the hub's tabs, the
calendar and master-detail splits). The hub's `IndexedStack` (`hub_shell.dart`) keeps every tab's FAB
mounted, so shared hero tags collide; the tags live in `main_calendar_screen.dart`, `clients_screen.dart`
and `employees_screen.dart`; `todayFab` (P2) and `liveMapRosterFab`/`liveMapRecenterFab`
(2026-09-13) are retired.

## Decision
No `alignment` for centring in a hug box; no `LayoutBuilder` under intrinsics; key a controlled
`DraggableScrollableSheet` slot; scope each concurrent scrollable; unique hub FAB tags.

## Consequences
The sheet is pinned in `live_map_screen_test.dart`. `AppointmentCard`'s title stays plain `Text`.
