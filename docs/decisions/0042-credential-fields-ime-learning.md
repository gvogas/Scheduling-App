# 0042. Credential fields disable IME personalized learning explicitly

**Date:** 2026-08-15 · **Rules file:** `.claude/rules/security.md`

## Context
A field rendering its characters lets a third-party keyboard retain and cloud-sync what was typed.
Every password field here has a Show/Hide toggle, so `obscureText` is no proxy: the instant it is tapped
the field is plain text at the `true` default, and `keyboardType: visiblePassword` does not imply the
flag either. That is how `AuthPasswordField` (both P4c setup fields ride it) and both
`PasswordReauthDialog` variants (then `DeleteAccountReauthDialog`) shipped without it. The four sites
each carried their own restatement of the rule.

## Decision
Set `enableIMEPersonalizedLearning` to `kCredentialImePersonalizedLearning`
(`lib/core/security/credential_input.dart`) unconditionally beside `obscureText` on every credential
field, never a bare `false`.

## Consequences
The named constant is what makes "every credential field" greppable.
