# P7 — Dashboard + History

**Date:** 2026-08-11 · **Branch:** `redesgin` · **Status:** **Phases A–D BUILT
and green.** Nothing here is deployed — none of it needs a deploy, it is all
app-side.

Binding spec: `docs/plans/2026-07-29-redesign-program.md` § P7, including its
2026-08-10 reconciliation block. This document is the implementation plan: the
phases, the decisions taken before writing code, and what is deliberately not
built.

**Both screens already exist and work.** Dashboard and History shipped in July;
P7 is the redesign pass plus one genuinely new control. Nothing here is a
rewrite — read every phase as "change what the spec names, leave the rest".

---

## Decisions taken before implementation

### 1. The period control ships as Today · Week · Month. **Year is dropped.**

The spec asks for four periods and says Month and Year must widen the HISTORY
half of the window, never the live one. The first half of that is fine. The
second is not implementable honestly today:

`AppointmentsRepository.fetchInRange` is capped at `_rangeStreamLimit` (1000)
— `firebase_appointments_repository.dart:343`. That is the same cap whose
silent truncation caused the window split on 2026-08-08, when a 70-day
business-wide listener was computing the 8-week trends over a PREFIX with
nothing on screen saying so. A Year window walks straight back into it: at ~14
jobs/day a year is ~5,100 docs, and even at 5 jobs/day it is ~1,825 — over the
cap for any real business, i.e. every trend on the screen would be wrong and
silent about it.

Owner call 2026-08-11: **ship Today/Week/Month only.** Month is the widest
window the current read path can serve without lying (~420 docs at 14/day, a
comfortable margin). Dropping the option is strictly better than shipping one
that reports partial numbers as if they were totals.

**Year is blocked on an aggregate read path, and as of 2026-09-06 nothing is
scheduled to build one.** P7b was to have needed one — its whole shape was
"project the minimal fields into a rules-locked collection, read via a
callable", and a `count()`-per-bucket path would have served Year exactly — but
**P7b was CANCELLED by owner call 2026-09-06**, so Year's absence is now
permanent rather than pending. Do not "add Year back" by widening
`fetchInRange`: that reports a prefix as a total, which is the exact failure
this decision leaves standing.

### 2. What is omitted, not stubbed

Per the spec's own empty-omitted rule, and unchanged by this plan:

| Omitted | Why |
|---|---|
| Time off card; pending-time-off Attention entry | P6 deferred (owner call 2026-08-10). P7 must omit, not stub, all three P6 touchpoints. |
| Revenue trend, Avg ticket, Unpaid invoices, Top clients by revenue, Quotes won, First-time fix | The six money sections wait for P7b. |

The third P6 touchpoint — the drawer's pending count — is not a P7 file and
needs no change.

### 3. Sequencing: dashboard first, review, then History

Owner call 2026-08-11. Phases A–C are the dashboard and stop at a review
checkpoint; Phase D is History. The two screens share no widgets that P7
changes, so the split costs nothing.

---

## Phase A — the period control

The only genuinely new behaviour in P7. Everything else is presentation or a
new reducer over data already fetched.

**A1. `DashboardPeriod` (`domain/dashboard_period.dart`).** A three-member enum
(`today`, `week`, `month`) with the window arithmetic beside it. Sunday-vs-Monday
is settled: `DashboardAggregator.mondayOf` already owns ISO week start — reuse
it rather than a second convention.

**A2. No range change at all — the periods already fit inside the window.**

The spec says Month and Year must widen the HISTORY half. Once Year is dropped
(Decision 1) **nothing needs widening**, which only became obvious while
writing this plan. `_windowStart` is `mondayOf(now) - 49 days`, so the fetched
window already reaches 49–55 days behind today; the widest surviving period is
the current month, at most 31 days back.

**Corrected during Phase A, by the test that asserts it:** that holds going
BACK but not going FORWARD. The fetched window ends at next Monday, so a whole
calendar-month window runs off the end of the data and silently under-counts
the rest of the month. **All three periods are therefore to-date** — they share
an end (the end of today) and differ only in how far back they start. That is
both what the numbers mean (there are no completed or cancelled jobs in the
future, and a whole-month box would be mostly unlived) and the only shape that
fits the fetched window. `dashboard_period_test.dart` pins the fit in both
directions, which is how the error was caught.

So the period control is a **pure client-side filter over the merged list** —
no new query, no second read path, no exposure to the 1000-doc cap, and the
live listener is untouched by construction rather than by care. Keep it that
way: if a future period does not fit the window, widen the HISTORY half only,
and never the live one.

