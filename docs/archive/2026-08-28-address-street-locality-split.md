# Address street/locality split

**Date:** 2026-08-28
**Status: COMPLETE 2026-09-09 — and the backfill turned out to have NOTHING TO
DO.** App, backend and script all shipped and deployed 2026-08-28. The live run
this banner asked for is **withdrawn, not pending**: a fresh prod dry run on
2026-09-09 returned

```
[dry-run] clients: 724 scanned, 0 reduced, 724 left alone
[dry-run] 40 have an address but NO city/province/postal/country ... skipped
```

**Zero docs to reduce, so a live run would write nothing.** Don't run it.

**Why the count went 114 -> 0, and it is not a mystery.** The 2026-08-28 figure
was taken **before** the segment-removal guard existed. For the guard to skip a
doc today the segment count must be UNCHANGED — i.e. no locality tail came off —
which is exactly the class described under "What the first prod dry run caught"
below: `streetFromAddress` rejoins with `", "`, so a doc whose tail does not
match its own locality fields still read as "changed" through pure re-spacing.
Two examples of that were spotted in the 114 and read as outliers; on this
evidence they were the whole population, and there was never a meaningful body
of duplicated addresses to clean. The script's decision logic has not changed
since that guard landed — `a808fe03` was the `bootstrapScript` refactor and
`462a1907` only added `scanByName` paging, both verified by diff.
**Two alternatives cannot be fully excluded from the Windows box** — an
unrecorded live run, or the Wave import having rewritten those docs — but each
needs an event nothing recorded, and the import gates on `lastSyncedHash`, which
both address shapes hash identically, so it would have SKIPPED them.
The 40 skipped are the documented rule-2 class (an address with no locality
fields to identify a tail with); they render correctly, because every read
composes.
**Mockup:** https://claude.ai/code/artifact/af063304-88e8-4ab5-818c-0568a67e172c
**Chosen option:** A — one composed line on the detail view

## Problem

`clients/{id}.address` stores the whole picked address string, and the city,
province, postal code and country are then stored a *second* time in their own
fields. The client form shows the duplication plainly: the Address box scrolls
sideways holding a string the four boxes underneath already carry, and editing
the city in one place leaves the two copies disagreeing.

**Root cause is one null.** `AddressParser.parse` extracts the locality parts
but never removes them from the street: `ParsedAddressFields.street` is
`apt?.street`, which is `null` whenever the address has no apt. So
`fillAddressControllersFromText` skips the address controller entirely and it
keeps whatever Places returned.

**Two shapes already coexist in prod.** The Wave import writes
`address = addressLine1` — street only. App-created clients write the full
string. Same field, two meanings, depending on where the client came from.

**There is already a live bug from it.** `contact_export_launcher.dart:137`
composes `street + city + province + postalCode + country`, assuming
street-only. On an app-created client the exported vCard reads
*"1234 Rue Principale, Montréal, QC H2X 1Y4, Canada, Montréal, QC, H2X 1Y4,
Canada."*

## The rule already exists server-side

`streetFromAddress` (`functions/wave/mappers.js:270`) strips trailing comma
segments that duplicate the structured locality fields, **tail-first** rather
than splitting on the first comma — so `100 Main St, Building A` keeps its
second segment. It has no Dart twin. This plan mirrors it, the same way
`ClientNamePolicy` already mirrors `client_name_utils.js`.

## Design

### Two new `AddressParser` members

- `streetOnly(address, {city, province, postalCode, country})` — the tail-strip.
  Hand-mirrors `streetFromAddress`. **Idempotent**: a street-only value passes
  through untouched, which is what makes it safe to apply to a mixed collection.
- `composeFull(...)` — runs `streetOnly` first, then rejoins with the parts.
  Calling `streetOnly` *inside* is what stops a legacy full-string doc rendering
  a doubled city. Not optional.

### Call sites

| Site | Uses | Why |
|---|---|---|
| `address_field_filler.dart` | `streetOnly` | **Fixes it at the source** — writes street-only into the Address controller, so new docs are clean. This is the null-`street` bug above. |
| `client_view_body.dart` | `composeFull` | The Address row and the Directions tile both need the whole address. |
| `ClientTile` | `composeFull` | The list subtitle is what identifies a job site at a glance. |
| `contact_export_launcher.dart` | `streetOnly` | It already composes the parts itself — this kills the doubled vCard. |
| Appointment booking | `composeFull` | **Must compose.** See below. |

### The trap

`AppointmentRecord.address` is a lone one-line string with **no city, province
or postal field of its own**, denormalized at booking and kept forever. Copy the
street-only value there and every job on the calendar loses its city, degrading
directions and the day route. Booking composes.

## Chosen option: A — one composed line

The detail view keeps a single `Address` row rendering
`1234 Rue Principale #4, Montréal, QC H2X 1Y4, Canada` — byte-identical to what
ships today, just assembled from the parts instead of read whole.

Rejected:

- **B — street over locality** (door number bold, locality muted beneath). Reads
  better on site, but the detail already renders correctly today, so a layout
  change buys nothing this change needs.
- **C — separate rows** (Street / City / Postal each their own `KeyValueRow`).
  Mirrors the form, but turns one row into three and pushes the rest below the
  fold on a small phone.

Keeping A makes this purely a data fix with no visual regression surface.

## Wave impact: none — verified

`toWaveCustomerInput` never sends `address` raw; it runs `streetFromAddress`
first. Both stored shapes produce the same payload:

