# Dashboard redesign — Today | Trends

**Status: DESIGN PICKED 2026-09-12 (Option B). NOT STARTED — no code, no
implementation plan yet.** The owner gives the build go-ahead separately.

Mockup (chosen design, private artifact):
https://claude.ai/code/artifact/9ee3a908-df11-4151-b536-e91753902123
(The page now shows only Option B: the busy Today tab, a quiet-morning Today tab
and the Trends tab, light and dark.)

**Picked: Option B, Today | Trends.** Not taken: Option A, "Attention first",
which kept one reordered scroll, and Option C, "Dispatch board", a per-tech
7:00–18:00 timeline.

App-only. Nothing here touches `functions/`, the rules or the indexes, so there
is no deploy step.

---

## Why

- **Needs attention is the last of eight sections**, below every chart, so the
  part the admin has to act on is the part they scroll to last.
- **The blue gradient hero** (`DashboardHero`) is the last solid-blue block
  left after the Fresh header (`docs/archive/2026-09-11-fresh-header-redesign.md`) removed
  the blue bar.
- **Two different questions share one scroll.** "What is happening now" (hero,
  Next up, workload, Attention) and "how have we done" (KPIs, charts, new
  clients) are mixed together, and the period switch changes only the four KPI
  tiles.
- **Full `AppointmentCard`s** in Next up and the attention groups mean five
  jobs take up a whole screen.

## Decisions made in the session

| Question | Answer |
|---|---|
| Layout | **Option B**: a Today / Trends switch under the title. |
| Unassigned jobs | **They never happen** (owner, 2026-09-12). Remove `TodayOps.unassignedCount`, the hero's `_UnassignedBanner` and the `dashboard_unassignedCount` ARB key. Show no unassigned state anywhere. |

## The design

### Header

Fresh header as on every other screen (back chevron, Calendar pill, menu,
26 px "Dashboard" title). Under the title is a full-width segmented control,
**Today | Trends**, using the same painted segmented style as the Clients chips
row. The screen always opens on Today.

### Today tab

1. **On site now · N.** One row per in-progress job today: the tech's avatar,
   the job title, the tech's first name and client, "ends HH:MM", and a thin
   progress bar showing how far `now` is through the job's time window for
   today (a `AppointmentDaySlice` window, so a multi-day run is judged by
   today's window). The label's right side reads "14 today · 2 done". An
   overdue job today adds a footer row that opens it.
   - **Quiet state:** before anything is in progress, one row: "Nobody is on
     site yet", with "First job starts at 7:00 · Sami" under it.
2. **Needs attention.** A row of chips, one per non-empty group, in severity
   order: Not closed (`overdueOpen`), Pending < 48 h (`pendingSoon`), Day off
   (`availabilityConflicts`), Not set up (`neverSetUp`). Each chip shows its
   count. The first non-empty group starts selected, and its rows show in a
   card under the chips (compact job rows or person rows, same 5-row cap and
   "N more" as today's `_FlagGroup.rowLimit`).
   - **All-clear state:** the chips are replaced by one line,
     `dashboard_allClear`, with the success check.
3. **Next up.** Compact rows (time column, title, client, avatar stack) under a
   red "now" rule, 4 rows, then "N more today" which opens the Calendar on
   today.
4. **Crew today.** A 2 × 2 grid of tiles: avatar, first name, today's jobs as
   pips against `maxJobsPerDay`, and "3/4". **When `maxJobsPerDay` is 0 (not
   set) the tile shows the count with no pips**, the same "0 means not
   configured" rule `DayLoad.capacity` already follows.

### Trends tab

1. **Period switch** (Today / Week / Month), which now scopes the headline and
   the three numbers under it.
2. **Headline card:** completed for the period in large mono numbers, "of N
   booked" beside it, the 8-week completed line under it (captioned "Completed
   per week · last 8 weeks", because the chart does not move with the period),
   and a three-column row: Booked, Cancelled, New clients.
3. **Jobs booked per day** (`DailyLoadSection`), unchanged in meaning.
4. **Completed vs cancelled, last 8 weeks** (`BusinessTrendsSection`), with the
   busiest day moved into its subtitle.
5. **New clients, last 8 weeks**, with a weekly sparkline in the label and the
   newest three rows, then "N more".

## What it costs

- **No new reads.** Everything above is already inside `dashboardRecordsProvider`.
  The changes are in the reducers: "On site now" needs today's in-progress
  slices (not just `TodayOps.upcoming`, which is pending-only and capped at
  `upcomingLimit` 5), and "N more today" needs the uncapped pending count.
- **Removed:** `DashboardHero` and its status bar and legend, `unassignedCount`,
  `dashboard_unassignedCount`.
- **Tour:** the four `TourStepId.dashboard*` ids keep their members, so no
  storage key changes and nobody replays. `dashboardHero` moves to On site now,
  `dashboardAttention` to the chips row, `dashboardUpcoming` and
  `dashboardWorkload` stay on their sections. **Their copy has to be rewritten**
  (a step's copy is part of the surface it points at). All four targets are on
  the Today tab, which is the tab the screen opens on.

## Open questions for the build

- Is the Today period still needed on Trends, now that Today's numbers sit on
  the Today tab? Dropping it would leave Week / Month.
- On a wide / landscape layout (`context.isWide`), should the two tabs render
  side by side with no switch?
- Is switching tabs an analytics event? The period change already logs one, and
  any new parameter has to be declared in `AnalyticsParams.allParams`.
