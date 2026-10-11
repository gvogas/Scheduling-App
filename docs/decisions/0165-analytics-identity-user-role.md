# 0165. Analytics identity: `user_role` only, from the live doc, no reset on sign-out

**Date:** 2026-09-07 · **Rules file:** `.claude/rules/analytics.md`

## Context
Nothing may identify a person in analytics. A stale role mislabels every event for the rest of the session,
and the resulting report ("employees use the dashboard heavily") reads perfectly plausible. A fresh
sign-in passes through a settled-but-empty doc; a transient Firestore error says nothing about the role.
`resetAnalyticsData` mints a new app instance id, and retention ("do people come back?") is measured
against that id. App version, device model and OS version are automatic Firebase dimensions.

## Decision
`setUserId` is never called; the role goes out as `user_role`. `AnalyticsIdentityListener` follows the live
doc: a settled empty role clears the property, a loading or error read holds it. Sign-out clears
`user_role` at the sign-out site (`delete_account_flow.dart`, `change_password_screen.dart`, right after
`logSignOut`), not via the listener, so `sign_out` and anything after it never carry the old role; it does
not call `resetAnalyticsData`. No property is spent on version/device/OS.

## Consequences
Accepted tradeoff: two people signing in on one handed-over device share an instance id; nothing
identifying is attached to it. Blanking on every transient error would be its own mislabel.
