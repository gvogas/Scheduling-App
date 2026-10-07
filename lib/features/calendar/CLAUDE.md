# Calendar UI (lib/features/calendar/)

Rendering rules for the calendar surfaces. These moved out of the root
`CLAUDE.md` on 2026-08-14 because they are pure Flutter UI with no
`functions/` hand-mirror, so they only need to load when working here.

Everything with a server-side twin — the appointment status allowlist,
multi-day spans, all-day blocks, personal jobs, the photo subcollection,
`AppointmentDaySlice` and the range-stream re-scoping rule — deliberately
STAYS in the root `CLAUDE.md`, because those are reachable from
`functions/` where this file does not load.

- **Calendar (rebuilt in P2, 2026-07-30):** `table_calendar` is **deleted**;
  the month view is our own `CalendarMonthGrid` + `CalendarMonthPager`. It
  renders **only the weeks the month actually occupies** — 4, 5 or 6 rows from
  `monthGridRowCount` (owner call, 2026-07-31: a fixed 6 trailed a week of
  nothing but off-month cells). A fixed **5** is still wrong the other way and
  drops the end of months like August 2026, so the row count must stay derived,
  never a constant. Week start comes from the locale (`weekStartForLocale`,
  memoized per locale string — it builds a `DateFormat` just to read its
  symbols, and the grid, pager and week strip all ask on every calendar
  rebuild). Resolve it from a widget through `CalendarMonthGrid.weekStartOf(context)`
  rather than re-inlining `weekStartForLocale(Localizations.localeOf(...))`.
  Because rows vary, `CalendarMonthGrid.heightFor` takes a **required `rows`**
  (use `rowsFor(context, month)`), the pager animates its viewport to the month
  in view, and each page is wrapped in `ClipRect` + top-aligned `OverflowBox`
  so a taller month being dragged in doesn't overflow before the height
  settles. Off-month cells render a **faint day number AND their
  crew dots** but stay untappable and out of the semantics tree: the design says
  "blank, Ink 15, not tappable" while the program spec widened the fetch range
  precisely so trailing days aren't dotless, and dots-plus-faint-number is what
  reconciles the two (owner-confirmed). **The crew dots also survive selection**
  (owner call, 2026-07-31): the selection circle fills the day number only and
  the dot row sits below it on the plain cell background, so suppressing them
  there made the day being looked at the one day whose crew was invisible.
  Every cell that has crew shows it — off-month, selected, today, all of them.
  **A day's dots count JOBS, not distinct people** (owner call, 2026-08-04, which
  reversed the P2 rule): `dayJobDotColors` (`calendar/domain/appointment_crew.dart`)
  emits one entry per job in list order, capped at 3, each carrying that job's
  first colour-resolvable assignee. The dots answer "how busy is this day", so
  two jobs for the same person are two dots. It returns `List<Color?>` and a
  **null entry is load-bearing, not a gap**: a job whose crew resolves to no
  colour still gets a dot, painted `palette.textFaint` — the same neutral the
  card's crew bar uses for an unassigned job. The old per-assignee version
  simply skipped those, so a day holding only unassigned work read as empty.
  The week strip renders the same list capped at 1, for the same reason.
  **A CANCELLED job gets no dot** (owner call, 2026-08-17): the dots answer
  "how busy is this day", and a called-off visit is work that is not
  happening, so a day holding only a cancellation has to read as free. `done`
  still dots — that work happened. The filter has one owner, `dottedJobsOn`
  (same file), and `dayJobDotColors` runs it BEFORE the cap, so a cancellation
  early in the day can't cost a live job its dot. **`CalendarDayCell`'s
  semantics count must use the same predicate** — the label speaks the dots'
  meaning ("the dots are colour-only, so the count carries their meaning
  instead"), so `countFor` in `main_calendar_screen.dart` reads
  `dottedJobsOn(...).length`, not the raw slice count, or a screen reader
  describes dots nobody can see. Note the count stays UNCAPPED while the dots
  cap at 3; only the filter is shared. **`dottedJobsOn` drops TIME OFF for the
  same reason read from the other end** (2026-08-24): a day off is not work at
  all, so a week of holiday must not paint as a fortnight of booked days. Its
  card still renders in the agenda below — the split is "never counted, always
  shown", and its one owner is `AppointmentRecord.isTimeOff`.
  `today` always comes from
  `currentDayProvider`, never `DateTime.now()`, or the circle sticks on
  yesterday in an app left open across midnight.
  **TODAY IS A RING AND SELECTION IS A FILLED CIRCLE, and that rule has ONE
  owner: `calendarDayCircleDecoration`** (`widgets/views/calendar_day_circle.dart`,
  owner call 2026-08-14 — today used to be a blue NUMBER, which was also the
  picker/field accent, so "today" and "the value you picked" spoke the same
  language). The ring is `onSurface`, so it survives both themes where a
  literal white vanishes on the light one; selection wins, since a filled
  circle under a ring is noise. Three widgets render a day token —
  `CalendarDayCell`, the week strip and the form's `InlineMonthCalendar` — and
  the rule had a hand-written copy in each, two carrying a comment asserting
  they matched the third. They had already drifted on the gate condition.
  Sizes and the number colour stay per-cell (they legitimately differ, and only
  the grid has a dot row); pass a `fill` for a tint like the picker's
  other-end-of-the-run marker.
  **The form's date picker is `InlineMonthCalendar`, and it renders from the
  same `month_grid.dart` helpers the calendar screen uses** — so the two can
  never disagree about where a day sits or where the week starts. It resolves
  the week start through `CalendarMonthGrid.weekStartOf(context)` like every
  other widget, and hoists its long-date `DateFormat` out of the 42 cells: the
  panel rebuilds on every day tap and on any other form change while it is
  open.
  **`AppointmentDateRange.visibleMonth` overscans ±7 days** (narrowed from ±14
  on 2026-08-13). The variable-row grid trails at most 6 off-month days on each
  side, so ±7 clears the worst case by one — where ±14 was a superset of every
  grid shape including the fixed-6-row one P2 replaced, and cost a fortnight of
  documents per month view on top of the fortnight `fetchStart` already adds.
  That saving buys a coupling: the window is now sized to the row rule, so
  bringing back a fixed row count leaves the edge cells dotless.
  **`month_grid_overscan_test.dart` is that coupling made to fail loudly** — it
  walks every month across a leap cycle at all seven week starts and asserts
  the fetch window contains every rendered cell. Change the row rule and it
  breaks there rather than in somebody's empty crew dots.
  **A single-day window has ONE owner: `AppointmentDateRange.forDay(day)`.**
  It is **calendar** arithmetic (`DateTime(y, m, d + 1)`), never
  `add(Duration(days: 1))`, which lands an hour off real midnight on the two
  DST-shift days. Two costs, not one: it mis-buckets a late-evening job, AND
  because `appointmentsInRangeProvider` is keyed by range **value**, an hour of
  drift stops matching the day-range another surface already holds open and
  forks a second live Firestore query for the same day. That is why
  `todayRangeProvider`, the drawer's job count, the day route and
  `forCalendar`'s selected-day leg all resolve through the one factory rather
  than re-deriving the pair — it was hand-copied at four sites, two of which
  cited each other as the authority.
  **Portrait is TWO scroll areas** (owner call, 2026-07-31): the grid is FIXED
  above the agenda, and the jobs have their own `CustomScrollView`, so reading
  down the day never moves the calendar. Collapse is a **drag on the divider
  between them** — `CollapseHandle` (`widgets/views/collapse_handle.dart`),
  which is also a tap-toggle and carries the Hide/Show calendar tooltip that
  the widget tests find it by.
  `CalendarCollapse` (`domain/collapse_state.dart`) accumulates drag deltas past
  **24px**, resetting on a direction reversal and on `endDrag` so two half-drags
  don't add up. Only `onDragDelta` returns a bool (it means "the flag flipped",
  so the caller rebuilds on a transition and not per gesture frame); `toggle()`
  is `void` — it always flips, so a bool there would be a constant nobody reads.
  The agenda's own `ScrollController` is load-bearing for a second reason: an
  explicitly-controlled scrollable is not the *primary* one, which is what keeps
  it and the grid off the app-wide `Scrollbar`'s single controller. The old
  shared-viewport version needed a derived
  `gridHeight − stripHeight` spacer to hold the extent the grid vacated; with two
  viewports there is no vacated extent, and the spacer is gone. **The grid does
  not scroll at all** (owner call, 2026-07-31): it sits in a
  `SingleChildScrollView` whose physics are `NeverScrollableScrollPhysics`, so
  the viewport is pure overflow protection — a short viewport (small phone,
  large text scale) shrinks the grid instead of running the column past the
  bottom, and at normal heights it shrink-wraps and is inert. The handle is the
  ONLY thing that moves the grid; don't restore scrollable physics to "fix" a
  clipped month.
  **That viewport is bounded by a `ConstrainedBox` against the pane, NEVER by a
  `Flexible`** (2026-08-31). It was `Flexible`, which made it a flex-1 sibling
  of the agenda's `Expanded` — and `RenderFlex` splits the free space evenly
  between two equal flex factors, so the grid could never exceed HALF the pane
  no matter how tall the month was. A six-week month wants ~334px at 1.0 scale
  where half an iPhone 15's pane is ~326, so its last week was quietly clipped
  by ~11px (99px on an SE), and only on the 4 or 5 months a year that need six
  rows. Nothing overflowed and nothing logged, because the never-scrolling
  viewport is exactly the thing that absorbs it. `_portraitContent` therefore
  wraps the column in a `LayoutBuilder` and caps the grid at `_kMaxGridShare`
  (0.7) of `constraints.maxHeight`: the grid takes the height its month asks
  for, and the cap only bites at large text scales, where clipping is still the
  accepted fallback. Don't hand the grid a flex share again — a loose
  `Flexible` cannot express "natural height, capped", because leftover space a
  loose child declines goes to `MainAxisAlignment`, not to the `Expanded`
  beside it. `main_calendar_screen_test.dart` pins it, and it pins it at a
  390x844 viewport WITH real safe-area insets: the bare 412x915 harness has
  ~81px more pane and passes either way.
  **The trade is that the COLUMN can now overflow where the flex share could
  not.** A non-flex child cannot be squeezed by the agenda, so grid + handle +
  header can exceed a short enough pane and overflow rather than clip — the one
  thing the old shape ruled out by construction. Measured: it holds at 375x667
  (the smallest pane that can run the iOS 18 floor) even at 3x text, and
  overflows by ~5px at 320x568, which no supported device is. That margin is
  the whole safety story, so a second test pins it at 2x text on the 375x667
  pane; raising `_kMaxGridShare` or growing the handle or the agenda header
  spends it.
  **Collapse is portrait-only** — `_splitCalendar` short-circuits the strip.
  **Paging selects.** A month swipe (or the month picker) lands on the 1st and
  SELECTS it, and a swipe on the collapsed week strip pages one week and selects
  that week's first day — the agenda must always describe the grid above it.
  That is also why the fetch window is `AppointmentDateRange.forCalendar`
  (month grid ∪ selected day) rather than the month alone: any path that leaves
  a selection outside the visible month drops its jobs from the fetch, and the
  agenda then reports "0 jobs" for a day that has some.
  The calendar is the **one screen with no `AppTopBar`** (see the frontend rule):
  `CalendarHeaderBlock` replaces it, and therefore must set the system overlay
  style itself via `AnnotatedRegion`, choosing icon brightness from the surface
  colour rather than the theme brightness. Its title and controls **stack under
  `context.isCompact`**. The month name itself is **measured, not gated**: the
  screen passes both `monthLabel` and `monthLabelShort` (`DateFormat.MMMM` /
  `.MMM`) and `_MonthRow` lays out the row, subtracts the year + chevron, and
  takes the abbreviation when the full name won't fit. Don't "simplify" that
  back to a text-scale threshold — the in-app XL setting is **exactly 1.4**, so
  the `isCompact` gate (`> 1.4`) missed it entirely, and the OS scaler, the
  device width and the locale's month lengths all move independently. The
  semantics label always speaks the full month. Note the widget test asserts
  against **viewport width**, not a scale: the test font is far wider per glyph
  than the shipped one.
