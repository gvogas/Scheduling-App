# Month-end overdue review — design

**Status (2026-09-19): BUILT and committed (`ed59a6a5`); functions DEPLOYED
2026-09-19 16:37Z (`608b817a`); NOT SHIPPED.** Built 2026-09-13 on branch
`month-end` (from `ba2fdb05`). Deploy `functions` first (the rider; old builds
degrade to the calendar on the tap), then ship the app build; no index, rules
or export change. After the app ships, an admin turns the month-end switch ON
for Paul — until then the rider sends to nobody and logs a recipient count of 0.
Deviations from the text below, all deliberate: the server counts
`OPEN_STATUSES` (which still includes legacy `confirmed`) while the screen lists
the stored `pending`/`in_progress` only; months group by the job's local
START date, the date its card shows; the analytics `count` is bucketed through
`bucketCount` like every other count; the month splitter's hairline sits under
its label row so the row can wrap at 260 px and 2x text; the checkbox is a 48pt
tile beside the card rather than inside its edge; and `sendToActiveAdmins`
gained an `includeUser` filter and now returns how many admins it targeted.

Mockup (chosen design, private artifact):
https://claude.ai/code/artifact/5eecc202-c6d8-4a6b-b723-25d7ebc99f05

**Picked: Option C's screen (big count + cards with a checkbox on the right
edge) with Option B's month splitters in place of C's month pills.** Every
month is in one scroll, oldest first. Option A (full cards behind a Select
mode) and B's dense ledger rows were not taken.

Written in the same session as `2026-09-12-live-map-improvements.md`; the two
are independent.

---

## Why

An overdue job is one whose end time has passed while its stored status is
still `pending` or `in_progress` (`AppointmentRecord.displayStatusAt`). The
crew get a "job finished?" push only inside the first 2 hours after the end
(`OVERDUE_LOOKBACK_MS`), and after that nothing asks anyone again. The
Dashboard's Attention list shows them, but only 5 rows, with no bulk action
and nothing prompting the admin to look. Jobs left open that way skew the
dashboard, job counts and History.

## Decisions made in the session

| Question | Answer |
|---|---|
| What does "Not done" write? | **`cancelled`** — the job never happened. |
| When is the push sent? | **Last day of the month, 6 pm Toronto**, riding the daily digest. |
| Which jobs are listed? | **Every open overdue job, however old** — not just this month's. |
| Where else is the screen? | **A drawer row with a count badge**, available any day. |
| How are jobs closed? | **Select several**, then Complete or Not done. |
| Screen layout | **C + B's month splitters** (above). |
| Undo? | **No — a confirmation dialog instead** (reasoning in §3). |
| Who gets the push? | **Paul only** — not every admin. Prod has four active admins (Paul, Evans, George, the Apple Tester); see §1. |

---

## 1. The push

- **A fourth isolated rider in `sendDailyJobDigest`** (`functions/notifications.js`),
  in its own `try` as that function's header comment requires, **placed after
  the TTL prune and BEFORE `runWaveDaily`.** All four riders share one
  540 s `timeoutSeconds`, and the Wave import alone once needed most of that;
  a rider below it can be killed by the timeout on exactly the evening it
  matters. **No new scheduled function** — a fourth Cloud Scheduler job
  starts costing money (`.claude/rules/notifications.md`), and the export
  count stays at 29.
- **Runs only on the business-local last day of the month.** A pure
  `isLastDayOfBusinessMonth(now)` in `notification_policy.js`: tomorrow's
  business-local month differs from today's, built on `businessYmd` /
  `businessDayStartMs` (calendar-day arithmetic, never `+ 86400000`).
- **Counts** docs with `status in ['pending','in_progress']` and
  `endTime <= now`, then filters them through a pure `selectMonthEndOverdue`
  beside `selectOverdueCandidates` that applies the same rules without the
  2-hour floor: skip `isPersonal === true` (that also covers time off, which
  is always personal), skip a record with no parseable `endTime`. Read through
  `scanAppointmentWindow`, with its own cap (`MONTH_END_REVIEW_MAX`, 1000)
  and warn-at-cap consequence sentence. **The count sent is the filtered
  length; at the cap the push says "1000+".**
