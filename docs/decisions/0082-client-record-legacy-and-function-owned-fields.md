# 0082. `ClientRecord`: legacy `businessName` read, function-owned fields never written

**Date:** pre-Wave reshape (legacy shape); `backfillLegacyClientNames` last seen 2026-07-05 (`f10b8107`) · **Rules file:** `.claude/rules/clients.md`

## Context
Pre-Wave-reshape "business-only" client docs stored their name under `businessName` with an empty `name`.
The one-time `backfillLegacyClientNames` function was removed, so the reads in `ClientRecord.fromMap` are
the only thing keeping those docs visible and searchable. The `name` fallback alone was not enough: it only
fires when `name` is blank, so a legacy doc holding a name AND a different business name was unfindable by
the business. A second matcher over the raw map beside the policy had drifted before — a client matched in
the instant local filter, then vanished when the debounced read landed. A doc missing `name` entirely is
excluded by the list/search `orderBy('name')`; the fallback only rescues a present-but-empty `name`.

## Decision
`fromMap` keeps both halves: `name` falls back to `businessName`, and the raw value is carried onto
`ClientRecord.businessName`, which `ClientSearchPolicy.index` indexes. `businessName` is read-only; `toMap`
never emits it (pinned by a test), nor `waveCustomerId`/`wave`/`jobCount`. Every field `toMap` emits is
capped by `isValidClientData` in `firestore.rules` (name/business/first/last/phone/mobile/email, the
address family, a bounded `contacts` array, `type`/`accessNotes`/`onSiteManager`/`billingTerms`/`autoInvoice`).

## Consequences
Stripping either half hides legacy business docs. Emitting `businessName` persists a field the app no longer
owns; emitting a function-owned field is refused by the rules. A new client field without a rules cap passes
the app until a later rules tightening rejects it.
