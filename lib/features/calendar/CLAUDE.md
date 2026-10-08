# Calendar UI (lib/features/calendar/)

Pure-Flutter rendering rules for the calendar surfaces, with no `functions/` hand-mirror. Rules with a server-side twin (status allowlist, multi-day spans, all-day blocks, personal jobs and time off, photos, `AppointmentDaySlice`, range-stream re-scoping) live in `.claude/rules/appointments.md`, which also loads from `functions/`.

## Month grid and pager

- Build the month view from `CalendarMonthGrid` + `CalendarMonthPager`; `table_calendar` is deleted. (ADR-0151)
- Derive the rows (4, 5 or 6) from `monthGridRowCount`, never a constant (a fixed count trails a blank week or drops a month's end). Size with `CalendarMonthGrid.heightFor` (a required `rows`) from `rowsFor(context, month)`; the pager animates to the month in view and wraps each page in `ClipRect` + top-aligned `OverflowBox` so a taller month dragged in doesn't overflow. (ADR-0151)
- Keep `AppointmentDateRange.visibleMonth`'s overscan at ±7 days (`_gridOverscanDays`): it is sized to the row rule (at most 6 off-month days a side), so a fixed row count would leave edge cells dotless; `month_grid_overscan_test.dart` pins the coupling. (ADR-0151)
- Resolve the locale week start through `CalendarMonthGrid.weekStartOf(context)`, never a re-inlined `weekStartForLocale(Localizations.localeOf(...))`; `weekStartForLocale` stays memoized per locale string (it builds a `DateFormat`, asked on every rebuild). (ADR-0151)
- Read `today` from `currentDayProvider`, never `DateTime.now()`, or the circle sticks on yesterday across midnight.
- Make paging select: a month swipe or the month picker selects the 1st; a swipe on the collapsed week strip pages a week and selects its first day — the agenda must describe the grid above it. Fetch with `AppointmentDateRange.forCalendar` (month grid ∪ selected day), never the month alone, or a selection outside it reads "0 jobs".
- Take a single-day window only from `AppointmentDateRange.forDay(day)` — calendar arithmetic (`DateTime(y, m, d + 1)`), never `add(Duration(days: 1))`, which mis-buckets late jobs on DST days. Every other surface reuses a range another listener already holds, never a fresh `forDay` — `appointmentsInRangeProvider` keys on range VALUE, so a new range forks a second live query. (ADR-0154)

## Day cells and dots

- Render off-month cells with a faint number AND their crew dots, untappable and out of the semantics tree. Keep dots on selected and today cells too — the selection circle fills only the number. (ADR-0152)
- Count JOBS, not people: `dayJobDotColors` (`calendar/domain/appointment_crew.dart`) emits one entry per job in list order, capped at 3 (the week strip passes `max: 1`), each the job's first colour-resolvable assignee. Keep the `null` entry and paint it `palette.textFaint`, or a day of unassigned work reads empty. (ADR-0152)
- Filter dotted jobs only through `dottedJobsOn` (same file; `countsAsWork` — drops cancelled and time off, keeps `done`), run BEFORE the cap so a cancellation can't cost a live job its dot. Time off (`AppointmentRecord.isTimeOff`) is never counted, always shown in the agenda. (ADR-0152)
- Feed `CalendarDayCell`'s semantics count from `dottedJobsOn(...).length` (`countFor`, `main_calendar_screen.dart`), never the raw slice count — the dots are colour-only, so the label carries their meaning. The count stays UNCAPPED; only the filter is shared. (ADR-0152)
- Decorate a day token only through `calendarDayCircleDecoration` (`widgets/views/calendar_day_circle.dart`): today an `onSurface` RING, selection a filled circle, selection wins. Its three callers (`CalendarDayCell`, the week strip, the form's `InlineMonthCalendar`) keep their own sizes and number colour; pass `fill` for a tint (the picker's other-end-of-run marker). (ADR-0153)
- Render `InlineMonthCalendar` from the same `month_grid.dart` helpers and `weekStartOf` as the screen, with its long-date `DateFormat` hoisted out of the 42 cells (it rebuilds on every tap and form change). (ADR-0153)

## Portrait layout and collapse

- Keep portrait as TWO scroll areas, so reading down the day never moves the grid: the grid fixed above, the agenda in its own `CustomScrollView` with its own `ScrollController` — explicitly controlled, so not primary and off the app-wide `Scrollbar`'s single controller. (ADR-0155)
- Collapse only through `CollapseHandle` (`widgets/views/collapse_handle.dart`): divider drag plus tap-toggle, carrying the Hide/Show calendar tooltip the widget tests find it by. `CalendarCollapse` (`domain/collapse_state.dart`) banks drag past `dragThreshold` (24px); only `onDragDelta` returns a bool ("flag flipped", so the caller rebuilds per transition), and `toggle()` stays `void`. Collapse is portrait-only (`_splitCalendar` short-circuits the strip). (ADR-0155)
- Never let the grid scroll: its `SingleChildScrollView` has `NeverScrollableScrollPhysics`, pure overflow protection. The handle is the ONLY thing that moves it; don't restore scrollable physics to "fix" a clipped month. (ADR-0155)
- Bound that viewport with a `ConstrainedBox` at `_kMaxGridShare` (0.7) of a `LayoutBuilder`'s `constraints.maxHeight` (`_portraitContent`), NEVER a `Flexible` — as a flex-1 sibling of the agenda's `Expanded` it caps the grid at half the pane and silently clips six-week months. `main_calendar_screen_test.dart` pins 390x844 WITH real insets and 2x text at 375x667; raising `_kMaxGridShare` or growing the handle or agenda header spends the overflow margin. (ADR-0155)

## Header

- Head the screen with `CalendarHeaderBlock`, the one screen with no `AppTopBar` (`.claude/rules/frontend.md`): it sets its own `AnnotatedRegion` from the surface colour (`overlayStyleFor`), never theme brightness, and stacks title and controls under `context.isCompact`. (ADR-0156)
- Measure the month label, never gate it on text scale: the screen passes `monthLabel` and `monthLabelShort` and `_MonthRow` takes the short one when the full name won't fit (`measureTextWidth`) — the in-app XL scale is exactly 1.4, which `isCompact`'s `> 1.4` misses. The semantics label always speaks the full month. (ADR-0156)

## Agenda: closed jobs and counts

- Sink CLOSED jobs to the bottom of the day in the calendar agenda only, via `_agendaOrder` (stored-status rule: `.claude/rules/appointments.md`); done and cancelled both sink. The day route, dashboard, employee TODAY panel and client job history keep their own sort and the full card. (ADR-0157)
- Collapse a closed row only via `AppointmentCard(collapseWhenClosed: true)`, passed ONLY by `AgendaSliverList`: gate only the success tint on `isDone`; crew avatars and the time on its own line apply to every closed row. Keep the time out of a `Row` beside the client (equal flex ellipsised `Day N of M`), and keep that counter on collapsed rows — a closed job renders on every day of its run. (ADR-0157)
- Don't lower `_kClosedMinHeight` (48): the row is a full `InkWell` that must clear Material's minimum, and as a `minHeight` content raises it without an edit. (ADR-0157)
- Leave the light-theme collapsed-Done contrast defect unless asked; a fix tints the CARD, never `StatusPill`. (ADR-0157)
- Draw one `_ClosedRule` (`calendar_closedCount`, "Done") at `firstClosedIndex`, counting the tail through `countsAsWork` (never `length - index`), and suppress it at zero. Keep the closed jobs one contiguous tail; don't reorder at the call site. (ADR-0158)
- Count the header (`_jobLabel`, `main_calendar_screen.dart`, `3 JOBS · 1 DONE`) through `countsAsWork` (owner: `.claude/rules/appointments.md`), so header, rule and dots agree. Filter only counts; cancelled and time-off cards still render. (ADR-0158)

## AppointmentCard

- Use `AppointmentCard` as the ONE appointment card (calendar agenda, day route, client job history, both dashboard sections, paginated history). Feed `crew:` from `crewFor(appointment, colorMap:, nameMap:)`, which falls back to the record's `employeeNames` without a `nameMap`. (ADR-0159)
- Band EVERY assignee in the crew bar (`_crewBarDecoration`): one flat colour, or a hard-stopped `LinearGradient`; `textFaint` only with no crew — never grey for multi-crew, which reads as unassigned. Cap bands and avatars at the same `_kMaxCrewShown` (4). (ADR-0159)
- Render the meta line as an overlapped avatar stack (`_CrewAvatars`, one per assignee) then the client name; `_crewLabel`/`calendar_crewPlusOthers` are only the fallback with no client name. Cancelled dims to 0.6. (ADR-0159)
- Never put `LayoutBuilder`, `AutoSizeText` or `FittedBox` under the card — its `IntrinsicHeight` (stretching the crew bar) needs intrinsics they can't report; `_CrewAvatars` computes its own width. (ADR-0159)

## Time off and non-working rows

- Render time off as `_DayOffStrip` with one layout: the headline is the typed reason, else the `<name> is off` sentence; only the caption is conditional; never fill both slots from one string. (ADR-0160)
- Resolve the reason only through `dayOffReason` (`calendar/domain/day_off_reason.dart`), which returns null with no subject (`hasSubject` false — the title is already the sentence's subject) and never promotes the saved `calendar_personal` placeholder to the headline; match it against EVERY locale (`personalTitlePlaceholders`) since the author's locale wrote it — a new locale joins that set. `_DayOffBody` (`details_view_body.dart`) uses the same helper. (ADR-0160)
- Keep the strip's dashed crew rail, and keep the `colorScheme.outline` border in the shared `nonWorkingTimeDecoration` — `neutralContainer` equals `scaffoldBackgroundColor` in light, so without it neither the day-off nor the holiday row is visible. (ADR-0160)
- Share only the ground with the holiday row (`widgets/cards/non_working_time_row.dart`: `nonWorkingTimeDecoration`, `NonWorkingTimeText`, `kNonWorkingRowMinHeight`, `kNonWorkingRailWidth`); each row keeps its own layout. Build any new "not work" row on the same four. (ADR-0160)

## Holidays

- Compute holidays in `domain/holidays.dart` (Québec statutory, Greek Orthodox Easter trio, CCQ construction shutdown) by pure arithmetic — never a bundled table, which silently stops after its last year. Display only: nothing is dimmed, warned or blocked. (ADR-0161)
- Mark a holiday only through `calendarDayTokenWithRule` (`calendar_day_circle.dart`), which paints a 2px rule 4px above the token's bottom and RESOLVES its own colour, so no surface can render a token and forget the marker. Never put it in the token's `fill` (selection wins that) or recolour the day number. `holidayHueFor` is the bare lookup (the agenda rail); `holidayRuleColorFor` adds the states. All three `calendarDayCircleDecoration` callers take it. (ADR-0161)
- Whiten the rule to `onPrimary` on a selected day (the agenda row below carries the hue); pass `keepHueWhenSelected` to LIFT it instead only where no agenda row sits beneath — `InlineMonthCalendar` alone. The lift (`_kSelectedHueLift`) clears 3:1 (pinned) and no further; off-month alpha is 0.45 (only "faded" is pinned). (ADR-0161)
- Keep the hues as three plain `AppPalette` fields (`holidayStatutory`/`holidayOrthodox`/`holidayConstruction`), never a `theme.brightness` branch or a `HolidaySet`-keyed map (`lerp` would snap it mid-animation). Pick hues in `crewPalette`'s gaps (blue is selection, red is cancelled, and a crew dot sits ~7px below, so a shared hue twins) and check a dark one against `_darkCrewOverride`'s VALUES — never `darkAmber` for construction. (ADR-0161)
- Treat `holidaysOn` as a LIST: `HolidaySet`'s declaration order is the precedence (`markerSetFrom`, statutory wins), never "first match"; the agenda renders every row. `CalendarDayCell` resolves `holidaysOn` ONCE for both its semantics label (which names the holiday) and `markerSetFrom`. (ADR-0162)
- Render `HolidayAgendaRow` (no avatar, rail = set hue) from inside `AgendaSliverList`, so the portrait calendar and the split `EventList` can't disagree; its REQUIRED `day` must be the day its `events` were resolved for — pass `_selectedDay ?? _focusedDay`, never the raw nullable. It renders above the skeleton and empty state (no read). The week agenda's `weekAgendaSlivers` instead places it under each day bar via `AgendaSliverList.holidayRows`; its `inWeek: true` lists skip it. The tag carries statutory vs observance; the construction row has no caption. (ADR-0162)
- Keep the three date traps pinned in `holidays_test.dart`: Patriotes is the Monday STRICTLY before May 25; Fête nationale and Canada Day BOTH move to the next day when they fall on a Sunday; the CCQ shutdown starts the Sunday PRECEDING July's last Saturday. (ADR-0162)
