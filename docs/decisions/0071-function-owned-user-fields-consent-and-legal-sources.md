# 0071. Function-owned user fields, the consent link, and the legal sources

**Date:** 2026-08-05 (terms link), 2026-08-08 (link restored after a revert; legal-site audit), 2026-08-15 (`email` out of `toMap()`) · **Rules file:** `.claude/rules/employees.md`

## Context
`termsAcceptedAt` / `locationConsentAt` are written only by `completeEmployeeSetup`; on the `/users` denylist
(the same posture as `jobCount`/`wave` on clients) a compromised admin session can't forge a consent record. P4c
deleted `codeExpiresAt` from that list. Without the denylist on `allow create`, an admin session that cannot edit
`uid` could create a doc carrying a forged one, and a second doc claiming an existing uid repoints the
`usersByUid` bridge every rules gate resolves through. `EmployeeRecord.toMap()` emitted `email` un-normalized
until 2026-08-15 — latent only because nothing in production calls `toMap()`; a whole-record write carrying it
would rewrite the doc while Auth kept the old address, and it is the key `updateEmployee`'s uniqueness query
reads. The setup screen once demanded acceptance of terms published nowhere and tappable nowhere; ticking the box
stamps `termsAcceptedAt`, so the person must be able to read the terms. A revert dropped the link once. The widget
test in `account_setup_screen_test.dart` exercises only the default locale, so a French rewording would drop the
link with nothing failing. A 2026-08-08 audit found the published support page still describing the signup-code
flow months after P4c.

## Decision
The function-owned fields are on the rules denylists and never in `toMap()`, which exists only to round-trip
editable fields; a future whole-record `set()` carrying them would be an opaque `permission-denied`. The consent
row locates the link key verbatim inside the sentence key in every `supportedLocales` entry (`new_success_strings_test.dart`); a
missing match falls back to one plain span (a missing link beats half a sentence or a `-1` substring crash). A tap
on the link opens the terms; the rest of the tile still toggles the checkbox. The row is a `StatefulWidget` solely to own the recognizer; one built in `build` leaks
on every rebuild. Setup is shown once, so Settings › Legal carries the durable Terms row beside Privacy, both via `AppUrls` (`privacyPolicy`, `termsOfService`). `docs/legal/` holds the
sources; the live site is the separate `gvogas/es-pro-legal` Pages repo, where the privacy policy is the index,
so a relative `privacy-policy.html` link 404s.

## Consequences
Editing `docs/legal/` alone changes nothing a user can read, and if the Pages repo drifts the consent record
points at the wrong text.
