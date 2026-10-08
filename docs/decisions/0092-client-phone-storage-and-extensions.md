# 0092. Client phone fields are normalized on the way in; extensions are first-class

**Date:** 2026-09-04 · **Rules file:** `.claude/rules/clients.md`

## Context
A mask-typed `phone` and a bare `name` (which IS the phone for a person) were two spellings of one number.
`bareNumber` alone folded an extension's digits onto the number, so `514-555-1234 poste 2` was stored as
`51455512342` — undialable, written silently on an ordinary save — and the old character class accepted any
arrangement of `e`,`x`,`t` (`text` passed) while rejecting `poste` on a bilingual product.

## Decision
`_normalizedMap` runs every `phone`/`mobile` (the client's and each contact's) through
`normalizePhoneForStorage` (`core/validators/phone_format.dart`), the owner `dialableUri` and
`ClientNamePolicy.composeStored` also use. `_extensionSuffix` (`ext`/`poste`/`post`/`x`/`p` + digits) keeps
the extension as its own trailing token; validation checks only the part before it. `isUsablePhoneNumber`
refuses under seven digits (`validation_enterAValidPhone`); empty passes, since a client without a number is
legitimate.

## Consequences
Folding the extension stores a number nobody can dial.
