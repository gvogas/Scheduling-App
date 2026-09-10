# Crew Record & Role Gates Implementation Plan

> **Provenance:** this file was reconstructed on 2026-09-07 from the executing
> session's own reads, after an agent cleanup deleted the untracked original
> mid-run. It is committed this time. Tasks 1-4 were executed from the original;
> Tasks 5-13 from this text.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: SHIPPED AND DEPLOYED — ARCHIVED 2026-09-09.** All thirteen tasks
were executed 2026-09-06/07 (commits `b3ca82a2` through `051a6b6d`), and the
Task 9 rules half went live 2026-09-07 at `462a1907` — see `docs/DEPLOYMENT.md`.
**Unticked boxes below are not outstanding work**: this plan was executed
without ticking, and each task's artifacts are present in the tree. Current
behaviour is `CLAUDE.md` and `.claude/rules/appointments.md`, never this file.

**Goal:** Ship the eight agreed changes to the appointment flow, the employee interface and the crew field record — culminating in author-stamped crew notes an admin can read.

**Architecture:** Four independent UI edits (Recent removal, job-address visibility, filter back button, photo refresh), one new shared role gate used by two surfaces (Day Route, History), one new Firestore subcollection with rules + store + provider + UI (crew notes), and one render change to the client picker.

**Tech Stack:** Flutter 3.10.7 / Dart, Riverpod 3, Freezed 4 (build_runner), Firestore + `firestore.rules`, `gen_l10n`.

**Design spec:** `docs/plans/2026-09-06-crew-record-and-role-gates.md`
**Mockup:** https://claude.ai/code/artifact/b12a97dd-0058-4d1c-be3c-3e766b0626d3

---

## Conventions for every task

**Analyzer baseline is `No issues found!`** — any lint you see is yours. Run `flutter analyze` before every commit.

**ARB edits regenerate themselves.** A hook (`.claude/hooks/gen-l10n.sh`) runs `flutter gen-l10n` whenever an ARB changes. Do NOT run it by hand. Both ARBs must be edited in lockstep; only `app_en.arb` carries the `@key` metadata block, and `flutter gen-l10n` fails on a bare key there.

**Commit form.** Use `git commit -F-` with a heredoc — PowerShell mangles double quotes in `-m` messages, and the Bash tool is available:

```bash
git commit -F- <<'EOF'
feat(scope): subject

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

**Staging.** Stage the files a task touches by explicit path. Never `git add -A`, and **never run `git clean`** — that is what destroyed the untracked original of this file.

**Explicit non-goal.** The repository-layer `employeeId` parameter on `fetchHistoryPage` / `searchHistory` / `_historyQuery` / `HistoryPager.fetchPage` **stays**, along with the `_historyWindows` per-scope machinery. It mirrors `functions/indexed_search.js`'s `historyScope`, which is deployed and still called by shipped builds. Task 3 removes only the widget-level `scopeEmployeeId`. Do not widen Task 3 into a repository refactor.

---

## Task 1: The live admin gate

The shared foundation for Tasks 2 and 3. Route arguments carry `isAdmin` as a push-time snapshot; this reads the role from Firestore instead, and fails **closed** while the doc is unsettled.

**Files:**
- Create: `lib/features/auth/application/is_active_admin_provider.dart`
- Test: `test/features/auth/application/is_active_admin_provider_test.dart`

- [x] **Step 1: Write the failing test**

Create `test/features/auth/application/is_active_admin_provider_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';