**A3. The reducers take the window, not the period.** A period-scoped reducer
is handed a resolved `[start, end)` pair and stays a pure function of it. Do
NOT thread a `DashboardPeriod` into the reducers and switch inside them — that
is the `displayStatusAt` mirror shape, and it puts the window rule in two
places. `DashboardPeriod.windowFor(now)` is the one owner.

A period-scoped count must scope through `runsOn`/`runsInRange`, not
`startTime`: the merged list reaches back to `fetchStart`, so a raw `startTime`
test reads a fortnight of past work as in-window.

**A4. Which sections the period actually scopes — the KPI numbers, not the
charts.** Decided while planning, and it needs stating because the alternative
looks tidier and is worse.

- **Scoped:** the summary numbers — completed, cancelled, new clients, busiest
  weekday. These are the "how did we do" figures, and "over what span" is
  exactly the question the control answers.
- **Not scoped: the charts, because each one's span is its subject.** The trend
  chart IS "the last 8 weeks" and the new day chart IS "the next 7 days"; both
  say so in their titles. Re-bucketing them per period would mean inventing a
  granularity for Today (24 hourly bars for a handful of jobs) and would make
  Week and Today render the same chart. A chart whose span is named in its own
  title cannot mislead about the period control.
- **Not scoped: "right now" sections** — hero, Upcoming today, Employee
  workload, Attention. Attention explicitly so: it is the one reducer with no
  range predicate, and clipping it to a period would drop the oldest and most
  neglected work from the list whose entire job is to surface it.

Say this in the code, or a later reader will "fix" the inconsistency.

**A5. The control itself.** A segmented control in the dashboard header, its
selection held by a `StateProvider` beside the other dashboard providers so the
ranges derive from it. New EN+FR ARB keys (`dashboard_periodToday`,
`dashboard_periodWeek`, `dashboard_periodMonth`) with `@key` blocks.

**A6. Tests.** A window test per period (boundaries included/excluded); a
reducer test that a period-scoped count day-scopes a multi-day run; a provider
test that **every fetched range is identical across all three periods** — the
period must never reach the query layer, and that is the regression that
matters; a widget test that switching re-renders.

## Phase B — the new sections and flags

**B1. Jobs booked per day** — 7 bars, over-capacity in red against
`maxJobsPerDay`. New reducer. It must count a multi-day run on **every day it
runs**: scope through `runsOn(...)`, never a `startTime` comparison, or days 2+
vanish and the range stream's fortnight of history reads as today. Capacity is
summed over the active roster's `maxJobsPerDay`; a roster where nobody has one
set (the field defaults to 0) has no capacity line to draw — render the bars
without it rather than showing everything as over capacity.

**B2. New clients → tappable rows.** The count exists; the rows do not. Tapping
lands on the client detail. **Behaviour change, not a no-op:** filter
`if (!client.archived)` beside the existing `createdAt != null` guard in
`newClientDatesProvider`. In Dart, deliberately — a `.where('archived', ...)`
needs an `(archived, createdAt)` composite index and a deploy, and the repo's
"never filter a server page in Dart" rule is about `fetchClientsPage`, where a
shortened page breaks the cursor. This read is a bounded one-shot with no
cursor, so that hazard does not apply.

**B3. Attention — accounts never set up.** Read from
`allUsersStreamProvider`, never `employeesStreamProvider` (which filters to
`status == 'active'`, so the flag would be permanently empty and silently never
fire). Test with `EmployeeRecord.isInvited` — an exact match. Age comes from the
users doc's `createdAt`, which is function-owned and **nullable on legacy
docs**: treat null as unknown and still list the row rather than dropping it.
Tapping lands on the Team roster, where `PendingInviteTile` already owns Reset
password and Remove. No new query, no index, no rules change.

**B4. Attention — availability conflict.** `daysWithBookedWork` already exists
as a pure policy behind `myAvailabilityConflictProvider`
(`settings/application/my_details_providers.dart:112`) — reuse it rather than
re-deriving the overlap. Note the scope difference: that provider answers it for
ONE person against a pending change; the dashboard asks it across the roster
against stored availability.

**B5. Tests.** One per reducer, including the multi-day day-scoping case for B1
and the null-`createdAt` case for B3.

## Phase C — dashboard restyle — **mostly already true**

Presentation only, no new data — and three of the four items turned out to need
no change, which is worth recording so the next reader does not go looking for
work that is done.

