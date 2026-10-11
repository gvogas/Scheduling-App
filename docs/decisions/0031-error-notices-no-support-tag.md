# 0031. Error notices carry no support tag; intro plus an actionable cause

**Date:** 2026-08-04 (support tag removed, owner call) · **Rules file:** `.claude/rules/error-handling.md`

## Context
Generic catch-site notices used to end `. (CLI-DEL)` so a user's screenshot mapped to a Crashlytics
line. Once the app stopped being a testing build that was developer scaffolding on a screen a customer
reads, and it took the room the message needed to say what to do next. The cause strings were
lowercase fragments then; they became full capitalized sentences that follow the intro's period, each
saying why and what to do, joined by an em dash.

## Decision
`composeErrorNotice` renders `"{intro}. {cause}"` (`error_noticeWithCause`) with no tag. The tag lives
only as the prefix of the site's `logger.warn` label, which is why the label must still start with it
and why the log-tag registry in the rules file has to stay exhaustive (ADR-0032). `error_causeUnknown`
is deliberately just "Please try again in a moment." — the intro already named the failure.

## Consequences
Re-adding a tag to any user-facing string undoes the decision. A stale registry makes Crashlytics
triage guesswork, because the label is now the only place a tag can be found.
