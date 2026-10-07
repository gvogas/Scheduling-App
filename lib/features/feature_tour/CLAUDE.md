# Feature tours (lib/features/feature_tour/)

Tour rules moved out of the root `CLAUDE.md` on 2026-08-14 — this block is
self-contained Flutter UI with no `functions/` hand-mirror, so it only
needs to load when working here or on a screen that hosts a tour.

Note the cross-cutting half that stays in the root file: `AppDestination`
member names are load-bearing BOTH as tour storage keys and as navigation
identity, so a rename replays or orphans a tour.

- **Feature tours (`lib/features/feature_tour/`, showcaseview 5.x):** each
  scope registers its OWN showcaseview scope (`TourScope.storageKey`) — the hub
  IndexedStack keeps every tab mounted, so a shared scope would mix hidden
  tabs' targets into the visible tour. `FeatureTourHost` is the only start
  path.
  **A tour is keyed on the sealed `TourScope`, not on `AppDestination`**
  (`domain/tour_scope.dart`, 2026-08-04): `DestinationTour` wraps a screen,
  `FormTour` wraps one of the sheets that carries a walkthrough
  (`addAppointment`, `addClient`, `invitePerson`, `jobDetails` — storage keys
  `sheet_addAppointment`, `sheet_addClient`, `sheet_invitePerson`,
  `sheet_jobDetails`) — which is the only reason a walkthrough of
  "how do I create an appointment" is expressible at all. **`storageKey` is
  BOTH the showcase scope name and the key the FROZEN `kLegacyTourSteps`
  migration snapshot is written in, and a destination's key is its bare
  `.name`** — do not prefix it, or every installed device replays every tour it
  has already seen. (The live seen flags are per STEP in `tour_seen_steps` as
  of 2026-09-04; `tour_seen_tabs` survives only as that migration's input —
  see the per-step bullet below.) Form keys are
  namespaced `sheet_*` so they cannot collide. `.name` stays load-bearing:
  renaming a `HubTab`, `PushedDestination` or `TourForm` member replays or
  orphans that tour.
  **Its visibility gate is chosen by the scope's sealed type, not
  by a null `HubShellScope`**: a `HubTab` gates on `HubShellScope.currentOf`
  AND on its hosting route being current (2026-09-15: a page pushed over the hub hides the tab without
  switching it, and the calendar tour started underneath the team-map page);
  a `PushedDestination` **and a `FormTour`** both gate on
  `ModalRoute.of(context)?.isCurrent` — one branch, because a
  `ModalBottomSheetRoute` IS a `ModalRoute`. A null scope is
  ambiguous — it also describes a hub screen hosted standalone in a test, where
  "never start" must be preserved. Before this split, Settings and History
  (now pushed routes) would have had `currentOf == null` and their tours would
  have silently never started.
  **A widget test that pumps `AddEventSheet`, `AddClientSheet`,
  `InvitePersonSheet` or the job-details sheet MUST call
  `markFormToursSeen()`**
  (`test/support/tour_test_support.dart`). A sheet's route is current the
  instant the test pumps it, so on a fresh-install preferences store the tour
  starts and showcaseview's repeating tooltip animation makes `pumpAndSettle`
  time out. Hub tabs are immune (no `HubShellScope` when hosted standalone).
  **A scrolling tour host passes `autoScroll: true` AND
  `kTourScrollCacheExtent`** — `isTargetRendered` cannot find a target a lazy
  list never built, and it drops that step silently rather than failing.
  **Wrap targets with `TourSteps.stepIf`, not `has(id) ? step(id, ...) : child`**
  — `step` force-unwraps `keys[id]!`, so an unguarded wrap crashes on a screen
  whose employee catalog is empty. A list-row step wraps the FIRST row only
  (the `GlobalKey` must stay unique), injected as a wrap callback so the widget
  stays reusable untoured — `ClientsListView` is also the booking flow's client
  picker.
  **A widget that hosts more than one step takes ONE
  `Widget Function(TourStepId, Widget)? tourWrap`, never a parameter per step.**
  `AppointmentFormFields` had the shape first; `DetailsViewBody`,
  `DetailsActionBar` and `NotificationsSettingsCard` grew twelve
  `wrap<StepName>` parameters and two copies of the same `?? child` helper
  between them before converging on it (2026-09-05). Wire it as
  `tourWrap: _tour.stepIf` — a tear-off of the `TourSteps` method, so a new
  step on that surface costs a call at the target, not a parameter threaded
  through two or three widgets and their tests.
  Every mode awaits `_routeTransitionSettled()` so showcase measures a
  page that has finished sliding in — including the host route's
  `secondaryAnimation`, so a hub tour never opens over a page still sliding
  away — and the post-frame start re-checks `ready`, which can drop between
  scheduling and starting (the calendar's `holdsTour`). It
  awaits `tourSeenProvider.ready` before acting (the optimistic empty default
  would replay seen tours on cold start), and drops steps whose target isn't
  rendered via `isTargetRendered` — **never `GlobalKey.currentContext`: the
  5.x `Showcase` widget does NOT forward its key to the element tree, so
  currentContext is always null** (zero survivors → mark NOTHING and return,
  never crash/retry). The auto-start sets a `_started` guard before its post-frame
  callback runs; **reset `_started` on the visibility-changed early-return** (the
  tab was switched away before the callback fired) — a stale `true` there
  permanently suppresses that tab's tour for the session, so a fast tab-switch
  during auto-start otherwise wedges it shut. **Data-dependent tabs MUST pass `FeatureTourHost(ready:)` false
  while their body shows a loading/error placeholder** — the tour's targets
  don't exist yet, so an ungated start finds zero survivors and permanently
  shows nobody anything against an empty body (bit LiveMap: its targets — the
  team sheet's header and the recenter tile since 2026-09-13, FABs before —
  live in the map stack, absent during the presence-data load). **A PARTIAL
  start is the same bug and is easier to miss**, though since 2026-09-04 it is
  no longer PERMANENT: only the steps that actually ran are marked, so the
  dropped ones are offered on a later visit. The gate still matters — it stops
  a tour opening on a skeleton in the first place. Any scope holding even ONE
  data-dependent target needs it, not just one whose body is entirely a
  placeholder. Calendar gates on
  `!isLoading`; LiveMap gates on `_mapTargetsRendered` (the map stack, not the
  placeholder, is showing); Dashboard and Day route gate on `AsyncData`; Team
  gates on `allUsersStreamProvider.hasValue`. **Clients and History are
  paginated, so they have no `AsyncValue` to read** — `ClientsListView` and
  `AppointmentHistoryView` each expose `onFirstPageSettled`, fired post-frame
  after the first page resolves (success OR failure — either way the skeleton
  is gone and no further row arrives on its own), and the screen gates `ready`
  on it. Wire any new paginated tour host the same way rather than starting
  against the skeleton.
  Settings and the three form sheets instead FORCE their below-fold targets to
  mount via `autoScroll: true` + an inflated `scrollCacheExtent` — a lazy list
  won't build off-screen rows for `isTargetRendered` to find. Scopes are
  registered in initState and deliberately NEVER
  unregistered (register() replaces; unregister in dispose would race the
  replacement State's initState on a hub identity change), and every
  dismiss/mark-seen is gated by `_tourRunning` because the package fires
  onDismiss even when idle. Step catalogs are pure (`tourStepsFor`);
  Clients/Employees/LiveMap/Dashboard and all three form sheets are
  admin-only, so their employee catalogs are empty and their screens guard
  wraps on catalog membership. **Calendar, Day route, History and Settings are
  the four destinations an employee can reach, and each has an employee tour**
  — keep that set matching `drawerGroups(isAdmin: false)`. History joined on
  2026-09-01, when a technician got a History scoped to their own jobs; its
  three targets (search, filter, row) render for that role, so its catalog is
  NOT admin-gated and `tour_definitions_test.dart` pins the set against the
  drawer.
  **A tour step's COPY is part of the surface it points at, so moving a control
  means re-reading its description** (2026-09-05). Two had gone stale and
  neither failed anything: `apptDetails` still listed "Address" after the job
  address moved into the WHO section, and `historyFilter` said "date range"
  where the filter has only ever offered a YEAR. Nothing can catch this
  mechanically — the step still has a target and the string still resolves —
  so audit the descriptions whenever a toured surface changes shape, not only
  when a step is added or removed.
  **A control shipped untoured is the other half of that audit.** 1.57 added
  the clients SORT and 1.58 the job-address block, and both rendered with no
  step at all; they are `clientsSort` and `apptJobAddress` now. Adding an id is
  safe by construction — it is absent from `kLegacyTourSteps`, so every
  installed device is offered it — which is exactly why the count assertions in
  `tour_definitions_test.dart` are worth keeping: they make growing a catalog a
  deliberate edit rather than a silent one.
  Seen flags are device-local SharedPreferences ONLY (`tour_seen_steps`);
  sign-out does not reset them — the Settings "Replay app tour" row is the
  only reset.
  **Seen flags are per STEP, not per scope** (`tour_seen_steps`, 2026-09-04).
  A release that adds a step to a screen someone already toured has to be able
  to show them that one step; the per-scope flag could not.
  `tour_seen_tabs` is now read exactly once, by the migration in
  `TourSeenController._load`, through the FROZEN `kLegacyTourSteps` snapshot in
  `domain/legacy_tour_steps.dart`. **Never add a new step id to that
  snapshot** — every id in it is marked seen on upgrade, so a new one there is
  a step no existing device will ever see. ABSENCE of `tour_seen_steps` is the
  migration marker, so `resetAll` writing an EMPTY list can't re-trigger it
  (and it deliberately leaves `tour_seen_tabs` alone).
  `markSteps` records only the ids that actually RAN, which retires the
  partial-start bug: a step dropped because its target hadn't rendered stays
  unseen and is offered on a later visit, and zero rendered targets marks
  NOTHING at all. `markFormToursSeen()` derives its set from the live
  catalogs, so a new sheet step can't leave a suite hanging on
  `pumpAndSettle`.
