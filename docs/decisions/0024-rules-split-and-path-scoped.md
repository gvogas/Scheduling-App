# 0024. Rules split out of root `CLAUDE.md`, committed and path-scoped

**Date:** 2026-08-14 (`.claude/` committed; calendar and feature-tour rules split), 2026-08-19 (most `.claude/rules/` files split), 2026-09-02 (appointment assignee/job-record set), 2026-09-07 (`analytics.md`), 2026-10-07 (`search.md`) · **Rules file:** `CLAUDE.md`

## Context
Root `CLAUDE.md` loads in every session and had grown to ~155k chars. Subject rules moved to
`paths:`-scoped files that load only when a matching path is touched — verified working: a `paths:` rule
is absent from context until its paths are touched — which took the file to ~31k. Before 2026-08-14
`.claude/` was gitignored and `docs/ARCHITECTURE.md` was the only copy anyone else could read; it is
COMMITTED since (private repo, worked from both a Windows box and the Mac), so rules, skills, agents,
commands and hooks reach every clone. Only `.claude/settings.local.json` stays ignored (machine-local).

Splits, by date: `lib/features/calendar/CLAUDE.md` and `lib/features/feature_tour/CLAUDE.md`
(2026-08-14); `images.md`, `appointments.md`, `employees.md`, `clients.md` and
`lib/core/navigation/CLAUDE.md` (2026-08-19), with the appointment assignee/job-record set following
on 2026-09-02; `notifications.md`, `wave.md` and `firestore-indexes.md` out of `functions/CLAUDE.md`
(2026-08-19), because each spans more than that one directory; `analytics.md` (2026-09-07);
`search.md` (2026-10-07). The calendar UI split because it is pure Flutter with no `functions/` twin;
anything with a server-side mirror stayed out of it. Each file's `paths:` frontmatter is the only record of where it loads.

## Decision
Root keeps a short topic index; each rules file owns its subject.

## Consequences
Keep the index in step when a file is added or split; `docs/ARCHITECTURE.md`'s Test Strategy mirrors
`testing.md`.
