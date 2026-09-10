# Add-job client picker — phone-first, taken on a call

**Date:** 2026-09-05
**Status: SHIPPED AND DEPLOYED — ARCHIVED 2026-09-09.** Design approved
(owner, 2026-09-05) with the four open questions answered the same day (see
**Owner decisions** below), and **built and released the same day** as
1.58.0+87 (`101d0c0a`); the implementation plan's boxes were ticked in
`394d67af`. In the code: `PhoneQueryPolicy`
(`lib/features/clients/domain/policies/phone_query_policy.dart`), `ClientPicker`
and `SelectedClientCard`. The gate this banner carried is **CLOSED** — the
`searchClients` callable went live 2026-09-06 in the 25 → 29 deploy, with its
composite `READY` and the token backfill run (720 clients / 84 appointments);
see the 2026-09-06 rows in `docs/DEPLOYMENT.md`, the only authority on what
production runs. One release prerequisite outlives this doc and is tracked in
`docs/plans/README.md`: `backfill-search-tokens.js` wants a re-run just before
the app build ships, because currently-shipped builds write no `searchTokens`.
**Implementation plan:** `docs/plans/2026-09-05-add-job-client-picker-implementation.md`
**Mockup:** https://claude.ai/code/artifact/aeedb5fe-92a8-455e-9c22-6741a4252b50
(narrowing list + compact keypad, the confirmation card, the address switch off,
and the near-miss state)

## The workflow this is designed for

The admin is **on the phone with the client**. The client reads their number
out; he types it into the add-job sheet while still talking. He enters **ten
digits, in full, every time** — not a name, not a suffix, no leading `1`.

Three consequences drove the whole design, and each reversed an earlier draft:

1. He types a **complete** number, so guidance like "the last four digits are
   enough" is advice he will never take.
2. He is **on a call**, so the match list has to stay on screen and narrow as he
   types — that narrowing is how he confirms *"Marie Tremblay, Wellington?"* at
   digit eight instead of waiting for the tenth. An earlier draft suppressed the
   list until seven digits; that is wrong here.
3. The **keypad must not eat the screen**, because the list is the point.

## Why — what is wrong today

Read out of `ClientSearchField`, `AppointmentFormConcerns.searchClients`,
`search_tokens.dart` / `functions/search_tokens.js`, and `indexed_search.js`.

1. **The list is wrong while he types, and it is tappable.** `kSearchDebounce`
   is 250 ms and `ClientSearchPolicy.shouldSearch` fires on the first
   alphanumeric, so ordinary pauses send `514`, then `514562`, then the real
   number. Worse, `ClientSearchField.build` gates the dropdown on
   `results.isNotEmpty` alone and **never clears it while a new search runs** —
   so at the moment he stops typing, the rows on screen belong to a half-typed
   prefix, with a spinner turning beside them.
2. **A short prefix matches the roster twice over.** `p:514` hits every 514
   number, and `t:514` hits every nameless client too, because for a person with
   no first/last name `clients.name` **is** the digit string and the text index
   emits word prefixes. The callable reads 200 `orderBy("name")` and returns 25;
   digits sort before letters, so that slice is the numerically lowest numbers.
   ~600 wasted document reads per booking.
3. **An over-long number can never match.** `normalizePhoneForStorage` →
   `bareNumber` stores exactly ten digits. `searchQueryTokens` emits one token,
   `p:<all digits typed>`, with **no leading-1 handling and no truncation**. An
   11-digit query is not a substring of a 10-digit string: zero results, always.
   (This is the typo case, not the daily path — a clean 10-digit query *does*
   work today. It was over-weighted in an earlier draft.)
4. **Zero results reads as "new customer".** The empty state offers only
   *Add "…" as a new client*, seeded as the **name**. `ClientNamePolicy._matchPhone`
   lifts a phone out only at **exactly ten digits**, so a 7- or 11-digit seed
   saves a client with a junk name and an empty phone — a record that can never
   be found again. `add_client_sheet.dart` does now lift on the seeded value;
   the ten-digit requirement is the remaining hole.
5. **A failed search is indistinguishable from an empty one.** A thrown
   `searchClients` logs `CLI-SEARCH` and renders the same "No clients found".
   On this flow that is a duplicate created by a network blip.
6. **A mobile match ranks last.** `phoneDigits` is `phone` and `mobile`
   *concatenated* — in Dart's `ClientSearchPolicy.relevanceScore` and in the
   server's `recordMatchesQuery`. The exact tier is unreachable for anyone with
   two numbers, prefix matching only ever tests the main line, and a query can
   straddle the seam and match a number that does not exist.
7. **Nothing ranks in production.** `relevanceScore` runs only on the injected-
   `FirebaseFunctions`-absent fallback, which in practice means tests. The
   callable ends `orderBy("name")` and `_clientsFromCallable` does not re-sort.
8. **The keyboard opens on letters.** No `keyboardType` is set, so every booking
   starts with a tap on `123`. No live formatting either, though
   `formatPhoneNumber` and its input formatter already exist in
   `phone_format.dart`.