**C1. Hero gradient card** — **already shipped.** `dashboard_hero.dart` already
paints a `LinearGradient` behind today's count and the completed / in-progress
split. Nothing to do.
**C2. KPI grid** — built in Phase A as `PeriodSummarySection`. Only tiles with
data; the six money tiles are absent, see Decision 2.
**C3. The chart rule** — bars in their own fixed-height track, value and axis
labels as siblings OUTSIDE it, because labels sharing the flex column silently
clip tall bars. B1's `DailyLoadChart` is built to it explicitly. The existing
`weekly_bar_chart.dart` **already satisfies it structurally**: it is `fl_chart`,
which lays axis titles out in their own reserved regions rather than in the
bars' box, so there is no flex column for a label to steal height from.
Rewriting it would be churn.
**C4.** The existing tour steps still work — `dashboardHero`,
`dashboardUpcoming`, `dashboardWorkload`, `dashboardAttention` are still
wrapped by `tour.stepIf` and their ids are untouched (they are the persisted
tour keys, so renaming one replays or orphans that tour). The new sections
deliberately get no steps: that would mean new ids and ARB keys for a tour the
spec never asked to extend.

> **Review checkpoint — reached 2026-08-11.** Phases A–C complete. `flutter
> analyze` clean, 1879 tests passing (1844 before), `firestore.rules` validates.

## Phase D — History restyle — **BUILT**

The chosen design is `docs/archive/2026-08-11-history-restyle.md` (option B, the
date rail). What follows is what the build actually needed.

**D1.** Year/Crew filters swapped from `MenuAnchor` to `showAdaptiveActionSheet`
— a `CupertinoActionSheet` on iOS. The filtering itself is untouched. Options
are chosen **by index, not by value**: the "All years" row selects null and the
sheet already returns null for a dismissal, so a value-typed sheet could not
tell "cleared" from "cancelled".
**D2.** Quick-filter chips (`HistoryStatusFilter`, one nullable value rather
than two toggles so "neither" and "both" cannot be two spellings of one list),
the single mono count, the sticky month bar, and the date rail. Cancelled was
already dimmed-and-struck by `AppointmentCard(dimWhenCancelled: true)` — no
card change was needed, which is the whole reason B was chosen.
**D3.** Filtering stays the existing bounded Dart-side search
(`historySearchProvider`). **No new server queries** — that is what keeps
History off a composite index.

**D4. The list now drives its own pagination, and that was the real cost.**
A sticky header cannot live inside `PagedListView`, so the rows are built as
`CustomScrollView` slivers and the three things ISP used to own had to be
rebuilt: the prefetch trigger, the new-page spinner/retry footer, and — the one
that bit — **re-requesting the first page after `PagingController.refresh()`,
which only RESETS state and does not fetch.** Without `_requestFirstPage` both
pull-to-refresh and the first-page Retry left the skeleton shimmering forever
with no request in flight. Caught by the existing Retry test hanging on
`pumpAndSettle`.

**D5. Each month is a `SliverMainAxisGroup`, and that is load-bearing.**
Repeated `SliverPersistentHeader(pinned: true)` slivers **stack** — a year of
history would park twelve bars across the top of the screen. A pinned header
bounded by its own group scrolls away with its rows instead. Pinned by a test
that reads the bars actually painted inside the viewport; removing the group
makes it report `['AUGUST 2026', 'JULY 2026']` where it should report one.

**D6. Two things deliberately NOT done.**
- The first-page indicators (skeleton, error, empty) are **not** wrapped in the
  `RefreshIndicator`. `AppEmptyState` carries its own `SingleChildScrollView`,
  so adding one would leave two controllerless primary scrollables under the
  screen's `PrimaryScrollScope` — the documented Scrollbar crash. ISP did not
  scroll those states either, so this is not a regression.
- No per-month counts, ever. See the design doc.

Two things the original spec predates, both to be preserved:

- `AppointmentHistoryView` takes an `isAdmin` and passes it straight through as
  `showActions` (restored 2026-08-08). History is where `done`/`cancelled` jobs
  live, so it is the one screen an admin looks for a completed job's edit
  button on. Do not re-hardcode it closed.
- The closed-job **collapsed green treatment is calendar-agenda-only by
  design.** History keeps the plain full-height `AppointmentCard`. Don't
  "unify" them: the agenda sinks closed work because it answers *what's left
  today*, and History is a record where everything is closed.

---

## Risks

| Risk | Mitigation |
|---|---|
| A period reaches the query layer and re-creates the 2026-08-08 truncation | A2 makes the control a pure in-memory filter; A6 pins every range as identical across periods |
| A new reducer compares `startTime` and drops days 2+ of a run | Every new reducer scopes through `runsOn`/`sliceFor`; B5 tests the multi-day case |
| Month still exceeds the 1000 cap for a very high-volume business | ~420 docs at 14 jobs/day leaves a wide margin; the repository already WARNs at the cap |
| A dropped or renamed tour step id replays or orphans the dashboard tour | C4 |
