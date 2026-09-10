# Retired sections of the active-plans index

Moved out of `docs/plans/README.md` on **2026-09-09**, when that index was
trimmed to live work only. Nothing here is outstanding — each section had
closed, and kept accumulating in a file whose job is to say what is left.
They are preserved verbatim because each records how something was decided,
what it cost, or a hazard worth not rediscovering.

The live index is `docs/plans/README.md`; the current state of the code is
`CLAUDE.md`, `docs/ARCHITECTURE.md` and `docs/CLOUD_FUNCTIONS.md`.

---

## Why each one was retired

| Section | Closed | Kept for |
|---|---|---|
| 2. Redesign — P1–P7 | Program COMPLETE; P6 and P7b cancelled by owner call 2026-09-06 | The two PERMANENT consequences: the dashboard's Year period and the six money sections stay absent, and a personal block / day off IS the time-off answer |
| 4. Device verification | CLOSED 2026-09-09 — §0–§10 (2026-08-11), the P5 block and the unrunbooked sweep (2026-09-09), all owner-reported | The §0.7 caveat, and the undiagnosed `RawScrollbar` assertion |
| 5. Live Activities on a multi-day job | Containment shipped 2026-08-11 (`dayCountOf(c) > 1` skips the card) | It is still an unanswered DESIGN question — carried forward so it is not lost with the archived multi-day doc |
| 7. App Store history | The app shipped; four updates are live | That Part 13's boxes were never reconciled, so an unticked one reads as *unknown*, and that the legal pages are published and verified byte-identical |
| 8. Function SDK downgrade | Found and fixed 2026-08-10; the admin ^14 warning retired 2026-09-06 | **The lesson**: the jest suite mocks firebase-admin, so it passed on the broken versions too. After any dependency change there, check the INSTALLED versions directly rather than trusting green tests |

---

## 2. Redesign — COMPLETE. P6 and P7b were CANCELLED 2026-09-06

- **P5 — SHIPPED AND DEPLOYED 2026-08-11**
  (`redesign-subdocs/2026-08-10-p5-my-details.md`). All three phases built and
  live: the rules clause is called and `updateSelfDetails` exists (A); an
  employee moves their own sign-in email through `changeEmployeeEmail`'s new
  `self` branch, with re-auth, confirm-twice and an active-admins fan-out (B);
  and the P4-parked time-to-leave toggle is live end to end (C). **Still not
  device-verified** — the whole self-service path is unreachable as an admin, so
  it needs a **technician** pass, and that is now the only thing outstanding on
  it. Deliberate deviations from the spec, all recorded in the
  plan's decisions section: no duplicate NOTIFICATIONS block (Settings already
  owns it), no duplicate profile card, SCHEDULING scoped to `maxJobsPerDay`, and
  the identity fields explicitly saved behind a Save/Discard bar (owner call)
  while availability keeps apply-immediately.
- **P6 Time off — CANCELLED (owner call 2026-09-06).** It had been deferred
  since 2026-08-10; this closes it and it will not be built. Nothing was ever
  built for it — no `timeOff` collection, no rules, no surfaces — and the last
  trace in the code, a comment reserving the `PushedDestination.timeOff` slot in
  `drawer_catalog.dart`, was deleted with the cancellation. **What stands in its
  place is permanent, not a stopgap:** a personal block / day off makes someone
  read as unavailable because `findBusyEmployees` deliberately does not filter
  it. There is no request/approve flow, no allowance, and there will not be one.
  The design is kept intact in the program spec as the record of what was
  decided.
- **P7b Wave invoice read path — CANCELLED (owner call 2026-09-06).** Never
  started, and will not be. Two consequences are now permanent rather than
  pending, and are documented at their sites: P7's **six money sections** stay
  omitted (empty-omitted rule, not stubbed), and the dashboard's **Year** period
  stays absent — P7b was the aggregate read path that would have served it. Do
  not "add Year back" by widening `fetchInRange`; a year is ~1,825 jobs even at
  5/day against a 1000-doc cap, so it would report a prefix as a total. See
  `lib/features/dashboard/domain/dashboard_period.dart`.

---

## 4. Device verification — CLOSED 2026-09-09, except Siri

`redesign-subdocs/2026-07-30-p1-p2-DEVICE-TEST.md` is the runbook, and it is now
fully run:

- **§0–§10** — closed 2026-08-11 on the owner's report.
- **The P5 block (18 checks)** — **passed 2026-09-09**, run as a **technician**,
  which is the only role that proves anything there (the admin branch of
  `allow update` masks a broken self clause completely).
- **The surfaces with no runbook** — **swept 2026-09-09** and reported passing as
  a group: every P3/P4/P4c screen, the drawer icons + the 43 tour steps, the
  closed-jobs agenda, the photo cue, the restyled History and the P7 dashboard.

**All of it is owner-reported, with no console capture or screenshot behind any
individual box.** So a later contradiction means "re-run that check", not "a
regression against a known-good baseline" — and for the unrunbooked sweep in
particular, nothing enumerates those screens, so treat a finding on one as new
rather than as a regression.

**The one device item still open is the Siri on-device pass** — the six read
intents in `ios/SiriIntents/` have never been exercised by voice, and that is
the whole of what stands between Siri Phases 1–3 and done. The Swift halves of
the multi-day mirrors (widget decoder, Siri snapshot v3) ride on the same pass;
Swift has no test harness here.