void main() {
  ProviderContainer containerFor(Stream<Map<String, dynamic>> doc) {
    final container = ProviderContainer(
      overrides: [currentUserDocProvider.overrideWith((_) => doc)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<bool> resolve(Map<String, dynamic> doc) async {
    final container = containerFor(Stream.value(doc));
    await container.read(currentUserDocProvider.future);
    return container.read(isActiveAdminProvider);
  }

  test('an active admin resolves true', () async {
    expect(await resolve({'role': 'admin', 'status': 'active'}), isTrue);
  });

  test('a disabled admin resolves false', () async {
    expect(await resolve({'role': 'admin', 'status': 'disabled'}), isFalse);
  });

  test('an active employee resolves false', () async {
    expect(await resolve({'role': 'employee', 'status': 'active'}), isFalse);
  });

  test('an empty doc resolves false', () async {
    expect(await resolve(const {}), isFalse);
  });

  test('surrounding whitespace does not defeat the match', () async {
    expect(await resolve({'role': ' admin ', 'status': ' active '}), isTrue);
  });

  test('an UNSETTLED doc fails CLOSED', () {
    // The whole point: "we do not know yet" must never read as "admin".
    final container = containerFor(const Stream.empty());
    expect(container.read(isActiveAdminProvider), isFalse);
  });
}
```

> **As executed:** Riverpod 3 auto-disposes a provider nothing listens to, and
> `Stream.value` emits on a microtask, so `containerFor` needs a
> `container.listen(currentUserDocProvider, (_, _) {})` — the same workaround
> `active_user_identity_provider_test.dart`, `role_upgrade_listener_test.dart`
> and `all_users_stream_provider_test.dart` already carry, and which
> `.claude/rules/testing.md` documents. `resolve`'s final synchronous read also
> needs the `Future.value(...)` wrap that `account_status_provider_test.dart`'s
> `firstNameValue` uses, or `async_return_with_no_await` fires.

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/auth/application/is_active_admin_provider_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../is_active_admin_provider.dart'`

- [x] **Step 3: Write the provider**

Create `lib/features/auth/application/is_active_admin_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/features/auth/application/account_status_provider.dart';

/// True only while the LIVE Firestore user doc says this session is an active
/// admin.
///
/// Every admin-gated surface reached by a PUSHED route takes its `isAdmin` from
/// a route argument, which is a snapshot: a stale back stack, an argless push
/// or a deep link can all carry one that no longer describes the signed-in
/// person. This is the same question asked of Firestore, which is the standing
/// rule for anything that gates access.
///
/// Fails CLOSED while the doc is unsettled, matching the least-privilege
/// default every appointment surface already takes. There is no loading window
/// in practice: `currentUserDocProvider` is a non-autoDispose stream the app
/// shell already holds open, so a pushed screen reads a settled value on its
/// first build.
final isActiveAdminProvider = Provider<bool>((ref) {
  final doc = ref.watch(currentUserDocProvider).value;
  if (doc == null) return false;
  return (doc['role'] ?? '').toString().trim() == 'admin' &&
      (doc['status'] ?? '').toString().trim() == 'active';
});
```

- [x] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/auth/application/is_active_admin_provider_test.dart`
Expected: PASS — 6 tests.

- [x] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/auth/application/is_active_admin_provider.dart test/features/auth/application/is_active_admin_provider_test.dart
git commit -F- <<'EOF'
feat(auth): add isActiveAdminProvider, the live-Firestore admin gate

Route arguments carry isAdmin as a push-time snapshot. Admin-gated pushed
surfaces need the role re-read from Firestore, failing closed while unsettled.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

Shipped as `b3ca82a2`.

---

## Task 2: Day Route crew selector honours the live role

**Files:**
- Modify: `lib/features/calendar/screens/day_route_screen.dart`
- Test: `test/features/calendar/screens/day_route_screen_test.dart`

**Scope note.** Gate the three things that decide access: the crew picker, the appointment stream, and `showEventDetails(showActions:)` (all flow from `buildDayRoute`'s `isAdmin`). Leave `_tour` and `FeatureTourHost` on `widget.isAdmin` — `TourSteps` owns GlobalKeys that must stay stable across rebuilds, so it cannot be rebuilt from a watched provider, and the one admin-only step is a `stepIf` on a widget that no longer renders.

- [x] **Step 1: Write the failing test**

Append to `test/features/calendar/screens/day_route_screen_test.dart` — first add the imports at the top of the file:

```dart
import 'package:scheduling/features/auth/application/account_status_provider.dart';
```

Then add a harness and test at the end of `main()`:

```dart
  Widget wrapWithRole({
    required List<AppointmentRecord> jobs,
    required Map<String, dynamic> userDoc,
  }) => ProviderScope(
    overrides: [
      currentUserDocProvider.overrideWith((_) => Stream.value(userDoc)),
      myAppointmentsProvider.overrideWith((_, _) => Stream.value(jobs)),
      appointmentsInRangeProvider.overrideWith((_, _) => Stream.value(jobs)),
      employeeColorMapProvider.overrideWithValue({_jane.id: _jane.color}),
      employeeNameMapProvider.overrideWithValue({'e1': 'Jane Doe', 'e2': 'Bob'}),
    ],
    child: ThemeNotifier(
      themeMode: ThemeMode.light,
      toggleTheme: () {},
      textScale: 1,
      setTextScale: (_) {},
      setLanguage: (_) {},
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lightTheme(),
        // The forged argument: this caller claims admin.
        home: const DayRouteScreen(isAdmin: true, employeeId: 'e1'),
      ),
    ),
  );

  testWidgets('a non-admin gets NO crew picker even with isAdmin: true',
      (tester) async {
    await tester.pumpWidget(
      wrapWithRole(
        jobs: [
          _job(
            id: 1,
            hour: 9,
            status: 'pending',
            employeeIds: const ['e1', 'e2'],
            employeeNames: const ['Jane Doe', 'Bob'],
          ),
        ],
        userDoc: const {'role': 'employee', 'status': 'active'},
      ),
    );
    await tester.pumpAndSettle();
    // The picker's own label. Two assignees means the admin build WOULD
    // render it, so its absence is the gate and not an empty-data accident.
    expect(find.text('Jane Doe'), findsNothing);
  });

  testWidgets('a real admin still gets the crew picker', (tester) async {
    await tester.pumpWidget(
      wrapWithRole(
        jobs: [
          _job(
            id: 1,
            hour: 9,
            status: 'pending',
            employeeIds: const ['e1', 'e2'],
            employeeNames: const ['Jane Doe', 'Bob'],
          ),
        ],
        userDoc: const {'role': 'admin', 'status': 'active'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Jane Doe'), findsWidgets);
  });
```

> **As executed:** the pre-existing `_adminScreen` helper passes `isAdmin: true`
> but overrode no `currentUserDocProvider`, so the new live gate silently
> flipped `'admin picker lists only employees with a job that day'` to a
> non-admin scenario. It needs an admin/active override, plus a
> `myAppointmentsProvider` override to cover the one pre-settle frame. Expect
> this class of breakage wherever a test hand-passes `isAdmin: true`.

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/calendar/screens/day_route_screen_test.dart`
Expected: FAIL on "a non-admin gets NO crew picker" — the picker renders because `widget.isAdmin` is true.

- [x] **Step 3: Resolve the role once and thread it**

In `lib/features/calendar/screens/day_route_screen.dart`, add the import:

```dart
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
```

Replace the body of `build` (the method that currently opens `// Use a week bucket so day switching reuses the same range listener.`) with:

```dart
  @override
  Widget build(BuildContext context) {
    // The route argument is a SNAPSHOT; this is the same question asked of
    // Firestore. Resolved ONCE so the picker, the stream, the day filter and
    // `showActions` cannot disagree about who is looking.
    final isAdmin = widget.isAdmin && ref.watch(isActiveAdminProvider);

    // Use a week bucket so day switching reuses the same range listener.
    final range = AppointmentDateRange.forWeekBucketOf(_day);

    // Admins need the whole day for the employee picker.
    final provider = isAdmin
        ? appointmentsInRangeProvider(range)
        : myAppointmentsProvider((employeeId: widget.employeeId, range: range));
    final async = ref.watch(provider);
    ref.listen(provider, _onAppointmentsAsyncChange);

    final data = _prepareBuild(
      async.value ?? const <AppointmentRecord>[],
      ref.watch(employeeNameMapProvider),
      isAdmin: isAdmin,
    );

    return FeatureTourHost(
      scope: _tour.scope,
      isAdmin: widget.isAdmin,
      stepKeys: _tour.keys,
      // Wait for real rows before starting the tour.
      ready: async is AsyncData<List<AppointmentRecord>>,
      child: _buildScaffold(async, data, isAdmin: isAdmin),
    );
  }
```

- [x] **Step 4: Take the resolved role in the two helpers**

Change `_buildScaffold`'s signature and its three `widget.isAdmin` reads:

```dart
  Widget _buildScaffold(
    AsyncValue<List<AppointmentRecord>> async,
    DayRoute data, {
    required bool isAdmin,
  }) {
```

Inside it, replace `if (widget.isAdmin && data.assigneeEntries.isNotEmpty)` with:

```dart
              if (isAdmin && data.assigneeEntries.isNotEmpty)
```

and pass `isAdmin` down to the timeline: replace `_timeline(async, data.jobs, data.employeeId)` with

```dart
                  _timeline(async, data.jobs, data.employeeId, isAdmin: isAdmin),
```

Then update `_timeline`'s signature to accept it and forward it to the widget that already takes an `isAdmin` (the `_DayRouteTimeline` constructed around line 428 and its `showEventDetails(context, job, showActions: isAdmin)` at line 488) — replace that constructor's `isAdmin: widget.isAdmin` with `isAdmin: isAdmin`.

`AppNavDrawer` at line 141 keeps `widget.isAdmin`: the drawer builds its own rows from `drawerGroups(isAdmin:)`, and Task 3 gates what an employee can reach from it.

- [x] **Step 5: Add the role to the memo key**

`_prepareBuild` memoizes `buildDayRoute` on its inputs, so the resolved role has to be one of them or the first cached value wins forever. Replace the whole method and add one field beside the other `_prepared*` fields:

```dart
  DayRoute? _preparedData;
  // Inputs used to derive _preparedData.
  List<AppointmentRecord>? _preparedSource;
  Map<String, String>? _preparedNameMap;
  DateTime? _preparedDay;
  String? _preparedEmployeeId;
  bool? _preparedIsAdmin;

  // Memoizes `buildDayRoute` on the inputs it was derived from. The identity
  // memo stays here rather than in `domain/`: it keys on `State` fields the
  // pure function does not have.
  DayRoute _prepareBuild(
    List<AppointmentRecord> source,
    Map<String, String> nameMap, {
    required bool isAdmin,
  }) {
    final cached = _preparedData;
    if (cached != null &&
        identical(source, _preparedSource) &&
        identical(nameMap, _preparedNameMap) &&
        _preparedDay == _day &&
        _preparedEmployeeId == _selectedEmployeeId &&
        _preparedIsAdmin == isAdmin) {
      return cached;
    }

    _preparedSource = source;
    _preparedNameMap = nameMap;
    _preparedDay = _day;
    _preparedEmployeeId = _selectedEmployeeId;
    _preparedIsAdmin = isAdmin;
    return _preparedData = buildDayRoute(
      source: source,
      nameMap: nameMap,
      day: _day,
      isAdmin: isAdmin,
      ownEmployeeId: widget.employeeId,
      selectedEmployeeId: _selectedEmployeeId,
    );
  }
```

- [x] **Step 6: Run the tests**

Run: `flutter test test/features/calendar/screens/day_route_screen_test.dart`
Expected: PASS — including the two new tests.

- [x] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/calendar/screens/day_route_screen.dart test/features/calendar/screens/day_route_screen_test.dart
git commit -F- <<'EOF'
fix(calendar): gate the Day Route crew selector on the live Firestore role

The selector was gated on the route argument, which a stale back stack or a
hand-rolled push can carry falsely. The resolved role now drives the picker,
the stream choice, buildDayRoute and showActions together.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

Shipped as `240102b6`.

---

## Task 3: History is removed for employees

**Files:**
- Modify: `lib/features/navigation/domain/drawer_catalog.dart:21`
- Modify: `lib/routes/app_routes.dart` (the `history` case, plus a gate widget)
- Modify: `lib/features/clients/screens/history_screen.dart:92`
- Modify: `lib/features/clients/widgets/views/appointment_history_view.dart`
- Delete: `test/features/clients/widgets/appointment_history_scope_test.dart`
- Test: `test/features/navigation/domain/drawer_catalog_test.dart`
- Test: `test/routes/history_admin_gate_test.dart` (create)

- [x] **Step 1: Flip the drawer test**

In `test/features/navigation/domain/drawer_catalog_test.dart`, replace the test named `'an employee reaches History from the TODAY group'` with:

```dart
  test('an employee never reaches History', () {
    // Owner call 2026-09-06: History is an admin surface. A technician reaches
    // a finished job through the calendar, where closed jobs sink to the
    // bottom of the day's agenda.
    final rows = drawerGroups(isAdmin: false).expand((g) => g.rows).toList();
    expect(rows, isNot(contains(PushedDestination.history)));
  });

  test('an admin still reaches History from the BUSINESS group', () {
    final business = drawerGroups(isAdmin: true)[2].rows;
    expect(business, contains(PushedDestination.history));
  });
```

Also update the employee row expectations in `'an employee sees only TODAY and ACCOUNT'` by adding one line inside it:

```dart
    expect(rows, isNot(contains(PushedDestination.history)));
```

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/navigation/domain/drawer_catalog_test.dart`
Expected: FAIL — the employee Today group still contains `PushedDestination.history`.

- [x] **Step 3: Drop the row from the catalog**

In `lib/features/navigation/domain/drawer_catalog.dart`, replace the Today group's third row:

```dart
  (
    title: (l10n) => l10n.nav_groupToday,
    rows: [
      HubTab.calendar,
      PushedDestination.dayRoute,
      // History is admin-only (2026-09-06). An employee's copy carried no
      // filter control of any kind, and a technician still reaches a finished
      // job through the calendar's closed-job sink.
      if (isAdmin) HubTab.liveMap,
    ],
  ),
```

- [x] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/navigation/domain/drawer_catalog_test.dart`
Expected: PASS.

- [x] **Step 5: Write the failing route-gate test**

Create `test/routes/history_admin_gate_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/routes/app_routes.dart';

void main() {
  Widget app(Map<String, dynamic> userDoc) => ProviderScope(
    overrides: [
      currentUserDocProvider.overrideWith((_) => Stream.value(userDoc)),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      onGenerateRoute: AppRoutes.onGenerateRoute,
      initialRoute: AppRoutes.history,
      onGenerateInitialRoutes: (_) => [
        AppRoutes.onGenerateRoute(
          const RouteSettings(
            name: AppRoutes.history,
            arguments: HistoryArgs(isAdmin: true, employeeId: 'e1'),
          ),
        )!,
      ],
    ),
  );

  testWidgets('a non-admin pushing /history lands on the invalid-link screen',
      (tester) async {
    await tester.pumpWidget(app(const {'role': 'employee', 'status': 'active'}));
    await tester.pump();
    expect(find.byType(InvalidRouteScreen), findsOneWidget);
  });

  testWidgets('an unsettled doc also refuses — the gate fails closed',
      (tester) async {
    await tester.pumpWidget(app(const {}));
    await tester.pump();
    expect(find.byType(InvalidRouteScreen), findsOneWidget);
  });
}
```

- [x] **Step 6: Run test to verify it fails**

Run: `flutter test test/routes/history_admin_gate_test.dart`
Expected: FAIL — `HistoryScreen` renders instead of `InvalidRouteScreen`.

- [x] **Step 7: Add the gate**

In `lib/routes/app_routes.dart`, add the two imports:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';
```

Replace the `history` case with:

```dart
      case history:
        final args = _args<HistoryArgs>(settings);
        if (args == null) return _invalidRoute(settings);
        return AppPageRoute(
          settings: settings,
          // The archive is admin-only (2026-09-06). The drawer no longer
          // offers it to an employee; this is the half a forged argument or a
          // stale back stack cannot get past.
          builder: (_) => AdminOnly(
            child: HistoryScreen(
              isAdmin: args.isAdmin,
              employeeId: args.employeeId,
            ),
          ),
        );
```

Then add the gate widget immediately above `class InvalidRouteScreen`:

```dart
/// Renders [child] only for a live active admin; anyone else gets a screen they
/// can leave rather than a surface the rules would reject anyway.
class AdminOnly extends ConsumerWidget {
  const AdminOnly({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(isActiveAdminProvider) ? child : const InvalidRouteScreen();
}
```

- [x] **Step 8: Run test to verify it passes**

Run: `flutter test test/routes/history_admin_gate_test.dart`
Expected: PASS — 2 tests.

- [x] **Step 9: Remove the now-dead widget scope**

In `lib/features/clients/screens/history_screen.dart`, delete the `scopeEmployeeId` argument from the `AppointmentHistoryView` call, leaving:

```dart
            builder: (context, _) => AppointmentHistoryView(
              searchQuery: _searchController.text,
              isAdmin: widget.isAdmin,
              filterTourWrap: (child) =>
                  _tour.stepIf(TourStepId.historyFilter, child),
              firstRowTourWrap: (child) =>
                  _tour.stepIf(TourStepId.historyRow, child),
              onFirstPageSettled: _onListSettled,
            ),
```

In `lib/features/clients/widgets/views/appointment_history_view.dart` make four edits:

1. Delete the constructor parameter `this.scopeEmployeeId,` and the field with its doc comment:

```dart
  /// Whose history this is. Null lists the business-wide archive, which only an
  /// admin may read; a technician passes their own doc id and both the paged
  /// list and the search scan narrow to jobs they were assigned to.
  final String? scopeEmployeeId;
```

2. In `_fetchPage`, drop the argument so the call reads:

```dart
      return await ref
          .read(historyPagerProvider)
          .fetchPage(after: after, limit: _pageSize);
```

3. In `_buildPaged`'s empty branch, replace the conditional body with the admin string:

```dart
        _ => AppEmptyState(
          icon: Icons.history_outlined,
          title: context.l10n.common_noAppointmentsFound,
          body: context.l10n.common_tapToScheduleAnAppointment,
        ),
```

4. At the `historySearchProvider` key (line ~443), replace the scoped key with the archive one:

```dart
      (query: query, employeeId: null);
```

- [x] **Step 10: Delete the obsolete test**

```bash
git rm test/features/clients/widgets/appointment_history_scope_test.dart
```

- [x] **Step 11: Run the affected suites**

Run: `flutter test test/features/clients/ test/features/navigation/ test/routes/`
Expected: PASS. `clients_noHistoryYetForYou` is now unreferenced in `lib/` — leave both ARB entries in place; an unused key is not an analyzer error and removing a translated string is a separate call.

- [x] **Step 12: Analyze and commit**

```bash
flutter analyze
git commit -F- <<'EOF'
feat(clients): make History admin-only

An employee's History carried no filter control of any kind: showYear needs
more than one year and showEmployee more than one assignee, and a technician's
list is scoped to their own jobs. Owner call is to remove the surface rather
than build a filter. Closed jobs remain reachable through the calendar.

The drawer no longer offers the row and /history is gated on the live role.
The repository-level employeeId scope stays: it mirrors the deployed
historyScope guard in functions/indexed_search.js.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

- [x] **Step 13: Update the rule file**

`.claude/rules/appointments.md` names "the technician's History scope" in its assignee/job-record paragraph. Replace that clause with a sentence recording that History became admin-only on 2026-09-06 and that the server-side `historyScope` guard and the `emp:<id>:` search scopes deliberately remain.

Shipped as `c9e5812e` + `24b3fdbe`.

---

## Task 4: Remove the Recent section

**Files:**
- Delete: `lib/features/calendar/application/recent_clients_provider.dart`
- Delete: `lib/features/calendar/domain/models/recent_client.dart`
- Delete: `test/features/calendar/recent_clients_provider_test.dart`
- Modify: `lib/features/clients/widgets/fields/client_picker.dart`
- Modify: `lib/features/calendar/widgets/sections/appointment_form_fields.dart`
- Modify: `lib/features/calendar/widgets/sheets/add_appointment_sheet.dart:329,355`
- Modify: `lib/features/calendar/widgets/views/details_edit_body.dart:185,236`
- Modify: `lib/features/calendar/domain/appointments_repository.dart`
- Modify: `lib/features/calendar/data/firebase_appointments_repository.dart`
- Test: `test/features/clients/widgets/client_picker_test.dart`

- [x] **Step 1: Write the failing test**

In `test/features/clients/widgets/client_picker_test.dart`, delete the `recents` constant, the `recentClients` and `onSelectRecent` harness parameters and the two arguments they feed, then add:

```dart
  testWidgets('an empty query renders no results panel at all', (tester) async {
    await tester.pumpWidget(harness(controller: TextEditingController()));
    // Recent was removed 2026-09-06: search is the only way to a client.
    expect(find.text('Recent clients'), findsNothing);
    expect(find.text('Search results'), findsNothing);
  });
```

Delete any existing test that asserts a recents row is tapped (the one binding `RecentClient? picked`).

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/clients/widgets/client_picker_test.dart`
Expected: FAIL to compile — `recentClients` is a required parameter of `ClientPicker`.

- [x] **Step 3: Strip the picker**

In `lib/features/clients/widgets/fields/client_picker.dart`:

- delete the import of `recent_client.dart`;
- delete the `required this.recentClients,` and `required this.onSelectRecent,` constructor entries;
- delete the `recentClients` field and the `onSelectRecent` field with its doc comment;
- delete the whole `_recents` method;
- replace the tail of `_body` so an empty or still-holding query renders nothing:

```dart
    if (controller.text.trim().isEmpty || status.isHolding) {
      return const SizedBox.shrink();
    }
    return _results(context, l10n);
```

**Do NOT touch `_results`, `_header`, `_Panel` or `_Row` — Task 12 rewrites those and will collide.**

- [x] **Step 4: Strip the form fields**

In `lib/features/calendar/widgets/sections/appointment_form_fields.dart`:

- delete the import of `recent_client.dart`;
- delete `required this.onResolveRecentClient,` from `AppointmentFormCallbacks` and the field with its doc comment;
- delete `this.recentClients = const [],` from `AppointmentFormFields` and the `recentClients` field with its doc comment;
- delete the whole `_selectRecent` method with its doc comment;
- in the `ClientPicker(...)` call, delete the `recentClients: recentClients,` and `onSelectRecent: (recent) => _selectRecent(context, recent),` arguments.

- [x] **Step 5: Strip the two call sites**

In `lib/features/calendar/widgets/sheets/add_appointment_sheet.dart`, delete the line `recentClients: ref.watch(recentClientsProvider).value ?? const [],` and the two-line `onResolveRecentClient: (recent) => resolveRecentClient(ref, recent),` argument, plus the now-unused import of `recent_clients_provider.dart`.

In `lib/features/calendar/widgets/views/details_edit_body.dart`, delete the three-line `recentClients:` ternary and the `onResolveRecentClient: (recent) => resolveRecentClient(ref, recent),` argument, plus the same import.

- [x] **Step 6: Strip the repository**

In `lib/features/calendar/domain/appointments_repository.dart`, delete the `fetchRecentClientBookings` declaration and its doc comment.

In `lib/features/calendar/data/firebase_appointments_repository.dart`, delete the `fetchRecentClientBookings` implementation (around line 503) including its `@override`.

- [x] **Step 7: Delete the dead files**

```bash
git rm lib/features/calendar/application/recent_clients_provider.dart lib/features/calendar/domain/models/recent_client.dart test/features/calendar/recent_clients_provider_test.dart
```

- [x] **Step 8: Drop the ARB key**

Delete `"clients_recentClients"` and its `"@clients_recentClients"` block from `lib/l10n/app_en.arb`, and `"clients_recentClients"` from `lib/l10n/app_fr.arb` (line ~843). The hook regenerates — do not run `flutter gen-l10n`.

- [x] **Step 9: Run the tests**

Run: `flutter test test/features/clients/ test/features/calendar/`
Expected: PASS. If `appointment_form_fields_test.dart` still passes `onResolveRecentClient: (_) async => null,` (line ~114), delete that argument.

- [x] **Step 10: Analyze and commit**

```bash
flutter analyze
git commit -F- <<'EOF'
feat(calendar): remove the Recent clients section from Add New Appointment

Search is the only way to a client now. The provider, the model, the
repository read and the tests go with the UI - git has the history.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

Shipped as `d3440af1`. Follow-up noted: `.claude/rules/clients.md` still carries a
"Recents are free or they are nothing" bullet describing the deleted
`recentClientsProvider` — stale, to be trimmed.

---

## Task 5: Job Address follows the toggle

**Files:**
- Modify: `lib/features/calendar/widgets/sections/appointment_form_fields.dart`
- Test: `test/features/calendar/widgets/sections/appointment_form_fields_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/features/calendar/widgets/sections/appointment_form_fields_test.dart` (reuse whatever harness the file already defines; it must let you set `selectedClient` and `useCustomAddress`):

```dart
  const withAddress = ClientRecord(
    id: 'c1',
    name: 'Groupe Lemieux',
    phone: '5145550142',
    address: '4188 Rue Sainte-Catherine E',
  );
  const noAddress = ClientRecord(id: 'c2', name: 'Anne Roy', phone: '5145550199');

  testWidgets('the toggle ON hides the Job address section', (tester) async {
    await tester.pumpWidget(
      harness(selectedClient: withAddress, useCustomAddress: false),
    );
    expect(find.text('Job address'), findsNothing);
  });

  testWidgets('the toggle OFF shows the Job address section', (tester) async {
    await tester.pumpWidget(
      harness(selectedClient: withAddress, useCustomAddress: true),
    );
    expect(find.text('Job address'), findsOneWidget);
  });

  testWidgets('a client with NO address on file keeps the field', (tester) async {
    // This client sits at useCustomAddress == false too, and shows no toggle -
    // hiding here would make the job unable to get an address at all.
    await tester.pumpWidget(
      harness(selectedClient: noAddress, useCustomAddress: false),
    );
    expect(find.text('Job address'), findsOneWidget);
  });
```

Match the label text to whatever `calendar_jobAddress` resolves to in `app_en.arb`; read it there rather than guessing.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/calendar/widgets/sections/appointment_form_fields_test.dart`
Expected: FAIL on the first test — the section renders a client-address pill.

- [ ] **Step 3: Add the derived getter**

In `lib/features/calendar/widgets/sections/appointment_form_fields.dart`, add beside the other derived helpers (just above `_jobAddress()`):

```dart
  /// True exactly when `SelectedClientCard` is showing its "use this address"
  /// toggle AND it is on — so the Job Address block below would only repeat
  /// the address already on screen.
  ///
  /// The non-empty test is load-bearing: a client with NO address on file also
  /// sits at `useCustomAddress == false` and shows no toggle, so hiding on the
  /// flag alone leaves that job with no way to get an address at all.
  bool get _clientAddressInUse =>
      !useCustomAddress &&
      (selectedClient?.fullAddress.trim().isNotEmpty ?? false);
```

- [ ] **Step 4: Gate the section**

In `_whoSection`, replace the four lines of the client branch that render the label and the section:

```dart
      const SizedBox(height: AppSpacing.sp16),
      if (!_clientAddressInUse) ...[
        formLabel(context, l10n.calendar_jobAddress, required: true),
        const SizedBox(height: AppSpacing.sp4),
        _tour(TourStepId.apptJobAddress, _jobAddress()),
        const SizedBox(height: AppSpacing.sp16),
      ],
```

Leave the `isPersonal && !isDayOff` branch below untouched — a personal block has no client and no toggle.

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/calendar/widgets/sections/appointment_form_fields_test.dart`
Expected: PASS — 3 new tests.

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/calendar/widgets/sections/appointment_form_fields.dart test/features/calendar/widgets/sections/appointment_form_fields_test.dart
git commit -F- <<'EOF'
feat(calendar): hide the Job address block while the client address is in use

The block repeated the address the SelectedClientCard already shows. Turning
the toggle off brings it straight back; a client with no address on file keeps
the field either way.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 6: Back button on the client filter sheet

**Files:**
- Modify: `lib/features/clients/widgets/sheets/clients_filter_sheet.dart`
- Test: `test/features/clients/widgets/clients_filter_sheet_test.dart` (create if absent)

- [ ] **Step 1: Write the failing test**

Create or extend `test/features/clients/widgets/clients_filter_sheet_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/widgets/sheets/clients_filter_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_back_button.dart';

void main() {
  Widget harness({required VoidCallback onBack}) => ProviderScope(
    overrides: [
      clientBuildingsProvider.overrideWith((_) async => const []),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ClientsFilterSheet(
          selected: const ClientsFilterAll(),
          onChanged: (_) {},
          onBack: onBack,
        ),
      ),
    ),
  );

  testWidgets('the sheet offers a visible back control', (tester) async {
    var backs = 0;
    await tester.pumpWidget(harness(onBack: () => backs++));
    await tester.pump();
    expect(find.byType(AppBackButton), findsOneWidget);
    await tester.tap(find.byType(AppBackButton));
    await tester.pump();
    // Back reports NOTHING, so the caller keeps the filter it already had.
    expect(backs, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/clients/widgets/clients_filter_sheet_test.dart`
Expected: FAIL — `ClientsFilterSheet` has no `onBack` parameter.

- [ ] **Step 3: Add the control**

In `lib/features/clients/widgets/sheets/clients_filter_sheet.dart`, add the import:

```dart
import 'package:scheduling/shared/widgets/primitives/app_back_button.dart';
```

Add the parameter and field:

```dart
  const ClientsFilterSheet({
    required this.selected,
    required this.onChanged,
    required this.onBack,
    super.key,
  });

  final ClientsFilter selected;
  final ValueChanged<ClientsFilterPick> onChanged;

  /// Leaves the sheet reporting NOTHING, so the caller keeps the filter, the
  /// chip label and the list position it already had.
  final VoidCallback onBack;
```

Replace the title `Padding` with a row that carries the arrow:

```dart
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sp4,
                AppSpacing.sp4,
                AppSpacing.sp16,
                AppSpacing.sp8,
              ),
              child: Row(
                children: [
                  AppBackButton(onTap: onBack),
                  Expanded(
                    child: Text(
                      l10n.clients_filterTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
```

Finally, wire the launcher at the bottom of the same file:

```dart
Future<ClientsFilterPick?> showClientsFilterSheet(
  BuildContext context, {
  required ClientsFilter selected,
}) => showModalBottomSheet<ClientsFilterPick>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) => ClientsFilterSheet(
    selected: selected,
    onChanged: (pick) => Navigator.of(sheetContext).pop(pick),
    onBack: () => Navigator.of(sheetContext).pop(),
  ),
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/clients/widgets/clients_filter_sheet_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/clients/widgets/sheets/clients_filter_sheet.dart test/features/clients/widgets/clients_filter_sheet_test.dart
git commit -F- <<'EOF'
feat(clients): give the client filter sheet a visible back control

Its only exit was a drag-down or a scrim tap. Back pops with no value, so the
active filter, its chip label and the list position all survive.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 7: Employee photos stay visible

Two independent fixes: the section must appear while an upload is pending, and it must re-read when the upload lands.

**Files:**
- Modify: `lib/features/calendar/widgets/views/details_view_leaf_widgets.dart` (`DetailsPhotosView`)
- Modify: `lib/features/calendar/application/event_details_controller.dart`
- Test: `test/features/calendar/details_photos_view_test.dart` (create)

- [ ] **Step 1: Write the failing test**

Create `test/features/calendar/details_photos_view_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/application/photo_upload_notifier.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/widgets/views/details_view_leaf_widgets.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  final appointment = AppointmentRecord(
    id: 'a1',
    title: 'Leak',
    startTime: DateTime(2026, 9, 6, 9),
    endTime: DateTime(2026, 9, 6, 10),
  );

  testWidgets('a pending upload renders the section on a job with no photos',
      (tester) async {
    final notifier = PhotoUploadNotifier()..reportPending({'a1': 1});
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [photoUploadNotifierProvider.overrideWithValue(notifier)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DetailsPhotosView(
              appointment: appointment,
              isCancelled: false,
              onRetry: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Before: hasPhotos ignored pendingCount, so the whole section was a
    // SizedBox.shrink and the first photo on a job vanished while uploading.
    expect(find.byType(SizedBox), findsWidgets);
    expect(find.text('PHOTOS'), findsOneWidget);
  });
}
```

If `PhotoUploadNotifier`'s constructor or `reportPending` signature differs, read `lib/features/calendar/application/photo_upload_notifier.dart` and match it exactly.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/calendar/details_photos_view_test.dart`
Expected: FAIL — `find.text('PHOTOS')` finds nothing.

- [ ] **Step 3: Count pending in the render gate**

In `lib/features/calendar/widgets/views/details_view_leaf_widgets.dart`, inside `DetailsPhotosView.build`, hoist the pending count above the gate and include it:

```dart
    final failedCount = failure?.failedCount ?? 0;
    final pendingCount = appointmentId == null
        ? 0
        : notifier.pending.value[appointmentId] ?? 0;
    // pendingCount is part of this test on purpose: without it the FIRST photo
    // added to a job left the whole section as a SizedBox.shrink for the whole
    // upload, so the crew saw no sign their photo existed.
    final hasPhotos =
        existingImages.isNotEmpty ||
        newImages.isNotEmpty ||
        failedCount > 0 ||
        pendingCount > 0;
    if (!hasPhotos) return const SizedBox.shrink();
```

Leave the `ValueListenableBuilder` below as it is — it still owns the per-drain rebuild, and `pendingCount` inside it stays read from the builder's `pending` argument.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/calendar/details_photos_view_test.dart`
Expected: PASS.

- [ ] **Step 5: Re-read the subcollection when an upload lands**

In `lib/features/calendar/application/event_details_controller.dart`, inside `build()`, subscribe to the repository's local-write stream and dispose the subscription with the notifier. Add immediately after the two existing `Future.microtask` lines:

```dart
    // A background photo upload appends its rows through this same singleton
    // repository, so its local-write poke is how this sheet learns the photo
    // landed. Without it the crew saw nothing until they closed and reopened.
    final writes = ref
        .read(appointmentsRepositoryProvider)
        .onLocalWrite
        .listen(
          (_) => unawaited(_loadStoredPictures()),
          onError: (Object e, StackTrace st) =>
              ref.read(loggerProvider).warn('APPT-IMG local write poke', e, st),
        );
    ref.onDispose(writes.cancel);
```

Add `import 'dart:async';` to the file if it is not already imported.

`_loadStoredPictures` needs no change: it already refuses to adopt a server list when the user has edited the photo list in the sheet (`if (!listEquals(state.existingImages, _lastKnownImages)) return;`).

- [ ] **Step 6: Run the controller suite**

Run: `flutter test test/features/calendar/event_details_controller_test.dart test/features/calendar/event_details_controller_image_cap_test.dart`
Expected: PASS. If a test's fake repository does not implement `onLocalWrite`, give it `Stream<void> get onLocalWrite => const Stream.empty();`.

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/calendar/widgets/views/details_view_leaf_widgets.dart lib/features/calendar/application/event_details_controller.dart test/features/calendar/details_photos_view_test.dart
git commit -F- <<'EOF'
fix(calendar): keep an employee's uploaded photos visible

Two gaps, both client-side - the rules already grant an assignee read and
create. DetailsPhotosView ignored pendingCount, so the first photo on a job
left the section invisible for the whole upload; and nothing re-read the
subcollection when a background upload landed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 8: The FieldNote model and its store

**Files:**
- Create: `lib/features/calendar/domain/models/field_note.dart`
- Create: `lib/features/calendar/data/appointment_field_notes_store.dart`
- Test: `test/features/calendar/domain/field_note_test.dart`

- [ ] **Step 1: Write the failing model test**

Create `test/features/calendar/domain/field_note_test.dart`:

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';

void main() {
  test('fromMap reads every stored field', () {
    final note = FieldNote.fromMap('n1', {
      'text': 'Copper feed corroded at the elbow.',
      'authorId': 'e1',
      'authorName': 'Marc Tremblay',
      'createdAt': Timestamp.fromDate(DateTime.utc(2026, 9, 6, 8, 42)),
    });
    expect(note.id, 'n1');
    expect(note.text, 'Copper feed corroded at the elbow.');
    expect(note.authorId, 'e1');
    expect(note.authorName, 'Marc Tremblay');
    expect(note.createdAt, DateTime.utc(2026, 9, 6, 8, 42));
  });

  test('a missing author degrades to empty rather than throwing', () {
    // A console-written or partially-migrated row must still render.
    final note = FieldNote.fromMap('n2', const {'text': 'hi'});
    expect(note.authorId, '');
    expect(note.authorName, '');
    expect(note.createdAt, isNull);
  });

  test('the legacy single string becomes an unattributed note', () {
    final note = FieldNote.legacy('Shutoff valve is behind the dryer.');
    expect(note.id, FieldNote.legacyId);
    expect(note.text, 'Shutoff valve is behind the dryer.');
    expect(note.authorId, isEmpty);
    expect(note.authorName, isEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/calendar/domain/field_note_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../field_note.dart'`

- [ ] **Step 3: Write the model**

Create `lib/features/calendar/domain/models/field_note.dart`:

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:scheduling/core/utils/firestore_parsing.dart';

part 'field_note.freezed.dart';

/// One crew note on a job — `appointments/{id}/fieldNotes/{noteId}`.
///
/// A document rather than a field on the parent, because two assignees on the
/// same job used to overwrite each other's single `fieldNotes` string, and
/// because the admin reading the record needs to know who wrote what.
@freezed
abstract class FieldNote with _$FieldNote {
  const factory FieldNote({
    required String id,
    @Default('') String text,
    @Default('') String authorId,
    @Default('') String authorName,
    DateTime? createdAt,
  }) = _FieldNote;
  const FieldNote._();

  /// Document id given to the pre-subcollection `fieldNotes` string, so the
  /// thread can render it beside real notes without colliding with one.
  static const String legacyId = 'legacy';

  factory FieldNote.fromMap(String id, Map<String, dynamic> data) => FieldNote(
    id: id,
    text: (data['text'] ?? '').toString(),
    authorId: (data['authorId'] ?? '').toString(),
    authorName: (data['authorName'] ?? '').toString(),
    createdAt: firestoreDateTime(data['createdAt']),
  );

  /// The appointment's own `fieldNotes` string, shown unattributed at the top
  /// of the thread. Nothing writes that field any more.
  factory FieldNote.legacy(String text) =>
      FieldNote(id: legacyId, text: text);

  bool get hasAuthor => authorName.trim().isNotEmpty;
}
```

- [ ] **Step 4: Generate the freezed part**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: writes `lib/features/calendar/domain/models/field_note.freezed.dart`.

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/calendar/domain/field_note_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 6: Write the store**

Create `lib/features/calendar/data/appointment_field_notes_store.dart`:

```dart
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:scheduling/core/logging/app_logger.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';

/// Reads and writes crew notes in `appointments/{id}/fieldNotes`.
///
/// Deliberately shaped like [AppointmentImagesStore]: the crew ADD to the
/// record and nothing more, so there is no update and no delete here — both
/// stay with the admin, in the rules and in this API.
class AppointmentFieldNotesStore {
  AppointmentFieldNotesStore({
    required CollectionReference<Map<String, dynamic>> appointments,
    required AppLogger logger,
  }) : _appointments = appointments,
       _logger = logger;

  final CollectionReference<Map<String, dynamic>> _appointments;
  final AppLogger _logger;

  /// The literal subcollection path shared with rules.
  static const String notesSubcollection = 'fieldNotes';

  /// Maximum note documents fetched for one appointment.
  static const int scanLimit = 200;

  CollectionReference<Map<String, dynamic>> _notesOf(String id) =>
      _appointments.doc(id).collection(notesSubcollection);

  /// Appends one note. The parent document is NOT touched: a note changes no
  /// field the history search reads, and leaving the parent alone keeps this
  /// write off the assignee `allow update` branches entirely.
  Future<void> append(
    String appointmentId, {
    required String text,
    required String authorId,
    required String authorName,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _notesOf(appointmentId).add({
      'text': trimmed,
      'authorId': authorId,
      'authorName': authorName,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<List<FieldNote>> fetch(String appointmentId) async {
    final snapshot = await _notesOf(
      appointmentId,
    ).orderBy('createdAt').limit(scanLimit).get();
    if (snapshot.docs.length >= scanLimit) {
      _logger.warn(
        'APPT-FIELDNOTE subcollection read for $appointmentId hit the '
        '$scanLimit-doc cap - notes beyond it were not loaded',
      );
    }
    return [
      for (final doc in snapshot.docs) FieldNote.fromMap(doc.id, doc.data()),
    ];
  }
}
```

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/calendar/domain/models/field_note.dart lib/features/calendar/domain/models/field_note.freezed.dart lib/features/calendar/data/appointment_field_notes_store.dart test/features/calendar/domain/field_note_test.dart
git commit -F- <<'EOF'
feat(calendar): add the FieldNote model and its subcollection store

One document per crew note, author-stamped, so two assignees on a job stop
overwriting each other and an admin can see who wrote what.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 9: Firestore rules for the notes subcollection

**Files:**
- Modify: `firestore.rules`
- Test: `test/core/security/field_notes_rules_test.dart` (create)

- [ ] **Step 1: Write the failing rules test**

Create `test/core/security/field_notes_rules_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Rules cannot be unit-tested without the emulator, so — like
/// `appointment_images_rules_test.dart` — this reads `firestore.rules` back as
/// TEXT and pins the properties the crew-notes grant stands on.
void main() {
  late final rules = File('firestore.rules').readAsStringSync();

  String notesBlock() {
    final start = rules.indexOf('match /fieldNotes/{noteId}');
    expect(
      start,
      greaterThan(-1),
      reason:
          'the crew-notes subcollection has no rules block, so every note '
          'read and write is denied by default',
    );
    final end = rules.indexOf('\n      }', start);
    return rules.substring(start, end == -1 ? rules.length : end);
  }

  String collapsed(String source) =>
      source.replaceAll(RegExp('//[^\n]*'), '').replaceAll(RegExp(r'\s+'), ' ');

  test('read is admin OR an assignee of THIS appointment', () {
    final block = notesBlock();
    expect(block, contains('allow read:'));
    expect(block, contains('isAdmin()'));
    expect(block, contains('isAssignedEmployee(parentAppointment())'));
  });

  test('an assignee may ADD a note', () {
    expect(
      collapsed(notesBlock()),
      contains(
        'allow create: if (isAdmin() || '
        'isAssignedEmployee(parentAppointment()))',
      ),
    );
  });

  test('a note can only be filed under the CALLER own doc id', () {
    // Without this an assignee could post a note signed with a colleague name.
    expect(
      collapsed(notesBlock()),
      contains('request.resource.data.authorId == myDocId()'),
    );
  });

  test('the key set is exact', () {
    expect(
      collapsed(notesBlock()),
      contains(
        "hasOnly( ['text', 'authorId', 'authorName', 'createdAt'])".replaceAll(
          RegExp(r'\s+'),
          ' ',
        ),
      ),
    );
  });

  test('text and authorName are length-capped and createdAt is pinned', () {
    final block = collapsed(notesBlock());
    expect(block, contains('isBoundedString(request.resource.data.text, 4000)'));
    expect(
      block,
      contains('isBoundedString(request.resource.data.authorName, 200)'),
    );
    expect(block, contains('request.resource.data.createdAt == request.time'));
  });

  test('editing and deleting a note stay ADMIN-ONLY', () {
    // A field record must not be quietly rewritten by the person whose work it
    // documents - the same posture the images subcollection takes.
    final block = notesBlock();
    expect(block, contains('allow update: if isAdmin()'));
    expect(block, contains('allow delete: if isAdmin()'));
  });

  test('the parent assignee update disjuncts are UNCHANGED', () {
    // A note write must not touch the parent document, so this adds no
    // disjunct - appointment_employee_update_rules_test.dart pins the count at
    // three and this test says why that number did not move.
    expect(
      '|| (isAssignedEmployee(resource.data)'.allMatches(rules).length,
      3,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/core/security/field_notes_rules_test.dart`
Expected: FAIL — "the crew-notes subcollection has no rules block".

- [ ] **Step 3: Add the rules block**

In `firestore.rules`, inside `match /appointments/{appointmentId}`, immediately after the closing `}` of the `match /images/{imageId}` block, add:

```
      match /fieldNotes/{noteId} {
        allow read: if isAdmin() || isAssignedEmployee(parentAppointment());

        allow create: if (isAdmin() || isAssignedEmployee(parentAppointment()))
          && request.resource.data.keys().hasOnly(
              ['text', 'authorId', 'authorName', 'createdAt'])
          && isBoundedString(request.resource.data.text, 4000)
          && request.resource.data.text.size() > 0
          && request.resource.data.authorId == myDocId()
          && isBoundedString(request.resource.data.authorName, 200)
          && request.resource.data.createdAt == request.time;

        allow update: if isAdmin();
        allow delete: if isAdmin();
      }
```

`parentAppointment()` is already declared in the `images` block. Firestore scopes a `function` to the `match` block that declares it, so **hoist it**: cut the four-line `function parentAppointment() { ... }` out of `match /images/{imageId}` and paste it directly under `match /appointments/{appointmentId} {`, above the `allow read:` line, so both subcollections resolve it.

- [ ] **Step 4: Run both rules suites**

Run: `flutter test test/core/security/`
Expected: PASS — the new suite plus the untouched `appointment_images_rules_test.dart` (which asserts the block still `contains('isAssignedEmployee(parentAppointment())')`, true after the hoist) and `appointment_employee_update_rules_test.dart`.

- [ ] **Step 5: Commit**

```bash
flutter analyze
git add firestore.rules test/core/security/field_notes_rules_test.dart
git commit -F- <<'EOF'
feat(rules): grant crew notes on appointments/{id}/fieldNotes

Read and create for an admin or an assignee, with authorId pinned to the
caller own doc id so a note cannot be filed under someone else name. Update
and delete stay admin-only, matching the images subcollection: adding to the
record is additive, removing from it is not.

Adds no parent allow-update disjunct - a note write never touches the parent.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 10: Repository and provider wiring for notes

**Files:**
- Modify: `lib/features/calendar/domain/appointments_repository.dart`
- Modify: `lib/features/calendar/data/firebase_appointments_repository.dart`
- Create: `lib/features/calendar/application/field_notes_provider.dart`
- Test: `test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart`

- [ ] **Step 1: Add the write case that will fail**

In `test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart`, add to `_writeCases`:

```dart
  (
    method: 'appendFieldNote',
    run: (r) => r.appendFieldNote(
      appointmentId: 'a1',
      text: 'Valve replaced',
      authorId: 'e1',
      authorName: 'Marc Tremblay',
    ),
    keepsA1: true,
    why: 'a crew note touches no field matchHistoryDocs reads',
  ),
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart`
Expected: FAIL to compile — `appendFieldNote` is not defined on `AppointmentsRepository`.

- [ ] **Step 3: Declare it on the interface**

In `lib/features/calendar/domain/appointments_repository.dart`, add beside the picture methods:

```dart
  /// Appends one crew note to `appointments/{id}/fieldNotes`.
  ///
  /// [authorId] must be the caller's own users-doc id — `firestore.rules`
  /// refuses anything else, so a note cannot be filed under another name.
  Future<void> appendFieldNote({
    required String appointmentId,
    required String text,
    required String authorId,
    required String authorName,
  });

  /// This job's crew notes, oldest first.
  Future<List<FieldNote>> fetchFieldNotes(String appointmentId);
```

Add the import `package:scheduling/features/calendar/domain/models/field_note.dart`.

- [ ] **Step 4: Implement it**

In `lib/features/calendar/data/firebase_appointments_repository.dart`:

Add the two imports:

```dart
import 'package:scheduling/features/calendar/data/appointment_field_notes_store.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
```

In the constructor body, beside `_images`:

```dart
    _fieldNotes = AppointmentFieldNotesStore(
      appointments: _appointments,
      logger: _logger,
    );
```

Beside the `_images` field:

```dart
  /// The crew-notes half — the `appointments/{id}/fieldNotes` subcollection.
  late final AppointmentFieldNotesStore _fieldNotes;
```

And the two methods, next to `appendAppointmentPictures`:

```dart
  @override
  Future<void> appendFieldNote({
    required String appointmentId,
    required String text,
    required String authorId,
    required String authorName,
  }) async {
    await _fieldNotes.append(
      appointmentId,
      text: text,
      authorId: authorId,
      authorName: authorName,
    );
    // The narrow poke: a note changes no field matchHistoryDocs reads, so the
    // window is woken rather than rebuilt.
    _notifyLocalWrite();
  }

  @override
  Future<List<FieldNote>> fetchFieldNotes(String appointmentId) =>
      _fieldNotes.fetch(appointmentId);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart`
Expected: PASS. If the mocked collection needs a stub for `.collection('fieldNotes')`, add one mirroring the existing `images` stub in that file's `repo()` helper.

- [ ] **Step 6: Add the provider**

Create `lib/features/calendar/application/field_notes_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/features/calendar/application/appointments_providers.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';

/// One job's crew notes, oldest first.
///
/// autoDispose and keyed by appointment id: the thread is read when a detail
/// sheet opens and is not worth holding once it closes.
final appointmentFieldNotesProvider = FutureProvider.autoDispose
    .family<List<FieldNote>, String>((ref, appointmentId) async {
      if (appointmentId.isEmpty) return const [];
      return ref
          .watch(appointmentsRepositoryProvider)
          .fetchFieldNotes(appointmentId);
    });
```

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/calendar/domain/appointments_repository.dart lib/features/calendar/data/firebase_appointments_repository.dart lib/features/calendar/application/field_notes_provider.dart test/features/calendar/data/firebase_appointments_repository_invalidation_test.dart
git commit -F- <<'EOF'
feat(calendar): repository and provider for crew notes

appendFieldNote pokes the history window rather than patching it - a note
changes no field the history search reads.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 11: The crew notes UI

**Files:**
- Create: `lib/features/calendar/widgets/views/details_field_notes_view.dart`
- Modify: `lib/features/calendar/widgets/views/details_field_record_view.dart`
- Modify: `lib/features/calendar/widgets/views/details_view_body.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- Test: `test/features/calendar/details_field_notes_view_test.dart` (create)

- [ ] **Step 1: Add the l10n keys**

In `lib/l10n/app_en.arb`, beside the existing `calendar_fieldNotes*` keys:

```json
  "calendar_crewNotesLabel": "CREW NOTES",
  "@calendar_crewNotesLabel": {
    "description": "Mono all-caps section label over the thread of notes the crew wrote on a job, shown to admins and crew alike. Already uppercase in source."
  },
  "calendar_addANote": "Add a note",
  "@calendar_addANote": {
    "description": "Button that posts the text in the crew notes field as a new note. Replaced a Save button when notes became append-only."
  },
  "calendar_notePosted": "Note added",
  "@calendar_notePosted": {
    "description": "Success notice after a technician posts a crew note."
  },
  "calendar_noteBy": "{name} · {when}",
  "@calendar_noteBy": {
    "description": "Byline over one crew note: who wrote it and when.",
    "placeholders": {
      "name": { "type": "String" },
      "when": { "type": "String" }
    }
  },
```

In `lib/l10n/app_fr.arb` (bare keys, no metadata):

```json
  "calendar_crewNotesLabel": "NOTES DE L'ÉQUIPE",
  "calendar_addANote": "Ajouter une note",
  "calendar_notePosted": "Note ajoutée",
  "calendar_noteBy": "{name} · {when}",
```

The hook regenerates. Verify `lib/l10n/.gen/untranslated.json` gained no entries.

- [ ] **Step 2: Write the failing view test**

Create `test/features/calendar/details_field_notes_view_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scheduling/features/calendar/application/field_notes_provider.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
import 'package:scheduling/features/calendar/widgets/views/details_field_notes_view.dart';
import 'package:scheduling/l10n/l10n.dart';

void main() {
  AppointmentRecord appointment({String fieldNotes = ''}) => AppointmentRecord(
    id: 'a1',
    title: 'Leak',
    startTime: DateTime(2026, 9, 6, 9),
    endTime: DateTime(2026, 9, 6, 10),
    fieldNotes: fieldNotes,
  );

  Widget harness(AppointmentRecord record, List<FieldNote> notes) =>
      ProviderScope(
        overrides: [
          appointmentFieldNotesProvider.overrideWith((_, _) async => notes),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DetailsFieldNotesView(appointment: record)),
        ),
      );

  testWidgets('an admin sees each note and who wrote it', (tester) async {
    await tester.pumpWidget(
      harness(appointment(), [
        FieldNote(
          id: 'n1',
          text: 'Copper feed corroded at the elbow.',
          authorId: 'e1',
          authorName: 'Marc Tremblay',
          createdAt: DateTime(2026, 9, 6, 8, 42),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Copper feed corroded at the elbow.'), findsOneWidget);
    expect(find.textContaining('Marc Tremblay'), findsOneWidget);
  });

  testWidgets('the legacy string renders unattributed at the top',
      (tester) async {
    await tester.pumpWidget(
      harness(appointment(fieldNotes: 'Valve is behind the dryer.'), const []),
    );
    await tester.pumpAndSettle();
    expect(find.text('Valve is behind the dryer.'), findsOneWidget);
  });

  testWidgets('an empty record renders NOTHING', (tester) async {
    await tester.pumpWidget(harness(appointment(), const []));
    await tester.pumpAndSettle();
    // The empty-omitted rule the rest of the sheet follows.
    expect(find.text('CREW NOTES'), findsNothing);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/calendar/details_field_notes_view_test.dart`
Expected: FAIL — `Target of URI doesn't exist: '.../details_field_notes_view.dart'`

- [ ] **Step 4: Write the thread view**

Create `lib/features/calendar/widgets/views/details_field_notes_view.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/calendar/application/field_notes_provider.dart';
import 'package:scheduling/features/calendar/domain/models/appointment_record.dart';
import 'package:scheduling/features/calendar/domain/models/field_note.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/app_avatar.dart';
import 'package:scheduling/shared/widgets/primitives/mono_section_label.dart';

/// The crew's notes on a job, read-only, shown to ANYONE who may read the job
/// — which is the admin and the assignees, exactly the set the rules admit.
///
/// The dispatcher's brief lives in the appointment's own `notes` and is
/// rendered by the client panel above; this is the other half of that
/// distinction, and the reason the two fields are separate.
class DetailsFieldNotesView extends ConsumerWidget {
  const DetailsFieldNotesView({required this.appointment, super.key});

  final AppointmentRecord appointment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = appointment.id;
    final stored = id == null
        ? const <FieldNote>[]
        : ref.watch(appointmentFieldNotesProvider(id)).value ??
              const <FieldNote>[];

    final legacy = appointment.fieldNotes.trim();
    final notes = [
      if (legacy.isNotEmpty) FieldNote.legacy(legacy),
      ...stored,
    ];
    // Empty omitted, like every other optional block on this sheet.
    if (notes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sp16),
        MonoSectionLabel(context.l10n.calendar_crewNotesLabel),
        const SizedBox(height: AppSpacing.sp8),
        for (final note in notes) ...[
          _Note(note: note),
          const SizedBox(height: AppSpacing.sp12),
        ],
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.note});

  final FieldNote note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final createdAt = note.createdAt;
    final when = createdAt == null
        ? ''
        : DateFormat.MMMd(
            Localizations.localeOf(context).toString(),
          ).add_jm().format(createdAt);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (note.hasAuthor) ...[
          AppAvatar(name: note.authorName, size: AvatarSize.sm),
          const SizedBox(width: AppSpacing.sp8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.hasAuthor)
                Text(
                  l10n.calendar_noteBy(note.authorName, when),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              Text(note.text, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/features/calendar/details_field_notes_view_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 6: Turn the compose box into a post box**

In `lib/features/calendar/widgets/views/details_field_record_view.dart`, replace `_saved`, `_save` and the button half of `build`.

Delete the `_saved` field. Replace `_save` with:

```dart
  Future<void> _post() async {
    final id = widget.appointment.id;
    if (id == null || _isSaving) return;
    // Set BEFORE the first await, like every other submit in this codebase:
    // awaiting first leaves the button live and a double tap posts twice.
    setState(() => _isSaving = true);

    // Resolved up front — `ref.read` on an unmounted consumer throws under
    // Riverpod 3, and this sheet can be dismissed mid-write.
    final logger = ref.read(loggerProvider);
    final notices = ref.read(noticeServiceProvider);
    final repository = ref.read(appointmentsRepositoryProvider);
    final identity = ref.read(activeUserIdentityProvider).value;
    final authorName = ref.read(currentUserNameProvider);
    final text = _notes.text.trim();

    if (identity == null || text.isEmpty) {
      setState(() => _isSaving = false);
      return;
    }

    if (guardedOffline(
      context,
      ref,
      intro: context.l10n.error_introSaveFieldNotes,
    )) {
      setState(() => _isSaving = false);
      return;
    }

    try {
      await repository.appendFieldNote(
        appointmentId: id,
        text: text,
        // The rules pin this to the caller's own doc id, so a note can never
        // be filed under a colleague's name.
        authorId: identity.docId,
        authorName: authorName,
      );
      if (!mounted) return;
      _notes.clear();
      setState(() => _isSaving = false);
      ref.invalidate(appointmentFieldNotesProvider(id));
      notices.success(context.l10n.calendar_notePosted);
    } catch (e, st) {
      logger.warn('APPT-FIELDNOTE appendFieldNote failed', e, st);
      if (!mounted) return;
      setState(() => _isSaving = false);
      notices.error(
        composeErrorNotice(
          context,
          intro: context.l10n.error_introSaveFieldNotes,
          error: e,
        ),
      );
    }
  }
```

In `build`, replace `final isDirty = _notes.text.trim() != _saved;` with:

```dart
    final canPost = _notes.text.trim().isNotEmpty;
```

and the filled button with:

```dart
            Expanded(
              child: FilledButton(
                // Disabled while empty, so the row cannot spend a write on
                // nothing — this is the one surface a technician taps with
                // gloves on, glancing away.
                onPressed: canPost && !_isSaving ? _post : null,
                child: Text(
                  _isSaving ? l10n.common_saving : l10n.calendar_addANote,
                ),
              ),
            ),
```

Change the controller initializer to start empty (it no longer seeds from the record):

```dart
  final TextEditingController _notes = TextEditingController();
```

Add the imports:

```dart
import 'package:scheduling/features/auth/application/account_status_provider.dart';
import 'package:scheduling/features/auth/application/active_user_identity_provider.dart';
import 'package:scheduling/features/calendar/application/field_notes_provider.dart';
```

- [ ] **Step 7: Render the thread in the detail body**

In `lib/features/calendar/widgets/views/details_view_body.dart`, add the import:

```dart
import 'package:scheduling/features/calendar/widgets/views/details_field_notes_view.dart';
```

Insert the thread immediately above the existing `if (canRecordFieldWork)` block, so an admin and a crew member both see it:

```dart
        // Anyone who may READ the job may read its crew notes — the same set
        // the rules admit. The compose box below stays crew-only.
        DetailsFieldNotesView(appointment: appointment),
```

Replace `_canRecordFieldWork`'s inline role test with the shared gate — change the method to:

```dart
  /// Whether the viewer is a non-admin assignee of [appointment].
  static bool _canRecordFieldWork(
    WidgetRef ref,
    AppointmentRecord appointment,
  ) {
    if (ref.watch(isActiveAdminProvider)) return false;
    final identity = ref.watch(activeUserIdentityProvider).value;
    if (identity == null) return false;
    return appointment.employeeIds.contains(identity.docId);
  }
```

and add `import 'package:scheduling/features/auth/application/is_active_admin_provider.dart';`.

- [ ] **Step 8: Run the detail suites**

Run: `flutter test test/features/calendar/`
Expected: PASS. Update any test that asserted the old "Notes saved" success string or a Save button in `DetailsFieldRecordView` to the new `calendar_notePosted` / `calendar_addANote` strings.

- [ ] **Step 9: Analyze and commit**

```bash
flutter analyze
git commit -F- <<'EOF'
feat(calendar): crew notes are append-only, author-stamped and admin-visible

DetailsFieldNotesView renders the thread for anyone who may read the job, so
an admin finally sees what the crew wrote and who wrote it. The compose box
stays crew-only and posts instead of overwriting. The legacy single string
still renders, unattributed, at the top - no backfill.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 12: The client search dropdown

**Files:**
- Modify: `lib/features/clients/widgets/fields/client_picker.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- Test: `test/features/clients/widgets/client_picker_test.dart`

- [ ] **Step 1: Add the fallback caption key**

In `lib/l10n/app_en.arb`:

```json
  "clients_noExactMatchClosest": "NO EXACT MATCH · CLOSEST NUMBERS",
  "@clients_noExactMatchClosest": {
    "description": "Caption inside the client search dropdown when the results are a fallback rung rather than hits. They answer a query nobody typed, so they must never read as matches. Already uppercase in source."
  },
```

In `lib/l10n/app_fr.arb`:

```json
  "clients_noExactMatchClosest": "AUCUNE CORRESPONDANCE EXACTE · NUMÉROS LES PLUS PROCHES",
```

- [ ] **Step 2: Write the failing test**

Add to `test/features/clients/widgets/client_picker_test.dart`:

```dart
  testWidgets('results render as an attached dropdown, not a titled panel',
      (tester) async {
    final controller = TextEditingController(text: '5145628332');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(
        controller: controller,
        results: const [marie],
        status: const ClientSearchStatus(mode: ClientQueryMode.phone),
      ),
    );
    // The panel header and match count are gone with Option A.
    expect(find.text('Exact match'), findsNothing);
    expect(find.text('1 match'), findsNothing);
    expect(find.textContaining('Marie Tremblay'), findsOneWidget);
  });

  testWidgets('a FALLBACK rung is captioned so near misses cannot read as hits',
      (tester) async {
    final controller = TextEditingController(text: '5145628999');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(
        controller: controller,
        results: const [marie, jp],
        status: const ClientSearchStatus(
          mode: ClientQueryMode.phone,
          isFallback: true,
        ),
      ),
    );
    expect(find.text('NO EXACT MATCH · CLOSEST NUMBERS'), findsOneWidget);
  });

  testWidgets('an exact hit carries NO caption', (tester) async {
    final controller = TextEditingController(text: '5145628332');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(
        controller: controller,
        results: const [marie],
        status: const ClientSearchStatus(mode: ClientQueryMode.phone),
      ),
    );
    expect(find.text('NO EXACT MATCH · CLOSEST NUMBERS'), findsNothing);
  });

  testWidgets('searching shows a suffix spinner and KEEPS the results',
      (tester) async {
    final controller = TextEditingController(text: 'lemi');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(controller: controller, results: const [marie], isSearching: true),
    );
    // The old build replaced the whole body with a centred indicator, so the
    // list jumped on every keystroke.
    expect(find.textContaining('Marie Tremblay'), findsOneWidget);
  });
```

If `ClientSearchStatus` spells the fallback flag differently, read `lib/features/clients/domain/models/client_search_status.dart` and use its real field name.

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/clients/widgets/client_picker_test.dart`
Expected: FAIL — the header "Exact match" still renders.

- [ ] **Step 4: Move the spinner into the field**

In `lib/features/clients/widgets/fields/client_picker.dart`, ensure the import is present:

```dart
import 'package:scheduling/core/adaptive/adaptive_progress_indicator.dart';
```

and give the `TextFormField` a suffix, replacing its `decoration:` line:

```dart
          decoration:
              formInputDecoration(context, l10n.clients_tapPhoneToStart)
                  .copyWith(
                    errorText: errorText,
                    // The spinner rides the FIELD, not the list: replacing the
                    // results with a centred indicator made the list jump on
                    // every keystroke.
                    suffixIcon: isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(AppSpacing.sp12),
                            child: AdaptiveProgressIndicator(size: 16),
                          )
                        : null,
                  ),
```

Then delete the `if (isSearching)` branch at the top of `_body`, so it opens straight at the failure test:

```dart
  Widget _body(BuildContext context, AppLocalizations l10n) {
    // A failure that renders as "no clients found" is how a duplicate gets
    // created for a client who is already on file.
    if (status.failed) return _failure(context, l10n);
    if (controller.text.trim().isEmpty || status.isHolding) {
      return const SizedBox.shrink();
    }
    return _results(context, l10n);
  }
```

- [ ] **Step 5: Replace the panel with the dropdown**

Replace `_results` and delete `_header`, `_Panel` and `_Row`, adding a `_Dropdown` and `_DropdownRow` in their place:

```dart
  Widget _results(BuildContext context, AppLocalizations l10n) {
    if (results.isEmpty && onAddNew == null) {
      return Text(
        l10n.clients_noClientsFound,
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    final isPhone = status.mode == ClientQueryMode.phone;
    return _Dropdown(
      // Option A drops the panel header, so the fallback rung keeps its
      // warning as a caption: those rows answer a query nobody typed and must
      // never read as matches.
      caption: status.isFallback ? l10n.clients_noExactMatchClosest : null,
      children: [
        for (final client in results)
          _DropdownRow(
            headline: isPhone && client.phone.trim().isNotEmpty
                ? formatPhoneNumber(client.phone)
                : client.displayName,
            detail: isPhone
                ? client.displayName
                : (client.phone.trim().isEmpty
                      ? null
                      : formatPhoneNumber(client.phone)),
            mono: isPhone,
            action: l10n.clients_attach,
            onTap: () => _attach(context, client),
          ),
        if (onAddNew != null)
          _DropdownRow(
            headline: l10n.clients_noneOfTheseNewClient,
            icon: Icons.person_add_alt_1,
            onTap: () {
              FocusScope.of(context).unfocus();
              onAddNew!();
            },
          ),
      ],
    );
  }
```

And, replacing `_Panel` / `_Row`:

```dart
/// The attached autocomplete list, drawn exactly like
/// `AddressAutocompleteField`'s — same border, radius and `sp4` gap — so the
/// client picker and the address picker behave identically.
class _Dropdown extends StatelessWidget {
  const _Dropdown({required this.children, this.caption});

  final String? caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.sp4),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.r12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (caption != null)
            Container(
              width: double.infinity,
              color: theme.statusColors.warningContainer,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sp12,
                vertical: AppSpacing.sp8,
              ),
              child: Text(
                caption!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.monoType.groupLabel.copyWith(
                  color: theme.statusColors.onWarningContainer,
                ),
              ),
            ),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0 || caption != null)
              Divider(height: 1, color: scheme.outlineVariant),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  const _DropdownRow({
    required this.headline,
    required this.onTap,
    this.detail,
    this.action,
    this.icon,
    this.mono = false,
  });

  final String headline;
  final String? detail;
  final String? action;
  final IconData? icon;

  /// A phone number reads as a number, not as prose.
  final bool mono;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sp12,
          vertical: AppSpacing.sp8,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.sp8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    headline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: icon != null
                        ? theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : (mono
                              ? theme.monoType.metric
                              : theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                )),
                  ),
                  if (detail != null && detail!.trim().isNotEmpty)
                    Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (action != null)
              TextButton(
                onPressed: onTap,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sp8,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  action!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
```

If `theme.statusColors` has no `warningContainer` / `onWarningContainer`, read `lib/core/theme/extensions/app_status_colors.dart` and use the warning pair it actually defines — do not reach for `colorScheme.tertiary` container slots by hand and never use a success colour here.

- [ ] **Step 6: Run test to verify it passes**

Run: `flutter test test/features/clients/widgets/client_picker_test.dart`
Expected: PASS — including the four new tests. Delete or update any older test in the file that asserted `'Search results'`, `'Closest numbers'` or a match-count string.

- [ ] **Step 7: Check the small-phone overflow case**

Add one harness pump at 260 logical px with 2x text (each test file owns its own local helper for this — there is no shared `_scaledHarness`):

```dart
  testWidgets('the dropdown survives a 260px phone at 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    final controller = TextEditingController(text: '5145628999');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      harness(
        controller: controller,
        results: const [marie, jp],
        status: const ClientSearchStatus(
          mode: ClientQueryMode.phone,
          isFallback: true,
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });
```

Run: `flutter test test/features/clients/widgets/client_picker_test.dart`
Expected: PASS with no overflow exception.

- [ ] **Step 8: Analyze and commit**

```bash
flutter analyze
git commit -F- <<'EOF'
feat(clients): render client search as an attached dropdown

Adopts AddressAutocompleteField's idiom so the client picker and the address
picker behave identically: bordered list under the field, spinner in the
suffix so results no longer jump per keystroke.

The panel header goes with one carve-out - a fallback rung keeps a caption,
because those rows answer a query nobody typed and must never read as matches.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016a4uSgRfEzNGHKFVGNga23
EOF
```

---

## Task 13: Full verification

- [ ] **Step 1: Analyzer**

Run: `flutter analyze`
Expected: `No issues found!` — that is the repo baseline, so anything here is yours.

- [ ] **Step 2: Full suite**

Run: `flutter test`
Expected: PASS. The last recorded green count was 3387; this plan deletes `appointment_history_scope_test.dart` and `recent_clients_provider_test.dart` and adds roughly 30 tests, so expect a number near 3400 — a recorded count is a claim, not a fact, so read the number the run actually prints.

- [ ] **Step 3: Localization drift**

Run: `cat lib/l10n/.gen/untranslated.json`
Expected: no entries for `calendar_crewNotesLabel`, `calendar_addANote`, `calendar_notePosted`, `calendar_noteBy`, `clients_noExactMatchClosest`.

- [ ] **Step 4: BOM check on every touched Dart file**

Run: `for f in $(git diff --name-only main...HEAD -- '*.dart'); do head -c 3 "$f" | od -An -tx1 | grep -q 'ef bb bf' && echo "BOM: $f"; done; echo done`
Expected: `done` with no `BOM:` lines.

- [ ] **Step 5: Manual pass, both roles**

Build with the defines (`--dart-define-from-file=dev/firebase.local.json`) and check, as an **admin**: Add Appointment shows no Recent and a dropdown as you type; the job-address block disappears with the toggle on; the client filter sheet has a back arrow; Day Route still offers the crew picker; History is still in the drawer; a job's crew notes are visible with author names.

Then as an **employee**: no History row in the drawer; Day Route has no crew picker; a job detail offers the note box and posting a note shows it in the thread; adding a photo shows the waiting row immediately and the photo once it lands, and it is still there after leaving and reopening the job.

- [ ] **Step 6: Deploy the rules**

Task 9 changes `firestore.rules`, so it must be deployed BEFORE the app build that writes crew notes ships. Clear the agent env vars first or the CLI stamps `agent-name/claude_code` into the audit log:

```bash
cd functions && npm run lint && cd ..
unset AI_AGENT CLAUDECODE CLAUDE_CODE
firebase deploy --only firestore:rules
```

Never pass `--force` — it deletes any prod TTL policy missing from `firestore.indexes.json`. No functions, no indexes and no backfill are needed for this plan.

---

## Self-review notes

- **Spec coverage:** design items 1→Task 4, 2→Task 5, 3→Task 6, 4→Tasks 1+2, 5→Tasks 8+9+10+11, 6→Task 7, 7→Task 3, 8→Task 12.
- **Type consistency:** `isActiveAdminProvider` (Tasks 1, 2, 3, 11); `FieldNote` / `FieldNote.legacy` / `FieldNote.legacyId` / `hasAuthor` (Tasks 8, 10, 11); `appendFieldNote({appointmentId, text, authorId, authorName})` identical in Tasks 10 and 11; `appointmentFieldNotesProvider(String)` in Tasks 10 and 11; `AppointmentFieldNotesStore.append/fetch` in Tasks 8 and 10.
- **Known soft spots the executor must confirm against real source rather than assume:** `PhotoUploadNotifier`'s constructor and `reportPending` shape (Task 7 Step 1), `ClientSearchStatus.isFallback`'s real field name (Task 12), the warning colour pair on `AppStatusColors` (Task 12 Step 5), and the existing harness signature in `appointment_form_fields_test.dart` (Task 5). Each step says to read the file rather than guess.
