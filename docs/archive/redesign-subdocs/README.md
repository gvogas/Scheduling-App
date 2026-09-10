# Redesign sub-documents — P1 through P7

**Every project here is built.** These are the record of how each one was
built — kept for rationale and task history, not as a description of the current
screens. For that read `CLAUDE.md`, which carries every invariant they
established. The program spec is `../2026-07-29-redesign-program.md`; the only
program is COMPLETE: **P6 and P7b were cancelled by owner call 2026-09-06**,
so it owes nothing further.

Left here rather than moved to `docs/archive/` because `CLAUDE.md`,
`docs/CLOUD_FUNCTIONS.md` and the dated audit snapshots cite these paths.

Each document is frozen as it was executed, so a couple of task-list lines still
say "create `docs/plans/<file>.md`" for files that ended up in this folder. Those
are left alone on purpose — the instruction was true when it ran.

**Nothing is open across this folder as of 2026-09-09** — the device runbook
below, the last live document in it, is now fully run. The P5 backend deploy that used to
sit beside it landed **2026-08-11** at `258cc91a` — functions, rules and storage,
25 functions live; see the deploy log in `docs/DEPLOYMENT.md`.

| Project | Plan / handoff | State |
|---|---|---|
| **P1 Foundation** | `2026-07-30-p1-foundation.md` · `-HANDOFF.md` | Shipped (`6a6c18b`..`8b356af`). |
| **P2 Calendar** | `2026-07-30-p2-calendar.md` · `-HANDOFF.md` | Shipped (`d9816fe`). The plan is **superseded in part** — the first hardware pass (P2b) overturned five of its decisions; its own banner says so. |
| **P3 Clients** | `2026-08-01-p3-clients.md` · `-HANDOFF.md` | Shipped; backend deployed 2026-08-01. Its §5b `#pre-ship` delete hole is **closed** — the flag file was deleted 2026-08-03 and `allow delete` on `/clients` was withdrawn 2026-08-08. |
| **P4 Team** | `2026-08-02-p4-team.md` · `-HANDOFF.md` | Shipped; deployed 2026-08-03. §6.3's time-to-leave toggle and §6.4's self-service rules clause are **P5 work** and are tracked in `../README.md`. §7's deploy has long since run — do not re-run it from this doc. |
| **P4b Auth + invites** | `2026-08-02-p4b-auth-invites.md` · `-HANDOFF.md` | ⚠️ **WITHDRAWN.** The signup-code flow was replaced by P4c the same day and deleted from production 2026-08-08. Only the restyled sign-in / reset-password surfaces survive. Nothing in its "still open" list is live work. |
| **P4c Employee accounts** | `2026-08-02-p4c-HANDOFF.md` | Shipped; deployed 2026-08-03, hardened 2026-08-08 with the `email_verified` guard. **Partly superseded 2026-08-21 — read `../../archive/2026-08-21-simplified-auth-design.md` for what is true now** (archived by the 2026-09-06 sweep). Four things the handoff describes at length no longer exist: the `email_verified` guard, the shared `Welcome123!` starting password (now random per account and never persisted), the create sheet's admin toggle (creation always writes `role: 'employee'`), and the Dart `kDefaultStartingPassword` mirror. It stays the record of **how the flow was built** — `CLAUDE.md` and `docs/CLOUD_FUNCTIONS.md` still point here, and its own second banner repeats this warning for anyone arriving from a stale pointer — but it is no longer a description of the current screens. Its §5 production migration is **closed**: prod was queried on 2026-08-08 and had zero `invited` users. |
| **P5 My details** | `2026-08-10-p5-my-details.md` | Shipped; **backend deployed 2026-08-11** at `258cc91a` — the `isSelf() && isAvailabilityOnlyChange()` clause on `/users` and `changeEmployeeEmail`'s `self` branch are both live, so an app build carrying this UI is now safe to ship. **Device-verified 2026-09-09** — all 18 checks of the P5 block reported passing by the owner, run as a technician. Nothing is left on P5. |
| **P7 Dashboard + History** | `2026-08-11-p7-dashboard-history.md` | Shipped 2026-08-11, phases A–D. App-side only — nothing to deploy. The dashboard's **Year** period is **permanently** absent and the six money sections stay omitted — **P7b was CANCELLED by owner call 2026-09-06**, so the aggregate read path they waited on is never being built (a year is ~1,825 jobs against a 1000-doc cap, so Year could only ever report a silent prefix). Don't "add Year back" by widening `fetchInRange`; see `lib/features/dashboard/domain/dashboard_period.dart`. Phase D's chosen design is archived at `docs/archive/2026-08-11-history-restyle.md`. **Device-verified 2026-09-09** in the unrunbooked-surfaces sweep. |
| **Device test** | `2026-07-30-p1-p2-DEVICE-TEST.md` | **CLOSED 2026-09-09.** §0–§10 closed 2026-08-11; the **P5 block (18 checks) passed 2026-09-09** as a technician, and the surfaces with no runbook (P3/P4/P4c, drawer icons + 43 tour steps, closed-jobs agenda, photo cue, restyled History, P7 dashboard) were swept the same day and reported passing as a group. All owner-reported, no console capture — a later contradiction means "re-run that check". The `RawScrollbar` assertion from the P4 pass is still unattributed. |
