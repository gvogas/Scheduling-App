# P1 + P2 device test — one check at a time

**Branch:** `redesgin` · **Written:** 2026-07-30 · **Revised:** 2026-07-31 ·
**Target:** real iPhone, not the Simulator

> **Revised 2026-07-31** after the first hardware pass. The owner changed eight
> things mid-test, and the checks below describe the app **as it is now**, not
> as P2 shipped. Where a check contradicts `2026-07-30-p2-calendar.md` or the
> P2 handoff, this file and `CLAUDE.md` win — see the "Superseded" note at the
> top of those two. What changed: variable-height month grid (§2.1), paging
> selects the 1st (§2.3), the fetch window covers the selected day (§2.3b),
> drag-handle collapse replacing scroll-driven collapse (§3), banded crew bar
> and per-assignee avatars (§4.2), personal + all-day jobs (§6b), Repeat inside
> the schedule panel and a clear button on the address (§6.4, §6.9), the
> measured month abbreviation (§9.2b), and the light-mode drawer haze (§1.6).

> **Reconciled 2026-08-10 — still the runbook, but the app moved five projects
> under it.** The checks below were written against P1+P2 and revised for P2b.
> P3, P4, P4c and three later changes have since altered things a tester will
> **see**, and none of them is a failure. Read this list first so you don't file
> one:
>
> - **Drawer rows now carry a 28×28 tinted icon chip.** Label-only rows are the
>   old design (2026-08-04).
> - **Tours are 43 steps, not 14, and three of them start inside a sheet.**
>   Opening Add appointment / Add client / Invite person for the first time on a
>   fresh install starts a walkthrough *in the sheet*. That is the feature.
> - **The day agenda sinks closed work.** `done` and `cancelled` jobs sort below
>   the open ones under a "Done · N" rule, render as a collapsed ~56px row with a
>   green tint, and lose their avatar stack (the crew colour bar stays). The
>   header count reads `4 JOBS · 1 DONE`. Every one of those rows must still open
>   the appointment sheet — that is check-worthy in itself.
> - **The appointment card has a photo glyph** at the end of the title line when
>   the job carries pictures, and a `Day 3 of 5` counter on a multi-day run.
> - **All-day is offered on EVERY job now**, not just personal ones, and an
>   appointment may span up to 14 days.
> - **Clients** have swipe actions (archive; delete only when the job history is
>   empty), an Archived chip and type-filter chips.
> - **There is no signup code anywhere.** Creating a person mints a real account
>   and shows an email + starting password to hand over. Any check mentioning an
>   invite code is describing a flow that was deleted.
> - **History shows an admin the Edit affordance on a completed job** (as the
>   action bar's bottom button, not the top chip).
>
> §0.1's `d9816fe` pin is historical — check out the tip of `redesgin`.

Neither P1 (foundation/navigation) nor P2 (calendar) has ever run on hardware.
This is the single pass that covers both.

**How to use this:** work top to bottom. Each check is self-contained — do the
action, compare against **Expect**, and mark the box. If something differs,
record it under **Result** in §9 and keep going unless the check says STOP.
Every check names the file that owns the behaviour, so the Claude session on the
Mac can go straight there.

---

## 0. Before the first launch (do these in order)

- [x] **0.1 — Pull the branch.**
      `git fetch && git checkout redesgin && git pull` → HEAD should be `d9816fe`.
- [x] **0.2 — Copy the two gitignored files across.** Neither is in git:
      - `dev/.env` — 8 keys. Bundled as an asset; **the app will not start without it.**
      - `ios/GoogleService-Info.plist` — note it lives at the **`ios/` root, NOT `ios/Runner/`.**
- [x] **0. — Do NOT run `flutterfire configure`.** It rewrites
      `lib/firebase_options.dart` into literal-values style and breaks the
      env-based iOS setup. If someone already ran it, `git checkout
      lib/firebase_options.dart` before building.
- [x] **0. — Do NOT look for a Podfile.** This project is **SPM-only**. Xcode
      resolves `firebase-ios-sdk` on first open; `pod install` is not part of
      this repo and never will be.
- [x] **0. — Real device, not Simulator.** App Check uses **App Attest**, which
      fails on the Simulator. On the Simulator every Firestore read/write returns
      `permission-denied`, which will look exactly like a P2 bug and is not one.
- [x] **0. — `flutter pub get`, then build.** Deployment target is iOS 18.0.

### 0.7 — Make UI errors visible (IMPORTANT, and revert after)

`main()` sets `FlutterError.onError = crashlytics.recordFlutterFatalError`, so
**overflow and layout errors go silently to Crashlytics and never appear in
`flutter run` output.** Half the checks below are looking for overflow. Before
testing, temporarily add the console dump in `lib/main.dart`'s handler:

```dart
FlutterError.onError = (details) {
  FlutterError.dumpErrorToConsole(details); // TODO(pre-ship): remove after device test
  crashlytics.recordFlutterFatalError(details);
};
```

- [ ] 0.7 patch applied
- [ ] **0.7b — revert it when the pass is done** (last line of §9)

---

## 1. Launch and shell (P1)

- [x] **1.1 — Cold launch to the calendar.**
      Expect: splash → calendar. No stall on a static frame.
      *Owner:* `splash`, `routes/hub_shell.dart`
- [x] **1.2 — The header pair is on every screen.**
      Tap the hamburger (top right) → drawer slides in **from the right**, 284px,
      grouped Today / People / The Business / Account.
      Expect: today's job count and on-shift staff count render on their rows.
      *Owner:* `features/navigation/widgets/app_nav_drawer.dart`
- [x] **1.3 — The Calendar pill goes home from anywhere.**
      Drawer → Settings → then tap the **Calendar** pill in the header.
      Expect: lands on the calendar tab with the pushed stack collapsed — not
      Settings-with-a-calendar-behind-it.
      Note: the **calendar's own header has no pill** (2026-07-31) — a go-home
      control on the screen it goes home to. Only the hamburger there.
      *Owner:* `goHomeToCalendar` in `core/navigation/`
- [x] **1.6 — The drawer in LIGHT mode.**
      Open the drawer with the light theme on.
      Expect: a clean white panel. **No grey haze or "glow" across it** — the
      drop shadow used to be painted inside the drawer and washed over its own
      surface (fixed 2026-07-31; it only ever showed in light).
      *Owner:* `features/navigation/widgets/app_nav_drawer.dart`
- [x] **1.4 — Back means back.**
      From Settings, use the back arrow (not the pill).
      Expect: returns to whatever pushed it, one level.
- [x] **1.5 — A notice renders as a dark pill at the TOP.**
      Trigger any success (e.g. mark a job complete).
      Expect: compact dark pill, coloured status dot, top of screen, auto-clears.
      Swipe up dismisses early.
      **STOP if no notice appears at all** — that means `NoticeListener` lost its
      `navigatorKey` and every notice in the app is suppressed.
      *Owner:* `core/notices/`, `main.dart`

## 2. Calendar month grid (P2)

- [x] **2.1 — Only the weeks the month occupies.** (Changed 2026-07-31 — the
      grid was a fixed 42 cells / 6 rows and trailed a week of nothing but
      off-month cells.) Check three months:
      - **August 2026** (31 days from a Saturday) → **6 rows**, the 31st visible,
        nothing clipped. This is the month a 5-row grid breaks.
      - **February 2026** (28 days from a Sunday) → **4 rows**, no lead cells, no
        trailing week.
      - Any ordinary month → **5 rows**.
      Expect in all three: the last row always contains at least one day of the
      month, and the grid gets shorter/taller as you page (see 2.3).
      *Owner:* `calendar/domain/month_grid.dart`, `calendar_month_grid.dart`
- [x] **2.2 — Off-month cells.** Look at the leading/trailing greyed days.
      Expect: faint day number **and crew dots if someone works that day**, but
      tapping does nothing. This is deliberate — see handoff deviation #5.
- [x] **2.2b — Dots on the selected day.** Tap a day that has crew dots under it.
      Expect: **the dots stay put** under the filled circle (changed 2026-07-31 —
      they used to disappear on selection, which hid the crew for the one day you
      were actually looking at). Check today's circle too, and an off-month day.
- [x] **2.3 — Swipe between months.** Swipe left, then right, several times fast.
      Expect: smooth paging, no crash. Paging **selects the 1st of the month you
      land on** and the agenda below follows it (changed 2026-07-31 — the
      selection used to stay behind in the month you came from, where the grid
      wasn't even highlighting it).
      Expect too: the grid's **height animates** between a 4/5/6-row month
      instead of jumping, and a taller month sliding in is never cut off
      mid-drag.
      *Owner:* `calendar_month_pager.dart`
- [x] **2.3b — Page several months, then check the agenda count.**
      Swipe forward 3+ months, then back to a month you know has jobs.
      Expect: the day's jobs are listed. **"0 jobs" on a day that has some is
      the bug fixed on 2026-07-31** — the fetch window followed the visible
      month only and stopped covering the selected day.
      *Owner:* `AppointmentDateRange.forCalendar`
- [x] **2.4 — The month picker still opens.** Tap the month name in the header.
      Expect: bottom sheet with **two wheels** — every month, and years −5/+15.
      Pick a distant month; the grid and agenda follow.
- [x] **2.5 — Today's circle.** Confirm today is ringed/bold and the dots under
      days match who's actually working.

## 3. The collapse — P2's headline interaction

**Reworked 2026-07-31.** It used to be one scroll view: the grid sat above the
jobs and scrolled away as you read down the day. It is now **two areas** — the
grid is fixed, the jobs scroll on their own, and the collapse is a deliberate
**drag on the divider between them**. Scrolling the jobs must never move the
calendar.

- [x] **3.1 — Drag the handle up.** Find the line between the calendar and the
      jobs (it carries a short grab bar). Drag it up ~30px.
      Expect: past 24px of travel the month grid **unmounts** and a one-week
      strip rises inside the fixed header.
      *Owner:* `calendar/domain/collapse_state.dart`
- [x] **3.2 — Drag the handle back down.**
      Expect: the full month grid returns.
      **STOP-worthy failure:** stays collapsed forever with no way back.
- [x] **3.3 — Tap the handle.** It is a button as well as a drag target.
      Expect: toggles collapsed/expanded on a single tap.
- [x] **3.4 — Scroll the jobs, hard.** Fling the job list up and down, deep into
      a long day.
      Expect: **the calendar never moves.** This is the whole point of the
      rework — if scrolling the jobs collapses the grid, the two areas got
      merged back into one scroll view.
- [x] **3.5 — Half-drag twice.** Drag the handle up ~15px, let go, drag up ~15px
      again.
      Expect: **no collapse.** Travel resets when the finger lifts, so two
      half-gestures don't add up into one.
- [x] **3.6 — Wobble mid-drag.** Drag up 20px, down 10px, up 20px without
      lifting.
      Expect: no flicker; reversing direction restarts the count.
- [x] **3.7 — Tap a day in the week strip while collapsed.**
      Expect: selects that day, agenda updates, strip stays collapsed.
- [x] **3.8 — Swipe the week strip sideways** while collapsed. (New 2026-07-31.)
      Expect: pages one week and **selects that week's first day**; the agenda
      and the header's month label follow it.
- [x] **3.9 — The Today pill.** Select a day that isn't today.
      Expect: a white **pill** (not a round FAB) appears bottom-left. Tap → back
      to today, pill disappears.
      Then: with today selected, **page to another month**. Expect the pill
      **appears** — it used to stay hidden because today was still the selected
      day, on a month you could no longer see (fixed 2026-07-31).
- [x] **3.10 — A day with one or two jobs.** Collapse the handle on a short day.
      Expect: it collapses and *stays* collapsed. A short list springs back to
      the top on its own and must not undo the gesture.

## 4. The appointment card (P2)

- [x] **4.1 — One card everywhere.** Compare a job as it appears on: the calendar
      agenda · Day route · a client's Job history · the Dashboard · History.
      Expect: identical card design in all five.
- [x] **4.2 — Multi-crew job.** Find/create a job with 2+ assignees.
      (Both halves changed 2026-07-31.)
      Expect: **one avatar per assignee**, overlapped into a stack, each ringed
      in the card colour so two crew colours don't merge — then the **client
      name** as the text of that line. No "Theo +1" text.
      Expect: the left colour bar is **split into a band per assignee** in their
      own colours, hard-edged. **Not grey** — grey means unassigned. Capped at
      4 bands / 4 avatars.
- [x] **4.3 — Unassigned job.** Expect: renders fine, faint (grey) bar, no
      avatars, no crash.
- [x] **4.4 — Cancelled job in History.** Expect: struck-through title, dimmed
      (0.6). On the calendar agenda a cancelled job is **not** dimmed — that
      asymmetry is intentional.
- [x] **4.5 — Overdue job** (past end time, still open).
      Expect: amber warning glyph before the title, "Overdue" chip.

## 5. Detail sheet (P2)

- [x] **5.1 — Open a job.** Expect: title + status chip on one row, then a single
      mono line like `TUE 4 AUG · 10:30 – 12:00`. No separate calendar/clock icon rows.
- [x] **5.2 — The info panel.** Expect: `CLIENT / PHONE / ADDRESS / NOTES` in a
      mono key column at left, values right. Phone and address are blue and tappable.
- [x] **5.3 — Empty sections are absent.** Open a job with no notes.
      Expect: **no** `NOTES` row at all — not "None".
- [x] **5.4 — Tap the phone** → dialer. **Tap the address** → map chooser.
- [x] **5.5 — Mark as complete** is a **filled green** button (not blue, not grey).
- [x] **5.6 — A repeating job** shows its repeat line under the when-line.
- [x] **5.7 — Employee account:** sign in as an employee and open a job.
      Expect: **no** Edit / Cancel / Delete affordances anywhere.
      **STOP if they appear** — that is a permissions-surface regression.

## 6. Form sheets (P2)

- [x] **6.1 — Tap + to book a job.** Expect: a bar across the top with
      **Cancel · New Appointment · Save**. No big Save button at the bottom.
- [x] **6.2 — Save is reachable with the keyboard up.** Tap into Notes so the
      keyboard covers the lower half.
      Expect: the top bar (and Save) stays put and visible. This is the whole
      point of the fixed bar.
- [x] **6.3 — Sections.** Expect mono headers: `TEMPLATES`, `WHO`, `SCHEDULE`,
      `DETAILS`.
- [x] **6.4 — The schedule panel holds everything about *when*.**
      (Changed 2026-07-31 — Repeat used to be a dropdown below the panel.)
      Expect one panel: Date on its own row, then **Start and End side by side**
      with a divider between (values in blue mono), then **Repeat** as a row
      showing the current rule. Tapping Repeat opens the action sheet.
- [x] **6.5 — Pickers work.** Tap Date → date picker. Tap Start → time picker;
      End should auto-advance if you haven't set it manually.
- [x] **6.9 — Clear the address.** Type an address, then tap the **×** in the
      field. (New 2026-07-31 — the field's custom pin suffix was suppressing the
      clear button every other text field has.)
      Expect: the pin turns into an × once there's text; tapping it empties the
      field, closes any suggestion list, and the address is really gone when you
      save.
- [x] **6.6 — Validation.** Hit Save with the form empty.
      Expect: inline errors under the offending rows (e.g. "Please select a date"),
      no crash, Save re-enables.
- [x] **6.7 — Edit an existing job.** Tap Edit on a job.
      Expect: the same bar chrome, title "Edit Appointment", primary "Save changes",
      and **Delete at the bottom of the scroll** — never in the top bar.
- [x] **6.8 — Double-tap Save.** Expect: one save, not two. The bar's verb
      disables and shows a spinner while in flight.

## 6b. Personal jobs (new 2026-07-31)

Time blocked off for the crew rather than a visit to a client. Nothing here
existed when this runbook was written.

- [x] **6b.1 — The switch is on the ADD form.** Tap + → the `WHO` section starts
      with a **Personal job** switch. Turn it on.
      Expect, immediately: the client picker, the address field, the template
      chips, the repeat row, Materials and Photos all **disappear**. The
      assignee picker stays — it decides who the block is for and who can see it.
- [x] **6b.2 — Save one with no title and no time.**
      Expect: it saves. The title is optional here (it stores as "Personal") and
      the **All day** switch — the first row of the schedule panel — is on by
      default when you haven't picked a time.
- [x] **6b.3 — On the calendar.** Find the block you just made.
      Expect: the card reads **"All day"** where the time range goes, and
      **"Personal"** where the client name goes. Not "12:00 AM – 11:59 PM".
- [x] **6b.4 — Its status pill stays "Scheduled".** Let a personal block's end
      time pass (or make one in the past).
      Expect: still **Scheduled** — never "In Progress", never "Overdue", and no
      "job finished?" push. A dentist appointment is not a job to close.
- [x] **6b.5 — Turn All day off.** Expect: the Start/End rows appear in the same
      panel and are required again.
- [x] **6b.6 — Edit an ordinary client job.** Open Edit on a normal job.
      Expect: **no Personal switch at all.** It is only offered on a job that was
      already personal, so a client visit can't be converted mid-life (which
      would wipe its client and address).
- [x] **6b.7 — Edit a personal job.** Expect: the switch **is** there, so you can
      turn it back into an ordinary job.
- [x] **6b.8 — Push text.** If you can trigger an assignment push for a personal
      block: expect it to name the block by its **title**, not "Client".
      *(Server-side; needs the functions deployed.)*

### 6c. All-day off the calendar screen (widget / Siri / push)

An all-day block stores a real midnight → 23:59 span, so every surface that
*speaks* the schedule rather than showing it had to learn the flag. All four are
now threaded; these checks are what proves it on hardware.

**Needs the functions redeployed** (`functions,firestore:rules,firestore:indexes,storage`)
for anything server-side, and a **rebuilt** app for the Swift decoders.

- [x] **6c.1 — Widget, today.** Make an all-day block for **today**, then look at
      the home-screen widget.
      Expect: the block is listed under **today** and reads **"All day"**.
      **This is the regression to watch:** before the fix it vanished from today
      (its midnight start was already past) and showed up only under *tomorrow*.
- [x] **6c.2 — Widget, "up next".** With an all-day block **and** a later timed
      job on the same day, check the small widget.
      Expect: the **timed** job is the one shown as next — the all-day block is
      listed but never wins the "up next" slot. With only the all-day block left,
      it does show.
- [x] **6c.3 — No 23:30 push.** Create an all-day block for **tomorrow** and
      leave the phone alone through the evening.
      Expect: **no "time to leave" / "upcoming job" push** around 23:30 tonight.
      That push was the one real bug here. A *timed* personal job (e.g. dentist
      at 2pm) must still get its reminder — worth confirming separately.
- [x] **6c.4 — Assignment push text.** Trigger an assignment/reschedule push for
      an all-day block.
      Expect: the body reads the **date only** — "Vacation · Wed, Jul 8". Never
      "Wed, Jul 8, 12:00 a.m.".
- [x] **6c.5 — Nightly digest.** If you can reach the 18:00 digest with an
      all-day block first on tomorrow's list:
      Expect: "First: Vacation · all day." — no clock time.
- [x] **6c.6 — Siri: today's schedule.** "Hey Siri, what's my schedule today?"
      with an all-day block on it.
      Expect: it reads **"all day, <title>"**, not a midnight time, and names the
      block by its **title** — *not* "unnamed client". (The snapshot gained
      `title` in v2 for exactly this.)
- [x] **6c.7 — Siri: next appointment.** With an all-day block and a later timed
      job: expect the **timed** one is announced as next.
- [x] **6c.8 — Siri after upgrading.** First launch after installing this build,
      Siri may answer **"Open ES Pro to sync your schedule."** once — the
      snapshot schema went 1 → 2 and the old payload is rejected until the app
      rewrites it. Open the app, then ask again.
      Expect: it answers normally the second time. If it keeps saying that, the
      version constants have drifted — report it.

## 7. The two dialogs (P2)

- [x] **7.1 — Scheduling conflict on EDIT.** Take an existing job, edit only its
      **notes**, and save.
      Expect: **NO conflict dialog.** The job must not collide with itself.
      **This is the bug C3 fixed — if the dialog appears here, report it.**
- [x] **7.2 — A real conflict on edit.** Move a job onto a slot where its assignee
      already has another job.
      Expect: the conflict dialog *does* appear, naming the busy person.
      Tap Cancel → returns to the form, **Save is usable again** (not stuck spinning).
      Tap Schedule anyway → saves.
- [x] **7.3 — Repeat scope dialog.** Save a change to a repeating job.
      Expect: two radio options **with real numbers** — e.g. "12 remaining visits
      through 26 Jan" — and the button label changes between **"Save this visit"**
      and **"Save 12 visits"** as you switch. Defaults to this-visit-only.
- [x] **7.4 — Delete a repeating job.** Expect: same dialog shape, and the confirm
      button is a **readable solid red** (check this again in dark mode, §8).

## 8. Dark mode

Switch to dark (Settings, or system) and re-check:

- [x] **8.1 — Calendar** — header, grid, dots, week strip.
- [x] **8.2 — Cards** — crew colour bars must still be distinguishable.
- [x] **8.3 — Detail sheet** — the green "Mark as complete" must be readable.
- [x] **8.4 — The delete confirm button.** Expect: solid readable red.
      **This is the specific thing C4 fixed** — it used to use the lifted
      foreground red as a fill and was unreadable in dark.
- [x] **8.5 — Status bar icons** on the calendar. Expect: correct contrast
      against the header. The calendar has no app bar, so it sets this itself —
      if the icons vanish into the background, `AnnotatedRegion` is wrong.
- [x] **8.6 — Notices** in dark.

## 9. Large text (2×) and landscape

- [x] **9.1 — Set text size to max** (iOS Settings → Display → Text Size, or
      Accessibility for the larger range).
- [x] **9.2 — Calendar header at 2×.** Expect: the month title and the
      route/menu controls **stack onto two rows**. No yellow-black overflow
      stripes. (Unstacked, this overflowed by 138px.)
- [x] **9.2b — The month name at large text.** Set the app's own text size to
      **XL** (Settings → Text size), on a long month — September, or any month
      in French. (New 2026-07-31.)
      Expect: the header shows the **abbreviation** ("Sep"), not "Septemb…".
      The row measures itself, so check a couple of widths/scales: the full name
      should come back whenever it genuinely fits.
      **Past bug:** the old rule keyed off a `> 1.4` text-scale gate and the XL
      setting is exactly 1.4, so it never fired.
- [x] **9.3 — Month grid at 2×.** Expect: taller rows, no clipping. Note: column
      width can drop under 48px on a narrow phone — accepted, a 7-column week
      can't do better.
- [x] **9.4 — Job form at 2×.** Expect: Start/End stack vertically instead of
      sharing a row.
- [x] **9.5 — Detail sheet at 2×.** Expect: the key/value panel stacks label
      above value.
- [x] **9.6 — Rotate to landscape.** Expect: month grid and agenda **side by
      side**, **no collapse handle**, and no collapse behaviour at all —
      collapse is portrait-only.
- [x] **9.7 — Rotate back.** Expect: the handle is back and works, nothing
      wedged.
- [x] **9.7b — Short viewport.** At 2× on a small phone, portrait.
      Expect: **no overflow stripes under the calendar.** The fixed grid shrinks
      (and scrolls internally) rather than running the column past the bottom —
      this overflowed by 1.9px before 2026-07-31.
- [x] **9.8 — Reset text size** before continuing.

## 10. Device-only paths (no test coverage — look carefully)

- [x] **10.1 — Camera capture.** Job form → photos → Camera. Take a shot.
      Expect: permission prompt first time, image lands in the strip.
- [x] **10.2 — Gallery pick.** Expect: OS photo picker, no permission prompt.
- [x] **10.3 — Photo upload survives backgrounding.** Add photos, save, background
      the app immediately, return.
      Expect: upload completes or retries; no duplicate photos on the job.
- [x] **10.4 — Notification deep link.** Trigger a push (assign yourself a job
      from another account) and tap the notification.
      Expect: opens **that job's** detail sheet, not just the app.
- [x] **10.5 — Home-screen widget tap.** Add the widget, tap a job row.
      Expect: same — the appointment sheet opens.
      *If it merely launches the app,* the `homeWidget` query param was dropped
      from the deep-link URL (see CLAUDE.md — three Swift producers must append it).
- [x] **10.6 — Offline save.** Turn on Airplane mode, try to save a job.
      Expect: a fast, clear offline notice — **not** a spinner that hangs.

---

## Results

> **§0 through §10 closed 2026-08-11 — all checks reported PASSING by the owner**
> from testing done on hardware ahead of this session, not from a pass driven
> from the repo. Recorded on his word; there is no console capture or screenshot
> behind any individual box, so treat a future contradiction as "re-run that
> check", not as a regression with a known-good baseline.
>
> **The P5 block below is CLOSED TOO — all 18 checks reported PASSING by the
> owner on 2026-09-09**, run on hardware as a technician (which is the only role
> that proves anything there — the admin branch of `allow update` masks a broken
> self clause completely). Recorded on the same terms as §0–§10: the owner's
> word, no console capture behind any individual box, so a later contradiction
> means "re-run that check", not "a regression against a known-good baseline".
>
> **The surfaces with no runbook were swept the same day** and reported passing
> as a group — the P3/P4/P4c screens, the drawer icons and the 43 tour steps, the
> closed-jobs agenda, the photo cue, the restyled History and the P7 dashboard.
> That is a general sweep, not per-check evidence: nothing here enumerates those
> screens, so treat a finding on one as new rather than as a regression.
>
> **Two things this does NOT cover.** The **Siri on-device pass is still
> unrun** — the six read intents in `ios/SiriIntents/` have never been exercised
> by voice, and that remains the only thing between Siri Phases 1–3 and done
> (`../2026-07-19-siri-app-intents-implementation.md`). And the loose end from
> the P4 pass is not retired: the `RawScrollbar` "attached to more than one
> ScrollPosition" assertion is still unattributed to a screen.

| # | Check | Pass? | Notes |
|---|---|---|---|
| §0–§10 | All | Pass | Owner-reported 2026-08-11; see the banner above |
| P5 | All 18 | Pass | Owner-reported 2026-09-09, run as a technician |
| — | The unrunbooked surfaces (P3/P4/P4c, tours, agenda, History, dashboard) | Pass | Owner-reported 2026-09-09, swept as a group |

Record anything that differs from **Expect** here, with the check number. For a
visual issue a screenshot is worth more than a description. For a crash or a
silent failure, grab the `flutter run` console output — with the §0.7 patch in
place, overflow errors will actually print.

- [ ] **Final: revert the §0.7 `dumpErrorToConsole` patch** before committing anything.

---

## P5 — My details (added 2026-08-10; **all 18 PASSED 2026-09-09**, owner-reported)

**Sign in as a TECHNICIAN, not an admin.** The admin branch of `allow update`
masks a broken self clause completely, so an admin pass proves nothing here.
**The required deploy has run** — 2026-08-11 at `258cc91a`, functions + rules +
storage, verified against the deploy log in `docs/DEPLOYMENT.md`. So a
`permission-denied` on any check below is now a **real finding**, not the
expected symptom of a missed deploy. (Before that deploy every check here could
only have failed, which is why the block reads `none run`.)

| # | Check | Expect |
|---|---|---|
| P5.1 | Settings › My details, edit the phone | A Save/Discard bar appears **only after** the first keystroke |
| P5.2 | Tap Discard | The stored phone comes back and the bar disappears |
| P5.3 | Type a change, then type the original value back | The bar disappears again — dirtiness is recomputed, not latched |
| P5.4 | Tap Save | Success notice; reopen the screen and the new phone is there |
| P5.5 | Toggle a working day | Writes immediately, **no** save bar |
| P5.6 | Turn off a day that holds a booked job | Amber note naming that day; the job is NOT moved |
| P5.7 | Turn off a day with no work | No amber note |
| P5.8 | Type into the phone field, then toggle a day WITHOUT saving | The half-typed phone must NOT be committed — reopen and confirm the stored phone is unchanged |
| P5.9 | Airplane mode, then toggle a day | Toggle reverts and an offline notice appears |
| P5.10 | Scroll to the bottom | **No** SCHEDULING section (technician) |
| P5.11 | Sign in as an admin, open My details | SCHEDULING section with the max-jobs row, and it saves |
| P5.12 | Tap the email row's edit action | Sheet demands the address twice plus the password |
| P5.13 | Enter mismatched addresses | Save stays disabled and the mismatch message shows |
| P5.14 | Enter a wrong password | A failure notice; the address must NOT have changed |
| P5.15 | Complete the change, sign out, sign in with the NEW address | Succeeds |
| P5.16 | On a second device signed in as an admin | A push arrives naming the person — and **not** their address |
| P5.17 | Settings › NOTIFICATIONS | A "Time-to-leave alerts" row, on by default |
| P5.18 | Turn it off, then trigger a departure alert | The push still arrives, as the plain 30-minute reminder (not time-sensitive), never silence |

---

## Notes for the Claude session on the Mac

- Start from `docs/plans/redesign-subdocs/2026-07-30-p2-HANDOFF.md` §2 — it lists **14 deviations
  with their reasons**. Several checks here (2.2 off-month dots, 4.4 the dim
  asymmetry, 9.3 sub-48px columns, 9.6 no landscape collapse) will *look* wrong
  to a fresh reader and are deliberate. Read that before "fixing" one.
- The behaviour is on `redesgin` @ `d9816fe`. Static gates are already green
  (analyze 0 issues, 1173 tests) — a failure here is a device/integration issue,
  not something the suite would have caught.
- **Do not fix and push from the Mac without re-running `flutter analyze` and
  `flutter test`.** The repo's standard is a 0-issue analyzer baseline.
- If a check fails, the fastest triage is usually: which of the three is it —
  a layout/overflow issue (§0.7 console will show it), a permissions/rules issue
  (`permission-denied` in the console → check `firestore.rules`, and confirm it's
  not §0.5 Simulator/App Attest), or a genuine logic bug (reproduce, then find
  the owning file named in the check).