If a pass is ever driven from the repo, read §0.7 first: `main()` routes
`FlutterError.onError` to Crashlytics, so overflows never reach `flutter run`
stdout and about a third of the checks are meaningless without the temporary
`dumpErrorToConsole` patch.

One loose end from the P4 device pass is still undiagnosed: a `RawScrollbar`
assertion ("provided ScrollController is attached to more than one
ScrollPosition") seen in the console, with no screen attributed to it.

---

## 5. One deferred design question — Live Activities for a multi-day job

Carried forward from the multi-day design doc (now
`docs/archive/2026-08-02-multi-day-appointments.md` §10) so it isn't lost with
it. A card counting down to an end four days out would sit on the Lock Screen
for the entire job, so **`resolveReminderForAssignee` skips multi-day jobs
outright** (`dayCountOf(c) > 1`, built 2026-08-11) — the `leaveNow` push still
goes out on day 1, which is the only day with a departure time. That skip is the
containment, not the answer: what a multi-day card should actually be (a per-day
card? a countdown to today's window end?) is an unanswered design question.

---

## 7. App Store — SHIPPED. The runbook is now a release checklist, not a launch one

**ES Pro was accepted by Apple and is live**; 1.45.0+72 was the **4th update**
(owner-reported 2026-08-11). The repo has moved on twice since — 1.46.0+73
(2026-08-14) and 1.46.1+74 (2026-08-15) are cut in `CHANGELOG.md`, and nothing
here records whether either has been submitted. (This sentence used to add that
"the photo migration's step 3 is waiting on an app build" — it is **not**: that
migration is complete in all four steps, verified in prod 2026-09-06. See §6.) `APP_STORE_SUBMISSION.md` still reads in places
like a pre-launch document and **its unticked boxes have never been reconciled
against four shipped submissions** — the app record, pricing, the FR
localization, screenshots and "attach the build and submit" were evidently done
during the first release and simply never ticked. Treat an unticked box there as
*unknown*, not *outstanding*; the count is not a work list.

What is genuinely still open, as far as the repo can tell: **the Siri phrases
check** — the one box in Part 6 that is still unrun, the rest of that part having
been re-confirmed passing on hardware 2026-09-09 (owner-reported) — and ASC App Privacy needing
**Precise Location** added. (**The Time Sensitive Notifications entitlement is
DONE** — `com.apple.developer.usernotifications.time-sensitive` is in
`ios/Runner/Runner.entitlements` as of `af92e7fe`; it needs the matching Apple
Developer portal capability on the App ID, which is a console step, not a repo
one.) One is blocked by Firestore itself: the `liveActivityCards` TTL policy
cannot be created yet. **A reconciliation pass over Part 13 is worth doing
once** — it is the difference between a checklist and a list of ghosts.

**The legal pages are NOT on that list — they are published and correct.** All
four (`terms-of-service`, `accessibility`, `support`, and the privacy policy
served as the repo's `index`) return HTTP 200 from `gvogas.github.io/es-pro-legal`
and were verified **byte-identical** to `docs/legal/` on 2026-08-11. Keep it that
way: republishing is part of any edit to those files, not a follow-up task, or
the consent checkbox stamps `termsAcceptedAt` against text nobody has read.

---

## 8. Function SDK downgrade — found and FIXED 2026-08-10, keep it from recurring

`functions/package.json` had been **downgraded** on 2026-08-08 (commit
`0b57e02c`, "updating") from `firebase-admin ^13.6.0` / `firebase-functions
^7.3.2` to `^10.3.0` / `^4.9.0`, with `node_modules` and the lockfile to match.
Production was unaffected — it runs the tree that declared 13.6/7.3.2 — but the
next `firebase deploy` would have installed from that file, and under those
versions `Query.prototype.count` **does not exist** (`@google-cloud/firestore`
4.15.1). Three production paths call `.count()`: `deleteClient`'s
client-has-history gate (`clients.js`), `recountClientJobs`
(`client_job_count.js`) and the Wave outbox depth (`wave/worker.js`) — so a
deploy would have silently broken the one guarantee stopping a client with job
history from being deleted.

`package.json` + `package-lock.json` were restored from the deployed tree
(`b398294d`) and reinstalled: firebase-functions 7.3.2, firebase-admin 13.10.0,
`@google-cloud/firestore` 7.11.6, `Query.prototype.count` present. `npm run
lint` clean.

**The jest suite cannot catch this class of regression** — it mocks
firebase-admin, so it passed on the broken versions too. After any dependency
change here, check the installed versions directly rather than trusting green
tests.

**The "do not bump to `firebase-admin ^14`" warning this section used to carry
is RETIRED (corrected 2026-09-06).** It is in, and has been since the 2026-09-04
maintenance pass: `functions/package.json` declares `^14.3.0` against
`firebase-functions ^7.3.2`, and that is what is installed. The blocker was
never the SDK pairing — it was jest/ESM, and a CommonJS `jose` mock unblocked
it. `npm audit` is clean. See the archived
`docs/archive/MOBILE_APP_AUDIT_2026-09-03.md` for the upgrade record.

---