- **The calendar agenda sinks CLOSED jobs to the bottom of the day, and only
  the calendar does** (2026-08-08). `_agendaOrder` in `appointment_day_slice.dart`
  gained a first tier — open before closed — above the existing all-day and
  window-start tiers, which still apply *within* the closed block. It reads the
  STORED status through **`AppointmentRecord.isClosed`**, never `displayStatus`,
  so the comparator stays clock-free like the rest of that module; `isClosed` is
  the model-layer mirror of `AppointmentStatus.isTerminal` and exists precisely
  so a pure module can ask without pulling Material in through `status_chip.dart`
  (it is also the one owner of the `done`/`completed`/`cancelled` triple —
  `displayStatusAt` calls it rather than re-spelling it). Both terminal states
  sink: a cancelled visit is as done with as a completed one.
  A closed job then renders in the **collapsed** treatment —
  `AppointmentCard(collapseWhenClosed: true)`, opt-in and passed ONLY by
  `AgendaSliverList`: the success tint for `done`, the crew avatars, and the
  time on its own line above them. **`_kClosedMinHeight` (48) is
  load-bearing, not belt-and-braces** — the row is still a full `InkWell`
  opening the same sheet, so it must clear Material's minimum; it is a
  `minHeight`, so content raises the row naturally and the constant needs no
  edit. **Don't lower it.**
  **This REVERSES part of the 2026-08-08 collapse design** (owner call,
  2026-09-11, option B). The row used to drop the avatar stack and put the time
  in a `Row` beside the client, landing near 64px against a full card's ~110 —
  and the whole row then read as *shrunken* rather than as finished, which is
  what got reported. It now lands near 90: still visibly shorter, so the
  collapse keeps doing its job, but no longer half-height. Rejected: dropping
  `collapseWhenClosed` altogether (true parity, but finished work takes full
  height again, which is the thing the collapse prevents) and raising the
  padding alone (the row stays visibly shorter, so it likely would not resolve
  the complaint).
  **Splitting the time onto its own line also fixed a real squeeze**, which is
  why it is not cosmetic: the old `Row` gave `Flexible(time)` and
  `Expanded(label)` equal flex, so `RenderFlex` split the width evenly and the
  time was capped at HALF the row even when the client name was short — so a
  multi-day run's `"9:00 AM – 5:00 PM · Day 3 of 5"` was ellipsised on exactly
  the rows this file says must keep the `Day N of M` counter.
  **CANCELLED rows take the restoration too** (same owner call): only the
  *tint* is gated on `isDone`, so the avatars and the time line apply to every
  closed row. The alternative — gating on `isDone` — makes cancelled the odd
  row out, visibly shorter than its neighbours inside one block.
  **A light-mode contrast defect on this row is KNOWN and deliberately
  unfixed**: `successContainer` is both the collapsed-Done card tint and
  `StatusChip`'s "Complete" fill, and in light theme both resolve to
  `AppColors.greenFill` — contrast 1.00, so the pill's capsule disappears and
  only its text remains. Dark double-composites at 16% alpha, so the capsule
  stays faintly visible, which is why this is light-only and was never caught.
  (Second collision on the same constant: light `secondaryContainer` is ALSO
  `greenFill`, so a selected card and a collapsed Done card are the same
  colour.) If it is ever taken, the fix is to tint the CARD with something that
  is not the chip's own fill — never to touch `StatusPill`, which is shared by
  the detail header, the day-off strip, History's filter chips and
  `UserStatusChip`. The **multi-day counter
  stays** on a collapsed row (deviating from the approved mockup, deliberately):
  a closed job renders on every day of its run, so without "Day 3 of 5" those
  rows are indistinguishable. `AgendaSliverList` emits one `_ClosedRule`
  (`calendar_closedCount`, which reads **"Done"** — owner call 2026-08-08,
  reversing the earlier "Closed"; a cancelled visit sinks into the same block
  and is counted by it, so the label is deliberately looser than the set) at
  `firstClosedIndex` — and the count is deliberately NOT `length - index`: it
  re-filters the closed tail through `countsAsWork`, so a cancelled visit and a
  completed day off sink into the block and are rendered there without being
  counted. The sort still has to keep the closed jobs one contiguous tail, so
  don't reorder them at the call site. **The agenda header's count answers the same question and
  must use the same predicate**: `_jobLabel` (`main_calendar_screen.dart`)
  appends `· 1 DONE` to `3 JOBS`, and BOTH sides filter through
  **`countsAsWork`** (`appointment_day_slice.dart`) so the header, the rule
  drawn over that block and the month grid's dots can never disagree about what
  a job is. **Time off and CANCELLED jobs are counted on neither side** — a day
  whose only entry is either reads `0 JOBS` with that card listed under it;
  only the COUNT is filtered, the cards are not.
  **Cancelled dropped 2026-08-25 (owner call), reversing the `isClosed` tail.**
  It read `1 JOB · 1 DONE` for a day holding one called-off visit, which is
  wrong twice — a cancelled job is not a job on the day, and it is certainly
  not DONE — and it put the header at odds with the dots, which have dropped
  cancelled since 2026-08-17, so the same day showed no dot beside a full job
  count. `countsAsWork` ("not cancelled, not time off") is now the ONE owner of
  that predicate: `countsAsLoadOn` is it plus `runsOn`, and `dottedJobsOn`
  filters by it. There were FOUR spellings before, and the header's was the odd
  one out. The DONE tail counts genuinely finished jobs only, and **the
  `Done · N` rule is suppressed entirely when its count would be zero** —
  cancelled cards still sink to the tail and render there, so a day of nothing
  but cancellations would otherwise draw `Done · 0`. Everywhere else (day route, dashboard, employee TODAY panel,
  client job history) keeps its own sort and the plain full-height card.