9. **The pick is unverifiable.** Selecting sets the field read-only to the
   display name and silently overwrites the job address.

## The decision

### The key property that makes it cheap

Phone matching is a **substring** test and `searchIndexTokens` emits every 3–12
digit substring **from every start position**. So the candidate set can only
**shrink** as digits land: anything matching ten digits already matched the
first six. One query can therefore serve the whole number.

| Typed | Answered by | Network |
|---|---|---|
| digits 1–6 | Recent clients held in memory, filtered live | none |
| digit 7 | The `searchClients` callable, **once** | 200 reads |
| digits 8–10 | Local narrowing of that answer | none |

~600 document reads per booking → 200, and no junk row is ever on screen.

### Two states, one step

| | |
|---|---|
| **Picking** | The list narrows above the **OS phone pad** (`TextInputType.phone`), with a two-way mode switch pinned above the field. About three client rows stay visible; the list scrolls past that. |
| **Picked** | He **taps** the row (it carries an *Attach* button). The keyboard dismisses, the form returns, and the client resolves into a **confirmation card** in the Client slot. |

**The tap is the handoff** — nothing is written to the job until he makes it —
and it is the only moment the layout may move. While typing, non-matching rows
**fade rather than disappear** so nothing jumps under his thumb mid-call. A
digit tally (`8 of 10`) sits in the field.

### The mode switch is load-bearing, not chrome

**The iOS phone pad has no letter key.** A custom pad could have carried its own
`abc`; the system pad cannot. So choosing `TextInputType.phone` *requires* an
in-app way back to a text search, and it has to sit **above the field**, where
it stays reachable with the keyboard up.

Two segments: **Phone** (default) and **Name or address**. There is no separate
address mode — `ClientSearchPolicy.rawTexts` already matches `address`, `city`,
`province` and `postalCode`, so the text search covers both. In that mode the
rows lead with the **name** and highlight the field that matched; in Phone mode
they lead with the **number**.

### Focus states

Five, and the first one removes the biggest implementation risk in the design.

| State | Keyboard | What it shows |
|---|---|---|
| **At rest** | none | Both mode segments live, field reads "Tap Phone to start" |
| **Focused, empty** | phone pad | Recents from memory, `0 of 10` tally |
| **Unfocused, part-typed** | dismissed | Digits kept, ring dropped, list **collapses to one line** ("2 matches — tap to carry on") |
| **Unfocused, error** | none | Red border + shake, `validation_pleaseSelectAClient` |
| **Attached** | none | No focusable field — the card replaces it; *Change* returns to focused-empty with the number in place |

Rules:

1. **Entering through the mode switch avoids the keyboard swap.** Both segments
   are live *before* focus, so choosing a name search never means opening a
   phone pad and changing it. The mid-typing swap still exists but becomes the
   rare path — which matters, because changing `keyboardType` on a focused field
   needs an unfocus/refocus to take effect.
2. **No autofocus on sheet open** (owner, 2026-09-05 — decided against
   always-autofocus and against a FAB-only variant). The keyboard never appears
   unasked, and **the mode switch stays the single way into the field**, which
   is what keeps the `keyboardType` swap off the common path entirely. The cost
   is one tap per booking, accepted. The same sheet also opens from a tapped
   calendar slot, where a keyboard on arrival would cover the time just chosen.
3. **Losing focus never loses the query.** Digits kept, result set kept,
   refocus re-renders from `SearchResultCache` (2-minute TTL, keyed on the
   normalized query) rather than firing the callable again.
4. **Wrap the field in `SheetFocusScroll`**, as the existing client and address
   fields already are, or the pad covers the field it belongs to.
5. **Attaching dismisses the keyboard; nothing else does.** Today both
   `onFieldSubmitted` and the select handler call `FocusScope.unfocus()`. Keep
   it on attach only — an unrequested dismissal costs him the list mid-sentence.
6. **Sheet-from-search still applies** when the inline add-client sheet opens
   from this field: 80 ms settle before `showModalBottomSheet`, double unfocus
   with a 120 ms gap on the way back.

### The confirmation card

Carried over from the earlier "pick in a sheet, confirm on a card" direction —
this is what the owner explicitly asked to keep. Number as the **headline**
(that is what he thinks in), then name, job count and last visit; the client's
address; the address hand-off as a **visible switch**; `Change` (reopens the
picker with the number already in it) and `Remove`.

### The address switch, off

Off is not the same as blank.

- The declined client address **stays on the card, struck through**.
- Under it, **previous job addresses for this client**, newest first with the
  date last visited — one tap, no billed Places call.
- For a building client the rows collapse to **unit numbers** against one
  street, which is the only part that varies.
- The Places search is the **fallback**, not the first offer.
- The existing `calendar_useClientsAddress` link stays as the way back.

### On a miss