| | stored `address` | `addressLine1` sent |
|---|---|---|
| Today | `"4-1234 Rue Principale, Montréal, QC H2X 1Y4, Canada"` | `"4-1234 Rue Principale"` |
| After | `"4-1234 Rue Principale"` | `"4-1234 Rue Principale"` |

`city`/`province`/`postalCode`/`country` come from their own fields and are
untouched, so the payload is byte-identical.

**No re-sync either.** `mappedFieldsHash` (`mappers.js:365`) hashes the *output*
of `toWaveCustomerInput`, not the raw doc. Same output → same hash →
`shouldEnqueueClientWrite` Rule 1 (`afterHash === mappedFieldsHash(before)`,
`worker.js:235`) returns false and nothing is enqueued; Rule 2 catches it again
against `lastSyncedHash`. **A full backfill therefore pushes zero customers to
Wave** — the trigger fires once per doc and refuses every one. No dead letters,
no rate limit, no roster-wide "Sync pending" badges.

Robust to either stored shape: a doc ending up as `address: "1234 Rue
Principale"` with `apt: "4"` separate hits the `startsWith("${apt}-")` guard and
lands on the same `addressLine1`.

## Migration

**Defensive composition is required regardless** — Wave imports and console
edits keep arriving in both shapes, so `composeFull` must dedupe forever.

**Backfill is optional cleanup**, and recommended: an idempotent `--dry-run`
script normalizing stored `address` to street-only, so the field means one
thing. Confirmed above to be Wave-neutral. Follows the conventions in
`.claude/rules/clients.md` for the other client backfills (idempotent, dry-run
prints the full change list).

## What shipped

`AddressParser.streetOnly` / `composeFull`, surfaced on `ClientRecord` as
`streetLine` / `fullAddress` so the five-field call has one owner across its six
sites. Call sites updated: `address_field_filler` (the source fix),
`client_view_body` (row + Directions), `ClientTile`, `contact_export_launcher`,
`edit_client_sheet` (seeds street-only, so opening a legacy doc doesn't write
the locality straight back), and the three booking sites.

One behaviour change beyond the bug fix: the exported vCard's `formatted` is now
the same composed string every screen shows, so province and postal share a
segment (`IL 62704`) where the old hand-rolled join comma-separated them
(`IL, 62704`). Keeping the hand-rolled join would have put a second spelling of
"the full address" next to the getter that owns it.

Verified: 2881 Flutter tests pass; analyzer clean on every touched file.

## The backend half the plan missed

Writing the backfill surfaced a destructive path the design did not account for.
`propagateClientEdits` compared the RAW `clients/{id}.address` and fanned it
onto future appointments whose stored address still matched. An appointment
carries one address string and **no locality fields of its own**, so the
backfill would have stripped the city off live jobs, unrecoverably.

Fixed by making the propagation compare the COMPOSED address. Because both
stored shapes compose to the same string, normalizing the client field now
propagates nothing — which is the property that makes the script safe, and it
is pinned by a test named for it.

That needed a JS owner for the rule, so `streetFromAddress` moved out of
`wave/mappers.js` into a new `functions/client_address_utils.js` alongside
`composeFullAddress` (a propagation module must not import from `wave/`).
`mappers.js` imports it — one implementation, not two.

It also fixed two pre-existing bugs in the propagation, both silent:

- An apt-bearing client never matched. The app books the composed address
  (`1234 Rue Principale #4, …`) while the doc stores the canonical
  (`4-1234 Rue Principale, …`), so `from` never equalled what the appointment
  held and those clients never took an address correction at all.
- A city-only edit never propagated, because it does not touch `address`.

## The backfill

`functions/scripts/backfill-client-address-street.js` — written, tested, **not
run**. Idempotent, `--dry-run` prints every change (the list is the review
artifact; a live run prints a sample instead).

It cannot lose information: it only removes trailing segments that match fields
still on the same document, so the old string is rebuildable from the doc
exactly. Categorically unlike `backfill-client-name-with-phone.js`, which
replaced a name that existed nowhere else.

Two deliberate refusals: it skips a doc with **no locality fields** rather than
guessing (there `streetFromAddress` falls back to the first segment — right for
the Wave push, a guess for a write that replaces data), and it never writes an
empty address.

Both triggers it fires are verified no-ops — `propagateClientEdits` per above,
and `waveUpsertCustomer` because the hash is over `toWaveCustomerInput`'s
output. So unlike the name backfills it needs no quiet Wave window and can run
whenever.

### What the first prod dry run caught

714 clients scanned, 114 reduced, 600 left alone — and **two of the 114 were
wrong**, both the same bug:

```
"2304,2308,2312 Philippe dolbec"  ->  "2304, 2308, 2312 Philippe dolbec"
"203-3161 Blvd. De La Gare,"      ->  "203-3161 Blvd. De La Gare"
```

Neither removed a locality tail. `streetFromAddress` rejoins with `", "`, so a
`street !== stored` guard fired on pure re-spacing — three civic numbers getting
spaces after their commas, and a trailing comma being dropped. The script was
rewriting data it had no business touching.

Fixed: it now requires a segment to have actually been **removed** (fewer
segments out than in), not merely that the string changed. Both prod values are
pinned as regression tests.

Also worth knowing, not a script problem: a handful of docs carry doubled apt
prefixes — `602-602-3855 Bd de Chenonceau`, `405-405-4450 Prom. Paton`,
`210-210-4450 Prom. Paton`. Pre-existing data quality; the script correctly
leaves the street portion alone.

Run it after the app build has been out long enough to confirm no new
full-string docs are landing.

## Not in scope

Grouping clients by building (discussed 2026-08-28, parked). The `streetOnly`
key would be the natural building key if that is revived — see the same
conversation.