- **`AppointmentCard` is the ONE appointment card** — calendar agenda, day
  route, client job history, both dashboard sections and the paginated history
  list (`AppointmentTile` is deleted, along with `colorFromMap` and
  `resolveAssigneeNames`). It takes `crew: List<AppointmentCrew>` from
  `crewFor(appointment, colorMap:, nameMap:)`; without a `nameMap` that falls
  back to the record's denormalized `employeeNames`, which is what the history
  and client surfaces already showed. **The crew bar bands EVERY assignee**
  (`_crewBarDecoration`, up to `_kMaxCrewShown` = 4 — the SAME cap the avatar
  stack uses, deliberately, so the bands and the faces never disagree on how
  much of the crew the card shows): a flat colour for one,
  a hard-stopped `LinearGradient` of each crew colour for more (owner call,
  2026-07-31 — it followed the first assignee alone before that, and the
  pre-redesign grey-for-multi-crew is doubly wrong: grey reads as
  *unassigned*). Only a job with no crew at all is `textFaint`. The meta line
  is an **overlapped avatar stack — one avatar per assignee — followed by the
  client name** (owner call, 2026-07-31; it was a single avatar plus the text
  `Theo +1 · Client`, and `calendar_crewAndClient` is deleted). `_CrewAvatars`
  computes its own width rather than laying out, because of the
  `IntrinsicHeight` rule below; `_crewLabel`/`calendar_crewPlusOthers` survive
  only as the fallback text for a record with no client name to show. `alwaysShowChip` is **gone**, not ported
  (every call site passed `true`); cancelled dims to **0.6**, not 0.75. The card
  uses `IntrinsicHeight` to stretch the crew bar, so **nothing in its subtree may
  use `LayoutBuilder`, `AutoSizeText` or `FittedBox`** — they cannot report
  intrinsics.
