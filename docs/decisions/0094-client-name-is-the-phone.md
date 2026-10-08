# 0094. `clients.name` is Wave's customer name: a person's bare number, a business's name

**Date:** 2026-08-08 (phone-from-name backfill), 2026-08-14 (name is the phone; prod run), 2026-08-16 (bare digits), 2026-09-28 (restore scripts deleted) · **Rules file:** `.claude/rules/clients.md`

## Context
`toWaveCustomerInput` syncs `name` verbatim to Wave's customer list and invoices, where people are identified
by number, unpunctuated. `backfill-client-phone-from-name.js` (prod 2026-08-08) lifted the number into
`phone` and renamed `name` to "First Last", renaming every such customer in Wave too. The 2026-08-14 prod run
of `backfill-client-name-with-phone.js` predated the first/last split and destroyed 504 names; the only copy
left was `clientName` on SETTLED appointments (`propagateClientEdits` gates on `hasWorkLeft`).
`restore-client-name-halves.js` wrote those back into the halves, never touching `name`, and its read-only twin
`docs/audits/audit-renamed-client-names.js` was kept in step with it; both scanned appointments ordered
`startTime` DESC on `(clientId, startTime DESC)`, since an unordered `limit` takes an arbitrary slice. Both
were deleted 2026-09-28 (in git history). `baseNameFor` once carried a pointer to a `functions/` function that
never existed.

## Decision
A PERSON's `name` is `bareNumber(phone)` — digits only, keeping a leading `+` — never
`ClientNamePolicy._digits`/`digitsOf`, which also sheds an 11-digit NANP leading 1 (right for comparing, wrong
for storing). A BUSINESS keeps its name. `ClientNamePolicy.looksLikeBusinessName` is biased to business (any digit left after
stripping the client's own number, or a company/property token like `inc`/`ltée`/`group`/`syndicat`/`copropriété`, accent-folded and letter-bounded). The app
renders `ClientRecord.displayName`, never `name`; `ClientNamePolicy.isBusiness` counts `commercial`/`building` plus legacy
`businessName`. `backfill-client-name-digits.js` (no `--since`) patches only when `stripPhone(name)` is empty; it stays idempotent because `stripPhone`
digit-matches rather than only suffix-matching, so keep it that way.
The backfill's base name is the stored `name` and `patchFor` writes the halves in the same patch; `ClientNamePolicy.baseNameFor` is Dart-only. The `phone` field stays formatted as `PhoneInputFormatter` masks it.

`propagateClientEdits` fans out `clientDisplayName`, because the app writes the display name at booking and
the raw name would put the number on cards. Dry run lists, both read in full: (1) every client treated as a
business and left alone, (2) every rename with no first/last on file.

## Consequences
A false positive leaves a client named as it was; a false negative renames a real company on live invoices —
hence the bias, and the dry run listing every match in full. Expect to add tokens from the data.