- **Zero open → no push.**
- **Recipient: only admins whose month-end switch is on — today, Paul.** The
  owner chose Paul alone over every admin. It is expressed as a stored
  per-person flag, `monthEndReviewPush` (bool, absent = OFF), rather than a
  hard-coded doc id or email, which would break the day Paul's account
  changes and could not be moved to someone else without a deploy. It is
  **admin-only**: a switch on `edit_person_sheet.dart`, shown only for
  admin-role people, and NOT on `kSelfServiceUserFields`. No rules change is
  needed, since `isValidUserData` is per-key. The server reuses
  `sendToActiveAdmins` and filters its already-read docs on
  `monthEndReviewPush === true` — no new query or index, at most 100 admin docs
  in memory. **Default OFF means nobody is notified until someone flips it for
  Paul** — see Deploy. `kind: "overdueReview"`, data
  `{kind, count}`, **no `appointmentId`**. Text lives in
  `notification_messages.js` in EN and FR, per recipient token locale:
  - EN title "{count} jobs still open" / body "They ended without being
    closed. Review them before {Month} wraps up."
  - Singular form for 1.
- **No once-per-month ledger** (removed 2026-09-12 on review). The digest is
  an `onSchedule` with no `retry` and `maxInstances: 1`, and the rider acts on
  exactly one day a month, so a duplicate needs Cloud Scheduler to fire the
  same job twice that evening. A claim collection plus a TTL policy would be
  permanent machinery guarding a case that has never happened. If a duplicate
  ever shows up in the logs, add the claim then.
- **Index:** `(status ASC, endTime DESC)` already exists for the overdue sweep.
  Order DESC to reuse it; the rider only needs the count.

## 2. Tap routing and the drawer row

- **`AppointmentLinkOpener.handlePushTap`** branches on
  `data['kind'] == 'overdueReview'` BEFORE reading `appointmentId`, and routes
  to the review screen through the hub the same way `openAppointment` waits for
  it. **Old builds degrade safely:** with no `appointmentId` they fall into
  `openAppointment('')`, which just shows the calendar.
- **New `PushedDestination.overdueReview`**, admin-only, in `drawerGroups`'
  "The business" group after History. It needs a new icon and colour case in
  the two exhaustive switches (`drawer_catalog.dart`), a label key, and a route
  in `AppRoutes.onGenerateRoute` behind the `AdminOnly` gate. **The member NAME
  is a tour storage key** (`lib/core/navigation/CLAUDE.md`), so pick it once.
  No tour is planned for it.
- **Count badge:** `_countFor` in `app_nav_drawer.dart` gains a case reading
  the screen's provider (below). The drawer body is only built while open, so
  an `autoDispose` watch costs nothing when closed. It renders in the overdue
  colour (`statusColors.overdue`).

## 3. The review screen

**Layout (as mocked):** `AppTopBar` "Overdue jobs" with the standard header
pair. Under it:

- **Summary:** a large mono count in the overdue colour, "jobs ended without
  being closed", and a mono "Oldest · Jul 22" line that becomes "N selected"
  while anything is ticked.
- **One scroll, oldest month first.** Each month opens with a splitter: mono
  "JULY 2026 · 1", a hairline, and a trailing "Select all" that flips to
  "Clear" when every job in that month is ticked.
- **Cards:** `AppointmentCard` rendering with the date added to the time line
  (the list spans days) and **no Overdue chip** (every card here is overdue).
  The right edge is a checkbox with its own 48 pt tap target; the rest of the
  card opens `showEventDetails(..., showActions: true)`. **No select mode.**
- **Action bar:** rises from the bottom only while at least one job is ticked,
  with **Not done (N)** (destructive outlined, `destructiveOutlinedButtonStyle`)
  and **Complete (N)** (filled primary). Selections may span months.