- **TIME OFF renders as `_DayOffStrip`, and the typed reason LEADS it**
  (2026-08-25). One layout serves titled and untitled blocks: the headline slot
  is always filled — the reason when there is one, the `<name> is off` sentence
  when there isn't — and only the caption beneath is conditional. Never render
  both slots from the same string. Two traps sit on the reason lookup, both
  owned by `dayOffReason` (`calendar/domain/day_off_reason.dart`): an unnamed
  personal block does **not** save blank, it saves the localized
  `calendar_personal` placeholder (`add_appointment_sheet.dart`,
  `details_edit_body.dart`), which must not be promoted to the headline; and
  with no subject to name, the title is already the sentence's subject, so
  there is no separate reason left. **That placeholder is matched across EVERY
  supported locale (`personalTitlePlaceholders`), never the reader's alone** —
  the title is written in the AUTHOR's locale and read back in the reader's, so
  a single `context.l10n.calendar_personal` test misses a French admin's
  "Personnel" on an English screen and promotes it to the headline, and misses
  in reverse. Adding a locale means the new spelling joins that set. **The
  OPENED view (`_DayOffBody`, `details_view_body.dart`) applies the same rule
  through the same helper** — tapping a strip that reads "Vacation" must not
  open a screen that has dropped the word, and the placeholder trap is subtle
  enough that a second spelling would have drifted. **The dashed crew rail REVERSES the earlier call** that a day off shows
  its colour only as the avatar — the dashes are what earn it, reading as the
  negative of the card's solid bar rather than a quieter version of it. The
  strip also carries a `colorScheme.outline` border, and that is load-bearing,
  not decoration: its `neutralContainer` fill resolves to `AppColors.paper`,
  which is ALSO `scaffoldBackgroundColor`, so without an edge the strip has no
  visible container at all in the light theme.
  **That ground is SHARED with the holiday row through
  `widgets/cards/non_working_time_row.dart`** (2026-08-29) —
  `nonWorkingTimeDecoration`, `NonWorkingTimeText`, `kNonWorkingRowMinHeight`
  and `kNonWorkingRailWidth`. The two rows say the same kind of thing and
  render adjacent in the same agenda, so the ground and the headline/caption
  column must not drift; they were hand-written copies that had already
  disagreed on the caption gap before the holiday row shipped. Only those four
  things are shared — each row keeps its own LAYOUT, which legitimately differs
  (the day off positions a dashed rail in a `Stack` to avoid forcing intrinsic
  layout and carries an avatar; a holiday belongs to nobody, so its rail is an
  ordinary child). Put a new "this day is not work" row on the same four.