Fall back to the **first seven** digits, then the **last seven**, shown as
**"closest numbers on file"** — never as matches. *New client* is demoted to
last and names the number it would create, placing it in the **phone** field.

> **Corrected 2026-09-05 while writing the implementation plan.** This said
> "last seven, then last four", and that ladder does not rescue the typo the
> mockup was drawn around. Stored `5145628332`, typed `5145628233`: last-7
> (`5628233`) misses, last-4 (`8233`) misses, **first-7 (`5145628`) hits**. A
> typo lands in the part of the number you are least sure of — the tail — so the
> slice that survives it is anchored at the head. The last-seven rung stays as
> the second fallback because it catches the other error, a wrong area code.

## Owner decisions (2026-09-05)

1. **The job address MOVES into the WHO section**, beside the card. The card
   owns the switch; `AppointmentAddressField` leaves `_detailsBody`. This
   changes the shape of the add-job sheet and the feature-tour step that
   targets that section.
2. **Use the OS phone pad**, not a custom keypad.
3. **Always require a tap** — never auto-attach, even on a single exact match.
4. **One change, everything together** — the cheap fixes below ship with the
   redesign rather than ahead of it.
5. **No autofocus** when the sheet opens. The mode switch is the only way into
   the field.

### Corrections this forced

- **My "~100 px shorter" argument for a custom pad compared against the wrong
  keyboard.** That figure is against the QWERTY keyboard (~291 pt with the
  predictive bar). The iOS *phone* pad is ~216 pt, so a hand-built pad would
  have saved roughly **25 px, not 100** — about half a row. The owner's call is
  the right one and my recommendation rested on a bad comparison.
- **Auto-attach is out.** I had recommended it on the grounds that an exact
  ten-digit match normally returns one row, so ranking is moot. Requiring the
  tap gives that up in exchange for the app never writing to the form
  unprompted, which is the safer default on a call.
- Two consequences follow from the OS pad and are now part of the design: the
  **mode switch** (no letter key on the system pad) and **three visible rows
  instead of four**, which makes the production ranking fix matter more — the
  right client has to be in the first three.

### Decisions from earlier passes, kept

- **Suppressing the list until seven digits: NO.** Correct for cost, wrong for
  a live call. Solved instead by changing *where the answer comes from*.
- **Leading "last four digits" guidance: DROPPED.** He types the whole number.

## Not in scope

Name search behaviour beyond the `abc` fallback; the clients-list screen; any
change to the token index, `searchIndexTokens` or its JS mirror; the inline
add-client sheet beyond what it is seeded with.

## Before building

- **The address move is approved but is the largest single edit here.**
  `AppointmentAddressField` comes out of `_detailsBody` and into the WHO
  section under the card. Check what else reads it: `_setPersonal` clears
  `controllers.address` for a personal job, `_switchToCustomAddress` /
  `_useClientAddress` stay the state transitions, and `TourStepId.apptDetails`
  currently wraps the section it is leaving.
  RESOLVED: the address block got its own step, `TourStepId.apptJobAddress`,
  and `apptDetails`' copy dropped "Address" — moving a control means re-reading
  the description of every step that named it.
- **Swapping `keyboardType` on a focused field does not reliably swap the
  software keyboard.** The mode switch must unfocus and refocus (or rebuild the
  field under a new key) to force it — without losing the query or bouncing the
  sheet's scroll position. This is the one part of the design most likely to
  feel broken on device.
- **Recents needs a source** — the last ~40 distinct clients off this admin's
  appointments, cached for the session. A client *not* in recents shows nothing
  until digit seven; that gap is accepted but is visible on a call.
- **Local narrowing is only sound if the seven-digit answer is complete.** If
  the callable truncates at `SEARCH_RESULT_LIMIT` there, filtering it further
  hides real matches. That case must say so rather than narrow silently.
- **Previous job addresses** need a read of `fetchClientHistory`
  (`_clientHistoryScanLimit`, 1000) — load it only once the switch is flipped,
  not on the booking path.
- **Unit grouping assumes a stable street part.** Free-typed addresses will not
  always group; ungrouped rows render in full rather than being forced into a
  unit column.
### The eight small fixes — shipping WITH this change, not before it

Owner call: one change, everything together. They are listed separately because
each is independently testable and none depends on the layout work, so they are
the natural first commits inside it. Ordered by what a ten-digit call hits:

1. **Clear the list when a new search starts.** One line. Stale rows are the
   only way to attach the wrong client without noticing.
2. **Stop querying below seven digits** — by answering those digits locally, not
   by hiding the list.
3. **Set `keyboardType` and apply the existing live formatter.** Two lines, and
   it removes a tap from every booking.
4. **Never let a zero result stand alone with a create button.**
5. **Lift the number into the phone field when creating**, at any digit count.
6. **Give a thrown search its own row with a retry.**
7. **Split `phoneDigits`** on both the Dart and the server side.
8. **Rank in production** — the narrowing list makes this visible, since a
   partial number returns several rows whose order is currently arbitrary.