- **Confirmation** (`showConfirmDialog`, Cupertino on iOS). **Neither label
  exists today:** the dialog's dismiss button is hard-coded to `common_cancel`
  ("Cancel"), which reads as the destructive choice in a dialog about
  cancelling jobs. Add an optional `cancelLabel` parameter defaulting to
  `common_cancel`, so every existing caller is unchanged, and pass "Go back".
  "Not done" and "Complete" are new ARB keys as well. The stored value behind
  "Not done" is `cancelled`, and every other screen still says "Cancelled".
  - Not done: "Mark 5 jobs not done?" / "They'll be cancelled and move to
    History. The crew won't be notified." / Go back · Not done (destructive).
  - Complete: "Mark 5 jobs complete?" / "They'll move to History as
    Complete, stamped with today's date." / Go back · Complete.
- **After the write:** the jobs leave the live list, an emptied month's
  splitter disappears, the count and "Oldest" recompute, the selection clears,
  and a success notice reads "5 jobs marked not done" / "5 jobs marked
  complete".
- **Empty state:** count 0 and `AppEmptyState` "No overdue jobs". Never blank.

**Why no Undo.** Reversing a completion must clear the server-owned
`completedAt`. Admins cannot write that field under the rules, and
`restoreAppointmentStatus` handles one document per call behind a durable rate
limit, so undoing a bulk of 20 is neither atomic nor reliable. A confirmation
names the consequence before anything is written.

**Reopening afterwards, checked against the code.** Both results land in
History, where an admin can open the job, tap Edit and set the status back to
Scheduled or In progress (`AppointmentStatus.appointmentValues`).
- A **Not done** (cancelled) job reopens cleanly.
- A **Complete** job reopens with a leftover finish time. `lifecycleStamps`
  only ever ADDS `completedAt` and never clears it, and the admin rules forbid
  touching it, so the detail sheet would still show "Completed …" on a
  reopened job. It is cleared only by `restoreAppointmentStatus`, one job per
  call. Known and accepted for this feature; not in scope to fix here.

**Data.** New `AppointmentsRepository.watchOverdueOpen()` (admin-only — the
appointments `allow read` gives admins everything, and the query is not
constrained by `employeeIds`):
`status whereIn ['pending','in_progress']`, `endTime < now` (fixed at
subscription), `orderBy('endTime', descending: true)` to reuse the existing
composite, `.limit(_overdueReviewLimit)` (500) with a warn at the cap, per the
"every query names a ceiling AND warns at it" rule. It is re-filtered in Dart
through `displayStatusAt(now) == overdue`, which drops personal blocks and
time off, then reversed and grouped by business month for display. The grouping
is a pure function with its own tests. A provider
(`overdueOpenJobsProvider`, `autoDispose`, `keepWarmWithGrace` like the
presence stream) feeds both the screen and the drawer count, so they cannot
disagree. The `now` boundary is refreshed on a coarse tick so a job crossing
its end time while the screen is open appears.

**Writes.** `updateAppointmentStatuses(ids:, status:)` already exists (one
batch, one shared `seriesOpId`). Chunk at 450 ids per batch so a large
selection stays under Firestore's 500-write batch limit. It calls
`_patchWindow`, so History's cached search window stays correct. Each
document is written alone, so a repeat series or multi-day run never gets a
scope dialog and its siblings are untouched.

