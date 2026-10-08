# 0068. Starting-password credential surfaces

**Date:** 2026-08-21 (random password; one nullable password value) · **Rules file:** `.claude/rules/employees.md`

## Context
The new-account dialog and the pending roster row both show an issued email + password and offer "Copy both".
They were separate copies and drifted twice: the confirmed-state icons disagreed, and the dialog tinted its panel
`surfaceContainerHighest`/`r8` against the row's `sheetRow`/`r12`. For a while a `hasPassword` bool defaulting to
`true` ran alongside the nullable password, so a button could say "Copy both" over an email-only clipboard and a
new surface holding no password inherited the wrong label with no compile error. `createAccount` once took loose
named strings; the server's re-provision branch overwrites the pending doc's editable fields, so an omitted field
silently wiped the person's phone or job title — a trap that bit the old Show code and Resend equally, with a new
field threaded through four layers. Since 2026-08-21 the starting password is not persisted, so a row with no
server echo has nothing to render; unlike the retired code flow, expanding a row re-issues nothing.

## Decision
The password lives only in widget/controller state, keyed to its account, never logged (auth catch sites log
through `logger.authFailure`, whose breadcrumb carries only the label and `failure.runtimeType`), noticed or
stored. `credential_line.dart` owns the payload (`copyCredentialsToClipboard`) and the surface widgets. The
"is there a password" fact is one nullable value with required params. `createAccount` takes the whole
`EmployeeRecord`. Only Reset password re-provisions; immediately after a create or reset the row still holds the
echoed pair, which is the moment that matters.

## Consequences
A default on those params, or a second boolean, reintroduces the label/clipboard disagreement.
