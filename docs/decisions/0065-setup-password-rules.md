# 0065. Setup password rules: trimmed, Unicode, and never the starting password

**Date:** 2026-08-21 (starting-password probe; `PasswordRequirement.symbol` removed — `symbol` is gone from the policy) · **Rules file:** `.claude/rules/employees.md`

## Context
Setup used to reject `kDefaultStartingPassword` by name in `account_setup_screen.dart`. That constant went with
the shared password on 2026-08-21, and the check was deleted on the reasoning that a random password leaves
nothing to re-choose accidentally — which ignored the person reading the starting password off a message while
filling the form; the hole was closed the same day. Every generated password (12 characters, upper, lower,
digit) satisfies `AuthValidators.newPassword` / `PasswordRequirement.allMetBy` by construction, and
`updatePassword` accepts a no-op, so setup would leave the account `active` on a credential the admin still
holds while `auth_setUpYourAccountBody` promised the temporary one stops working. Separately, raw-text
validation let `"Aa1!bcd "` pass the 8-character rule and store 7, and an ASCII letter class on the server
refused `Éric2024` behind a green checklist.

## Decision
`AuthService._refuseIfStillTheStartingPassword` reauthenticates with the trimmed candidate before the callable:
success means it is still the current credential → `AuthFailureStartingPasswordReused`, a field error. The
client never sees the generated password, so it tests rather than compares. It lives in `AuthService`, not the screen, because
setup has two routes in (`login_screen.dart`, holding the typed password, and a cold start through
`SplashScreen`, which does not). The policy is 8+ with an uppercase and a lowercase Unicode letter and a digit,
validated trimmed on both sides; `completeEmployeeSetup` maps Auth's policy refusals to `invalid-newPassword`
instead of an internal error. The `AccountSetupScreen` guards stay: consent in the submit handler, an
already-active failure walks them in, and abandon is a plain `signOut` (the rules deny an invited account every
collection push, presence and Live Activity registrations write).

## Consequences
Treating any reauth error other than the three wrong-password codes as "different" lets a network blip through;
not accepting all three dead-ends setup. Don't re-add a name-based comparison (there is no constant) or a shared
default.