**Controller.** `OverdueReviewController` holds the selected ids and returns a
sealed outcome (`Ok(count)` / `Busy` / `Failed(error)`), per the "action
outcomes vs. errors" rule. The in-flight flag is set before the first `await`.
The widget calls `guardedOffline` before confirming. A failure logs
`APPT-REVIEW` and composes `error_introReviewOverdue` ("Couldn't update the
jobs"). Add the tag to the notice-bearing registry in
`.claude/rules/error-handling.md`.

## 4. Side effects, checked

- **No crew pushes.** `notifyAppointmentChanges` gates cancel/reschedule
  events on `hasWorkLeft`, which is false for a job whose end has passed.
  **No admin pushes either — but only since the 2026-09-13 review fix.** This
  line first said "Mark-done sends no push today either", which was true for
  the crew only: `notifyAdminsOfCompletion` pushed every OTHER admin once per
  completed job, so a bulk Complete of 60 jobs was 60 pushes each. The bulk
  write now stamps a fresh `seriesOpId` on every status, and
  `isCrewCompletion` reads a fresh op id as an admin write (the crew mark-done
  rule cannot write one). Side effect, accepted: an admin's edit-form save to
  Done no longer pushes the other admins; the action-bar Mark as complete still
  does, since that single write stamps no op id.
- **Personal blocks and time off never close, so they sit in both reads.** The
  server scans `MONTH_END_SCAN_MAX` (5000) raw rows and caps only the REPORTED
  number at 1000, so they cannot consume it. The app's live query is still
  `.limit(500)` before the Dart filter — accepted 2026-09-13 with prod holding
  15 open-ended rows (12 open personal blocks in total): past ~500 the oldest
  real overdue jobs drop off the screen and `APPT-REVIEW` warns, years away at
  that rate.
- **`completedAt` = when Paul reviewed it**, not when the work happened.
  `stampLifecycle` stamps at the transition, server-side. Accepted: fixing it
  would mean letting a client write a server-owned field. The confirmation copy
  says "stamped with today's date" so it is not a surprise.
- **Live Activities:** `endCardOnTerminal` ends a card on done or cancelled.
  It is a no-op here in practice, since no card is live for a long-ended job.
- **`jobCount`** excludes cancelled (the 2026-09-11 four-bug-fixes Issue 2,
  on `dev`), so a "Not done" lowers that client's count.
- **Dashboard and History** pick the changes up through their existing
  streams.

## 5. Analytics

One event on the success branch only, e.g. `overdue_review_applied` with
`action` (`complete` | `not_done`) and `count`. Both keys must be added to
`AnalyticsParams.allParams`. No ids, client names or dates
(`.claude/rules/analytics.md`).

## 6. Testing

- **jest:** `isLastDayOfBusinessMonth` across 28/29/30/31-day months, the
  DST-shift days, and 23:59 vs 00:00 at the zone boundary;
  `selectMonthEndOverdue` (any age included, personal excluded, missing
  `endTime` excluded, terminal excluded); the rider isolation (a throw does
  not affect the digest or Wave riders) and its position above the Wave rider;
  the recipient filter (an admin with the switch absent or false gets nothing,
  an employee with it true gets nothing, a disabled admin gets nothing);
  the EN/FR/plural text and the cap's "1000+".
- **Dart unit:** month grouping and ordering across a year boundary; the
  Select all / Clear state per month; the controller's `Busy` and chunking.
- **Widget:** empty state; ticking vs opening a card; the action bar appears
  and disappears; both confirmation copies; the notice after success; the
  drawer row visible to admins only with the right count; push-tap routing
  for `overdueReview` vs an appointment id; 260 px × 2× text overflow sweeps on
  the summary and a card.

## Deploy

- **Backend first, as usual.** Old builds degrade (see §2).
  `firebase deploy --only functions`. **Verified 2026-09-12, not assumed:**
  - no index: `appointments (status ASC, endTime DESC)` is already in
    `firestore.indexes.json` and serves both the rider and the app query;
  - no rules change: `allow read: if isAdmin() || ...` admits an admin's
    unconstrained list query;
  - no new export (a rider, not a function) and no backfill.
- **Paul's phone can receive it:** `users/wzGnxcRS7NxZsE3GOA6D/fcmTokens`
  holds two iOS tokens refreshed 2026-09-12. The app never prompts for
  notification permission, so check this again for anyone else the switch is
  later turned on for.
- **After the app build ships, turn the month-end switch ON for Paul** on his
  Team sheet. Until then the rider runs and sends to nobody, silently. It logs
  the recipient count so an empty run is visible.
- The drawer row and the review screen are NOT gated by the switch. Every
  admin can open them; only the push is Paul's.
- The first real push lands on the next last-of-month at 18:00 after the
  deploy. To see it sooner, run the rider's pure pieces in jest; don't fake the
  date in prod.
- New l10n keys in both ARBs: `nav_` (row label), a new review-screen set
  (title, summary, oldest line, selected line, splitter Select all/Clear,
  buttons, both dialogs, both notices, empty state — use the `calendar_`
  bucket, since there is no `overdue_` prefix and inventing one is not
  sanctioned), and `error_introReviewOverdue`.
