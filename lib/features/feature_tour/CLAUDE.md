# Feature tours (lib/features/feature_tour/)

Loaded when working here or on a screen hosting a tour (showcaseview 5.x). Root `CLAUDE.md` keeps the cross-cutting half: an `AppDestination` member name is both a tour storage key and navigation identity.

## Scopes and storage keys

- Key a tour on the sealed `TourScope` (`domain/tour_scope.dart`), never on `AppDestination`: `DestinationTour` wraps a screen, `FormTour` one of the `TourForm` sheets (`addAppointment`, `addClient`, `invitePerson`, `jobDetails`) — the only way a sheet walkthrough is expressible. (ADR-0178)
- Keep `TourScope.storageKey` a destination's bare `.name` and a form's `sheet_*` (`sheet_addAppointment`, `sheet_addClient`, `sheet_invitePerson`, `sheet_jobDetails`, namespaced so they cannot collide). It is both the showcase scope name and the key of the frozen `kLegacyTourSteps` snapshot, so a prefix replays every tour on every installed device. Never rename a `HubTab`, `PushedDestination` or `TourForm` member — it replays or orphans that tour. (ADR-0178)
- Give each scope its OWN showcaseview scope (`TourScope.storageKey`) — the hub `IndexedStack` keeps every tab mounted, so a shared scope mixes hidden tabs' targets into the visible tour. `FeatureTourHost` (`widgets/feature_tour_host.dart`) is the only start path.
- Register the scope in `initState` and deliberately NEVER unregister it: `register()` replaces, and an unregister in `dispose` would race the replacement State's `initState` on a hub identity change.
- Gate every dismiss and mark-seen on `_tourRunning` — the package fires `onDismiss` even when idle.

## Visibility gate

- Pick the gate from the scope's sealed type, never from a null `HubShellScope` — that also describes a hub screen hosted standalone in a test, where "never start" must hold. A `HubTab` needs `HubShellScope.currentOf` AND its hosting route current (a page pushed over the hub hides the tab without switching it); a `PushedDestination` and a `FormTour` share one `ModalRoute.of(context)?.isCurrent` branch, because a `ModalBottomSheetRoute` IS a `ModalRoute`. (ADR-0178)
- Call `markFormToursSeen()` (`test/support/tour_test_support.dart`) in any widget test that pumps `AddEventSheet`, `AddClientSheet`, `InvitePersonSheet` or the job-details sheet: its route is current the instant it is pumped, so on a fresh preferences store the tour starts and showcaseview's repeating tooltip animation times out `pumpAndSettle`; it derives its set from both roles' live catalogs, so a new sheet step can't hang a suite. Hub tabs are immune (no `HubShellScope` standalone); `markAllToursSeen()` covers a toured pushed screen.

## Starting a tour

- Await `tourSeenProvider.ready` before acting — the optimistic empty default would replay seen tours on a cold start. (ADR-0179)
- Await `_routeTransitionSettled()` (the route's animation AND its `secondaryAnimation`) so showcase measures a page that has finished sliding in, and a hub tour never opens over a page still sliding away. Re-check visibility and `ready` in the post-frame start — `ready` can drop between scheduling and starting (the calendar's `holdsTour`). (ADR-0180)
- Find survivors with `isTargetRendered`, never `GlobalKey.currentContext` — the 5.x `Showcase` does not forward its key to the element tree, so `currentContext` is always null. Zero survivors: mark NOTHING and return, never crash or retry, and leave `_started` set — resetting it re-arms `_start` on every rebuild. (ADR-0180)
- Reset `_started` on that post-frame early return (switched away or not ready): the auto-start sets it before its callback runs, and a stale `true` suppresses the tab's tour for the session after a fast tab switch. (ADR-0180)
- Pass `FeatureTourHost(ready:)` false while the body shows a loading or error placeholder, in any scope holding even ONE data-dependent target — an ungated start drops those steps or opens a tour on a skeleton. Calendar gates on `!data.isLoading && !holdsTour`, LiveMap on `_mapTargetsRendered` (its targets live in the map stack), Dashboard and Day route on `AsyncData`, Team on `allUsersStreamProvider.hasValue`. (ADR-0180)
- Gate a paginated host, which has no `AsyncValue`, on its list's `onFirstPageSettled`: `ClientsListView` and `AppointmentHistoryView` fire it post-frame after the first page resolves, success OR failure, since either way the skeleton is gone and no further row arrives on its own. Wire any new paginated host the same way. (ADR-0180)
- Force below-fold targets to mount with `autoScroll: true` AND an inflated `scrollCacheExtent` — `isTargetRendered` can't find a target a lazy list never built, and drops that step silently. The three create sheets pass `kTourScrollCacheExtent` (3000 px); Settings inflates its master list to 4000 px. The job-details sheet and Dashboard pass `autoScroll: true` only.

## Steps and wrapping

- Keep step catalogs pure (`tourStepsFor`, `domain/tour_definitions.dart`). Clients, Employees, LiveMap, Dashboard and the three create sheets are admin-only, so their employee catalogs are empty and their screens guard wraps on catalog membership.
- Wrap targets with `TourSteps.stepIf`, never `has(id) ? step(id, ...) : child` — `step` force-unwraps `keys[id]!`, so an unguarded wrap crashes on an empty employee catalog.
- Wrap only the FIRST row of a list-row step (its `GlobalKey` must stay unique), injected as a wrap callback so the widget stays reusable untoured — `ClientsListView` is also the booking flow's client picker.
- Give a widget hosting more than one step ONE `Widget Function(TourStepId, Widget)? tourWrap`, never a parameter per step, wired as `tourWrap: _tour.stepIf` (a tear-off of the `TourSteps` method) — a new step then costs a call at the target, not a parameter threaded through two or three widgets and their tests. (ADR-0181)
- Re-read a step's description whenever a toured surface changes shape, and add a step for every new control — nothing catches stale copy or an untoured control mechanically. Keep the count assertions in `tour_definitions_test.dart`: they make growing a catalog a deliberate edit, not a silent one. (ADR-0182)
- Give an employee tour to each destination `drawerGroups(isAdmin: false)` offers (Calendar, Day route, Settings). History's employee catalog is still non-empty but unreachable, since `/history` is admin-only. `tour_definitions_test.dart` pins the set through a hand-written `employeeToured`, not derived from `drawerGroups`, so change the catalog and that set together. (ADR-0183)

## Seen flags

- Store seen flags per STEP, device-local in SharedPreferences ONLY (`tour_seen_steps`) — a release that adds a step to an already-toured screen must be able to show just that step. Sign-out does not reset them; the Settings "Replay app tour" row (`resetAll`) is the only reset. (ADR-0179)
- Record through `markSteps` only the ids that actually RAN: a step dropped because its target hadn't rendered stays unseen and is offered by a later host State (cold start or re-push) — not by switching hub tabs, whose State stays mounted. (ADR-0179)
- Never add a step id to the FROZEN `kLegacyTourSteps` (`domain/legacy_tour_steps.dart`) — every id in it is marked seen on upgrade, so a new one there is a step no existing device ever sees. (ADR-0179)
- Read `tour_seen_tabs` only in the one-time migration in `TourSeenController._load`. ABSENCE of `tour_seen_steps` is its marker, so `resetAll` writes an EMPTY list (which can't re-trigger it) and deliberately leaves `tour_seen_tabs` alone. (ADR-0179)
