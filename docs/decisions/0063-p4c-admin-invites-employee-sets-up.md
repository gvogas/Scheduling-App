# 0063. P4c: the admin invites, the employee sets up

**Date:** 2026-08-02 (P4c), 2026-08-08 (`#compat-1.37.1` shim retired) · **Rules file:** `.claude/rules/employees.md`

## Context
P4c replaced the one-time signup-code flow entirely. The admin's person sheet calls `createEmployeeAccount`,
which mints a Firebase Auth account plus an `invited` `users` doc that already carries the real `uid` (the code
flow left `uid` empty until redemption), and returns email + password for the admin to hand over out-of-band
(the new-account dialog right after creation, or the expanded roster row while that echo is in memory). Client
side, `create_account_screen.dart`, both `accept_invite_*` screens, `CodeEntryBoxes`, `signup_code_dialog`,
`InvitePreview`, sign-in's bottom prompt and the `revokeInvite`/`previewInvite` callables were deleted, and
`codeExpiresAt` went everywhere. The deep-link dispatcher was reduced to the appointment branch;
`awaitLoginRoute` and the invite-branch route race went with it. Once every device was on 1.40+ (2026-08-08) the
backend half went too: `invites.js`, `signup_code_utils.js`, the `createEmployeeInvite`/`redeemSignupCode`
callables, the `signupCodes` rules block and TTL entry, and two `allow delete` grants. Design:
`docs/archive/redesign-subdocs/2026-08-02-p4c-HANDOFF.md`.

## Decision
Provision only through `createEmployeeAccount`; the employee signs in normally, both gates route `invited` to
`AccountSetupScreen`, and `completeEmployeeSetup` activates. No code-based invite anywhere in the stack.

## Consequences
An old `esproschedule://invite?code=…` link still sitting in someone's messages falls through to `IgnoredLink`
on purpose — it must not reach a screen that no longer exists.