- **Holidays are COMPUTED and DISPLAY-ONLY, and the marker is a rule UNDER the
  day number** (2026-08-29, designed in
  `docs/archive/2026-08-29-calendar-holidays.md`). `domain/holidays.dart` derives
  Québec's statutory days, the Greek Orthodox Easter trio and the CCQ
  construction shutdown from pure arithmetic — no dataset, no network call, no
  yearly maintenance. A bundled table was rejected deliberately: whatever range
  it covered, the calendar would stop marking holidays the year after with no
  error and no bug report. Nothing is dimmed, warned or blocked; an emergency
  call on Saint-Jean saves exactly as it did before.
  **The marker lives INSIDE the token, and that is the whole design.**
  `calendarDayTokenWithRule` (`widgets/views/calendar_day_circle.dart`, beside
  the decoration it wraps) paints a 2px rule 4px above the token's bottom edge.
  **It RESOLVES the colour itself rather than taking one** — a surface hands it
  the set and the two states, so it cannot render a token and forget the
  marker, which would compile clean and simply show nothing. That is the drift
  `calendarDayCircleDecoration` was extracted to end, and this is its twin.
  `holidayHueFor` is the bare palette lookup (what the agenda row's rail
  paints) and `holidayRuleColorFor` layers the two state variants over it. A marker living in the
  token's `fill` is erased by selection — which wins the fill by rule in
  `calendarDayCircleDecoration` — so it would be absent on exactly the day
  being read. **The day NUMBER is never recoloured** (owner call): the rule
  alone is the marker, so selection and off-month keep reading as they always
  did. On a SELECTED day the rule goes `onPrimary` white, because every
  candidate hue muddies against the primary-blue fill (Greek flag blue, the
  first pick, was very nearly invisible on it) — the agenda row below is open
  by definition on a selected day and carries the colour and the name instead.
  **That last clause is the whole justification, so a surface with NO agenda
  row beneath it must pass `keepHueWhenSelected`** — the hue is then LIFTED
  toward `onPrimary` instead of replaced by it. `InlineMonthCalendar` is that
  surface and the only one that passes it: whitening there dropped the holiday's
  CATEGORY at the exact moment a date is being chosen, on the one surface that
  can prevent a mis-booking rather than report one. The lift factor is picked
  so all three clear 3:1 on the fill and no further, since every step past that
  pulls the three toward the same white and loses the distinction it exists to
  keep; both are pinned by tests.
  Off-month drops to 45% alpha so the rule fades with the faint number; for the
  construction shutdown that is the NORMAL case, since the run crosses the
  July/August boundary every single year.
  **All THREE `calendarDayCircleDecoration` call sites take it** — the month
  grid, the collapsed week strip and the form's `InlineMonthCalendar`. The
  picker is the one that matters most and the easiest to forget: it is where a
  date is chosen while booking, so it is the only surface where the marker can
  prevent a mis-booking rather than just report one.
  **The three hues live on `AppPalette`, never a `theme.brightness` branch**
  (`holidayStatutory` / `holidayOrthodox` / `holidayConstruction`) — the
  frontend rule forbids branching on brightness for styling, and this is the
  same shape as `crewColorOf` reading `palette.crewOverride`. They are three
  plain fields rather than a `HolidaySet`-keyed map for two reasons, and
  "`core/` must not import a feature type" is NOT one of them — that rule does
  not exist here, and a dozen files under `core/` already import from
  `features/`. The real ones: `lerp` interpolates a `Color` field but can only
  SNAP a map at the midpoint, so a keyed map would step the hue mid-theme
  animation; and `holidays.dart` imports `l10n.dart` for its label resolvers,
  so taking `HolidaySet` would drag `AppLocalizations` into `core/theme/`,
  which today has zero feature imports. The hues sit in `crewPalette`'s GAPS on purpose: blue
  is the selection fill, red means *cancelled*, and the ten crew hues are
  painted as round dots ~3px below this rule, so a shared hue twins with the
  dot beneath it. **The DARK construction hue must not be `darkAmber`** — that
  constant IS the dark rendering of crew amber, so the shutdown's rule and the
  crew dot beneath it painted the same colour until 2026-08-29; check a new
  hue against `_darkCrewOverride`'s VALUES, not just `crewPalette`.
  **`holidaysOn` returns a LIST and the marker reduces it.** The two Easters
  coincide roughly one year in three (2028, 2031, 2034), so one day really can
  carry both Good Fridays. `HolidaySet`'s DECLARATION ORDER is the precedence —
  statutory wins the single hue a cell can show — and the agenda renders BOTH
  rows so nothing is lost. Reducing with "first match" instead would make the
  colour depend on the order the sets happen to be built in.
  **The semantics label names the holiday**, for the same reason it carries the
  appointment count: the rule is colour-only. `CalendarDayCell` resolves
  `holidaysOn` ONCE and feeds both the label and `markerSetFrom` — don't
  re-look-up per concern.
  **The agenda row reuses the day-off vocabulary** (`HolidayAgendaRow`) —
  `neutralContainer`, `outline` border, `r12`, mono all-caps tag. A holiday IS
  non-working time, so it joins a category the app already speaks instead of
  opening a new one; the only structural difference is that it belongs to
  nobody, so there is no avatar and the rail slot carries the set's hue. The
  shared half lives in `widgets/cards/non_working_time_row.dart` — see the
  day-off bullet above. It
  lives inside `AgendaSliverList` (which takes a REQUIRED `day`) rather than at
  the two call sites, so the portrait calendar and the split-layout `EventList`
  can never disagree. That day must be the same one the `events` beside it were
  resolved for — the screen passes `_selectedDay ?? _focusedDay`, its
  resolved-day idiom, never the raw nullable field, or the holiday row and the
  job list describe different days. It renders ABOVE the skeleton and the empty
  state, because it costs no read and a holiday with nothing booked is the day
  it has most to say about. **The TAG is where "statutory vs observance"
  lives** — the grid marker carries only a hue, and on a selected day that hue
  is white. The construction row deliberately carries NO caption (owner call):
  "Construction holiday" needs no gloss.
  **Three date rules are wrong in the obvious implementation** and are each
  pinned in `holidays_test.dart` against published dates. Patriotes is the
  Monday STRICTLY before May 25 — when the 25th is itself a Monday (2026) an
  "on or before" reading gives the 25th, and is right the other six years in
  seven. Canada Day shifts to July 2 when July 1 is a Sunday, **and Fête
  nationale shifts to June 25 on the identical rule** — implementing one
  without the other (which the first build did) answers the same legal
  question two ways in 2029, when both dates fall on a Sunday. And the CCQ
  shutdown is the Sunday PRECEDING July's last Saturday, **not** the widely
  repeated "Sunday after the third Saturday", which is right for 2024–2026 and
  wrong for 2022 and 2023.
