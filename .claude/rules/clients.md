---
paths:
  - "lib/features/clients/**"
  - "functions/clients.js"
  - "functions/client_*.js"
  - "functions/wave/**"
  - "functions/scripts/backfill-client*"
  - "test/features/clients/**"
---

# Clients (and appointment history)

Loaded when working on clients, the Wave sync, or the History screen. Root context: `../../CLAUDE.md`. Search ranking, the token index and the appointment `_patchWindow` live in `.claude/rules/search.md`.

## The client record

- Keep both halves of `ClientRecord.fromMap`'s legacy read, indefinitely: `name` falls back to a blank-`name` doc's `businessName`, AND the raw value is carried onto `ClientRecord.businessName` for `ClientSearchPolicy.index` — the fallback alone leaves a doc with a name and a different business name unfindable by the business. Don't add a second raw-map matcher beside the policy; that is what drifted before. (ADR-0082)
- Treat `businessName` as read-only: `toMap` never emits it (pinned by a test), nor the function-owned `waveCustomerId`/`wave`/`jobCount`, which `firestore.rules` refuses on any write that touches them (with `buildingKey`, `deletionToken`); an unchanged value passes. (ADR-0082)
- Add an `isValidClientData` type/length cap in `firestore.rules` for every new field `toMap` emits, or a later rules tightening rejects writes the app still sends. (ADR-0082)
- Patch a cached window by MERGING over the stored doc (`_patchWindow`), never substituting `ClientRecord.toMap()` — it omits `jobCount`/`createdAt`, blanking the count until TTL; any new non-emitted field inherits this. (ADR-0087)

## Archive, not delete

- Archive a client; never delete one with history — its visits keep `clientName` but lose the `clientId` link. Archived clients drop out of the paged list and type/building filters but stay searchable and bookable (an unfiltered search includes them, so the row badges them). (ADR-0083)
- Keep `archived` (boolean) on EVERY client doc: the list filters it server-side and Firestore drops docs missing it, so one goes invisible in the list while still found by search. Both create paths stamp it — `_normalizedMap` (`firebase_clients_repository.dart`) and Wave `importCustomers` (`functions/wave/customers_import.js`) — and `syncClientBuilding` stamps it on any write lacking one. The Wave UPDATE branch must never write it, or every import un-archives everything (pinned by a test). (ADR-0083)
- When a client is missing from the list but found in search, run `functions/scripts/backfill-clients-archived.js` (`--verbose` names each doc). (ADR-0083)
- Delete only junk, only through the `deleteClient` callable (`functions/clients.js`): it refuses `failed-precondition / client-has-history` on a LIVE `count()` aggregate, never the lazy `jobCount`. Never re-add `allow delete` on `/clients` — rules can't count a foreign collection, so the callable is the only place the guarantee can live. (ADR-0083)
- Keep the `deletionToken` fence: the callable stamps a token in a transaction, counts, deletes only while it still owns it, and clears its own on failure; `firestore.rules` refuses a booking or `clientId` relink onto a tokened client (`canLinkClient`, a `getAfter`) and any client update while it is set. A retry after a killed attempt takes a new token; never clear another attempt's. The token release has its own try/catch that `logger.error`s and rethrows the ORIGINAL error. (ADR-0083)
- Keep `canDeleteClient` (`domain/policies/client_delete_policy.dart`) advisory only, `jobCount == 0` with null withholding. It reproducibly disagrees with the callable for a client whose only visits were cancelled; keep the gate (it asks "do documents point here") and change the message if it becomes a complaint. (ADR-0083, ADR-0091)
- Put `flutter_slidable` in `ClientsListView._slidableTile`, never inside `ClientTile`, so only the list decides a row is destructible — a safety default, not a live constraint. A full swipe commits Archive only; delete is never gesture-committed. (ADR-0083)
- Route list and detail actions through the one `ClientActionsHost` mixin (`clients/widgets/views/client_actions_host.dart`) so notices, `CLI-ARCH`/`CLI-DEL` and confirm copy can't drift; its hooks stay separate because the detail stays open after archiving (to offer Unarchive) and dismisses after deleting.

## List screen

- Keep the Filter button IN the header row with no chips (the count sentence already names the filter): button, sentence, a ✕ only while a filter is on, the sort control pinned to the end in a `ConstrainedBox` at 55% of the row, never `Flexible` (two flex-1 children split 50/50). The button never scrolls — it is the only way to the addresses and the full sheet. `ClientsFilterBar` keeps its name because `TourStepId.clientsFilter` targets it; pass the header `leading` and `sortWrap` rather than wrapping it — a showcase nested inside another does not resolve. (ADR-0084)
- Keep `ClientsFilter` a sealed one-of, so the sheet is ONE radio group — picking an address clearing a type is not a bug. Keep the radio glyph on the ghost `rFull` pill rows, or colour is the only cue. (ADR-0084)
- Read `clientBuildingsProvider` only from `ClientsFilterSheet`, never a list row or `ClientsListView` — it is a catalog read nobody opening the tab needs.
- Keep `ClientsListView` free of chrome (Filter, ✕ and header live in `clients_screen.dart`) as a design margin; don't cite a second caller — it has none. (ADR-0084)
- Show `total` (`clientsTotalCountProvider`, a family keyed on `ClientsFilter`, counted through the same `_filteredQuery` as the page) under EVERY filter, ignore it while searching, and render nothing for a null count — rows loaded is scroll depth, not the roster. Keep the unfiltered count watched under every filter so a round trip re-counts nothing. Count with `count()`, never a scan. Page size is 50 under every sort. (ADR-0085)
- Leave `kFloatingControlsClearance` at the bottom of all three paths — paged list, grouped card tail, filtered/search results — or the last row sits under the FAB and `ScrollToTopButton` (shared with the calendar's `agenda_sliver_list.dart`; see `.claude/rules/frontend.md`).
- Keep grouping opt-in: `ClientsListView(grouped:)` defaults false; only `clients_screen.dart` passes true. Every list is ONE card, headed by `buildingLabel` under a building filter. No letter headings — pages are ordered on the stored name (a person's bare number), so don't restore `letterGroupsOf`/`clientInitialOf`/`sortClients` without a stored, display-ordered sort key. (ADR-0086)
- Build the card as a `DecoratedSliver` around a `SliverList`, never a `Container` around a `Column`, which builds every loaded row per keystroke; `ClientsSliverList._clipEndRows` rounds the end rows per row because the decoration doesn't clip. Memoize through `RowCache`. (ADR-0086)
- Drive the grouped pager with the shared `paged_sliver_driver.dart`; `PagingController.refresh()` only resets, so it must still `requestFirstPage`. (ADR-0086)
- Make every list filter a SERVER `where` in `fetchClientsPage(filter:)`, never a Dart filter over a page — that shortens a full page and ends the list at the first non-match. `archived == (filter is Archived)`, plus `type ==` or `buildingKey ==`, the sort's `orderBy`, then `__name__`; each filter × sort needs its `(archived[, type|buildingKey], <sort field>, __name__)` composite — `(archived, name, __name__)` serves the default Name sort and Archived — and a search within a filter sends the same keys to `searchClients`, served by `(archived[, type|buildingKey], searchTokens, name)`. (ADR-0087)
- Exclude archived clients from the type and building filters (and building counts); never from an unfiltered search. A non-boolean `archived` or padded `type` is invisible to equality — `syncClientBuilding` normalizes on the next write, `backfill-client-buildings.js` the rest. (ADR-0087)
- Treat `ClientsSort.mostJobs`/`.recentlyAdded` as nullable-field sorts (`ClientsSort.requiresBackfill`): `orderBy` drops docs without the field. `functions/scripts/backfill-client-sort-fields.js` is a release prerequisite and stamps a FIXED pre-app date, never `serverTimestamp()`, or the legacy roster reads as newest; deploy each `(archived, <field> DESC, __name__)` composite READY first. (ADR-0087)
- Make `fetchClientsPage`'s cursor tuple follow the sort and key its boundary cache `"<sort>:<docId>"` — a `name` boundary would resume a `jobCount` query from a string. Don't collapse it to one map. (ADR-0087)
- Store `ClientType.building` as `"building"` with NO `propertyManagement`/`"property_mgmt"` alias (Dart or `BUSINESS_TYPES`); map any stray row forward. An unknown value reads `unset`, flipping `isBusiness` false and exposing the name to the phone rewrite. (ADR-0088)

## Buildings

- Treat `buildingKey` as a SERVER-OWNED projection: `syncClientBuilding` stamps it and keeps `clientBuildings/{sha256(key)}` and `clientBuildingMemberships/{clientId}` in step in ONE transaction, reconciling from the LIVE doc and stored membership, never the event delta (a retry would double-count). Never derive the catalog in the app — that was a 5000-doc scan. (ADR-0089)
- Change `buildingKeyFor` (`clients/domain/policies/client_building.dart`) and `buildingFor` (`functions/client_buildings.js`) together; cases go in `test/fixtures/client_building_cases.json`, never one suite.
- Key on street-without-unit AND city, reduced through `AddressParser.streetOnly` first (legacy docs with locality in `address` must land on the same key); `noFixedAddress` or blank is null. The floor is two clients — one entry per address is just the client list again. (ADR-0089)
- Show addresses as the filter sheet's own section (one sealed `ClientsFilterBuilding(key)`), rendering nothing when no address is shared. Render no shared-address count or Building pill anywhere; the row keeps its type badge. (ADR-0089)
- Treat the building catalog as eventually consistent: an edited address moves groups once the trigger lands; reopening the sheet reloads it. (ADR-0089)

## Wave sync state

- Read the Wave sync badge from a LIVE doc: `ClientDetailView` watches `clientStreamProvider` (`clients_providers.dart`, over `ClientsRepository.watchClient`) and keeps the handed-in record only as an offline fallback. Never move it back onto a passed-in record (its state predates the server's `pending`), or write an optimistic `pending` client-side (only the server knows if a Wave-mapped field changed). (ADR-0090)
- Don't patch the search/scan cache from that listener; the cached copy keeps a stale sync state on purpose. (ADR-0090)
- Keep `upsertCustomer`'s noop short-circuit (`functions/wave/customers.js`) calling `healSyncState`, which re-hashes INSIDE the transaction (an edit landing in the window must not be marked synced) and never writes `lastSyncedAt`. (ADR-0090)

## `jobCount`

- Recompute `jobCount` absolutely, never `FieldValue.increment` (`recountClientJobs` retries), and write with `update()`, not `set({merge: true})`, so a deleted client isn't resurrected as a stub. A row renders nothing (never `0`) until the field exists. (ADR-0091)
- Keep `countJobsFor` the ONE owner of `total − laterRunDays(dayIndex > 1) − cancelled + cancelledLaterRunDays`, shared with `functions/scripts/recount-client-jobs.js` (a release prerequisite). The fourth term is the correction, so never clamp at 0; subtract cancelled rather than allowlisting live statuses, so legacy statuses still count. Needs both `(clientId ASC, dayIndex ASC)` and `(clientId ASC, status ASC, dayIndex ASC)`. (ADR-0091)
- Fire `clientsToRecount` on create, delete, `clientId` change and a cancelled-ness FLIP — not on any status change, so `pending → done` stays zero-read. (ADR-0091)

## Phones and names

- Normalize every stored `phone`/`mobile` (client and contacts) in `_normalizedMap` through `normalizePhoneForStorage` (`core/validators/phone_format.dart`). Keep an extension (`_extensionSuffix`: `ext`/`poste`/`post`/`x`/`p` + digits) as its own trailing token — folding it in stores an undialable number. `isUsablePhoneNumber` refuses under seven digits; empty passes. (ADR-0092)
- Show the additional-contacts count against `kMaxAdditionalContacts` (50, matching the rules' array bound) and stop offering Add at it, rather than letting the server refuse with an unnamed `permission-denied`.
- Keep `EditClientSheet._save` promoting `mobile` into an empty `phone` and clearing `mobile` on every save — it is no longer editable, and a stale one stays matched and pushed to Wave. The Wave import folds the same way (`importedPhone`, `functions/wave/mappers.js`, writing `mobile: ''` and never renaming). (ADR-0093)
- Store a PERSON's `clients/{id}.name` as their bare number (`bareNumber`, keeping a leading `+`), never `ClientNamePolicy._digits`/`digitsOf`, which drop a NANP leading 1; the `phone` field stays formatted. A BUSINESS keeps its name. `ClientNamePolicy` (`clients/domain/policies/`) and `functions/client_name_utils.js` are hand-mirrors sharing worked examples. (ADR-0094)
- Keep `ClientNamePolicy.looksLikeBusinessName` biased toward business — a false negative renames a real company on live invoices; add tokens as dry runs find misses. (ADR-0094)
- Render `ClientRecord.displayName` everywhere, never a person's `name`: a business shows its name, a person `firstName` + `lastName`. `ClientNamePolicy.isBusiness` = `commercial`/`building` plus any legacy `businessName`. (ADR-0094)
- Read both dry-run lists of `backfill-client-name-with-phone.js` in FULL before going live: (1) every client treated as a business and left alone, (2) every rename with no first/last on file. Its base name is the STORED `name`, never `displayName` (that would rename a business to its contact person). `backfill-client-name-digits.js` patches only when `stripPhone(name)` is empty — keep it that narrow — and takes no `--since` (a reformat, not a rename; age is no reason to leave a doc inconsistent). (ADR-0094)
- Compose every save through `ClientNamePolicy.composeSave`, never `composeStored` directly — it would replace the only copy of a typed name; `composeSave` splits it into the halves and never clobbers a populated half. Both sheets pass `type` (and the edit sheet the stored `businessName`), or a save renames a business to its number; seed the edit field from `baseNameFor`, never `displayName` — the Wave import sets no `type`, so `displayName` seeds the contact person and saving renames the customer in Wave. `composeStored` stays idempotent on both branches. (ADR-0095)
- Keep `backfill-client-name-with-phone.js`'s `splitName` the ONLY JS copy of `splitPersonName`. (ADR-0095)
- Make `propagateClientEdits` fan out `clientDisplayName`, not the raw `name` — the app writes the display name at booking, so the raw name puts the number on cards. (ADR-0094)
- Keep the `name` rules cap at 225 (`TextLimits.personName` 200 + 1 + `TextLimits.phone` 24, pinned by `text_limits_test.dart`) — lowering it makes old-shape docs un-updatable. (ADR-0095)
- Lift a number from the name into an EMPTY phone field via `liftPhoneFromNameField`: a field that is nothing but a number lifts at any dialable length; one embedded in a longer name needs exactly ten digits, and a candidate with `+` stays in the name. Call it on both sheets' `onChanged` AND on the seeded name in `AddClientSheet.initState` (a programmatic seed fires no `onChanged`); any new seeding entry point needs the call. A name that is only the number keeps it (the field is required; emptying it looks like the paste vanished). Trim brackets at the seam (`_openSeam`/`_closeSeam`; `OPEN_SEAM`/`CLOSE_SEAM` in JS), never by widening `_edgeSeparators`, which `stripPhone` shares. (ADR-0095)

## Addresses

- Resolve street + apt only through `AddressParser.canonicalFrom` (explicit apt wins; blank keeps the embedded one) in both save paths. (ADR-0096)
- Store `clients/{id}.address` as the street line; compose the rest via `AddressParser.streetOnly`/`composeFull` (`ClientRecord.streetLine`/`fullAddress`). `composeFull` reduces through `streetOnly` FIRST — both shapes exist forever. (ADR-0096)
- Book and launch with the COMPOSED address, never `streetLine` — `AppointmentRecord.address` and `AddressMapLauncher` have no locality fields. (ADR-0096)
- Don't reintroduce a `fields.street != null` guard in `fillAddressControllersFromText`; `ParsedAddressFields.street` is null with no apt. (ADR-0096)
- Make `propagateClientEdits` compare the COMPOSED address, never the raw field, and keep the JS twins (`streetFromAddress`/`composeFullAddress`, `functions/client_address_utils.js`) in step with `streetOnly`/`composeFull` and character-identical (apt via `canonicalToDisplay`, mirroring the four Dart apt patterns IN ORDER); the app's display spelling is canonical for `appointments.address`. Compare raw and `backfill-client-address-street.js` becomes destructive. Pinned by `client_propagation.test.js`. Wave is unaffected by the shape because `mappedFieldsHash` hashes `toWaveCustomerInput`'s OUTPUT. (ADR-0096)

## Booking client picker

- Send a SLICE of the typed number (`PhoneQueryPolicy`); on a miss at 10+ digits retry the first seven BEFORE the last seven (a typo lands in the tail), and label fallback results "closest numbers on file", never matches. Narrow a complete answer locally and re-query a truncated one (`ClientSearchWindow.canNarrowTo`). (ADR-0097)
- Keep `ClientSearchEntry.phoneDigits` one entry per number in `ClientSearchPolicy.index`, the repository's relevance call and `recordMatchesQuery` (`functions/search_tokens.js`); scoring is in `.claude/rules/search.md`. (ADR-0097)
- Re-rank the `searchClients` answer with `ClientSearchPolicy.scoreRecord` in the REPOSITORY, so callable and local fallback agree. (ADR-0097)
- Render `ClientSearchStatus.failed`, never "No clients found" — on the booking path that reads as "new customer" and creates a duplicate. (ADR-0097)
- Don't restore recent clients or build the collapsed match summary; the deleted symbols are listed in the ADR. (ADR-0098)
- Keep `ClientsRepository.addClient` returning the created `ClientRecord` (not `void`) — the booking form links to its id. Open every add-client sheet through `showAddClientSheet` (`clients/widgets/sheets/add_client_sheet.dart`, result gated on `context.mounted`), with `settleFocus: true` from a search field.
- Keep the `ClientPicker` `onAddNew` affordance gated explicitly if ever reused off an admin-only surface. Guard every inline-add host with `InlineAddClientHost` (`requestAddClient`, `calendar/widgets/sheets/inline_add_client_host.dart`) — the settle delays the barrier, so a double-tap stacks two sheets.

## History and Job history

- Render History's date on a LEFT RAIL, leaving `AppointmentCard` untouched; make each month a `SliverMainAxisGroup` — bare pinned `SliverPersistentHeader`s stack. (ADR-0099)
- Call `fetchNextPage()` from a builder post-frame — the controller sets its value synchronously, so mid-build it changes a listenable during layout. Don't give the first-page indicators a scroll wrapper — `AppEmptyState` scrolls itself, and two controllerless primary scrollables crash the Scrollbar. (ADR-0099)
- Render a text search FLAT, with month (+ year when not current, from `currentDayProvider`, never `DateTime.now()`) on the rail; chip filters alone keep month bars. (ADR-0099)
- Show ONE count, `18 JOBS · 2 CANCELLED`, where the cancelled clause is a SUBSET of the total (2 of the 18); search keeps the clause. Never per-month counts — history pages, so one would climb while you read. (ADR-0099)
- Hand `tallyOf`/`monthSectionsOf` STABLE list instances from `RowCache` (`clients/widgets/views/row_cache.dart`), keyed on a record — `PagingState.items` re-flattens per access, so a consumer-side memo is a no-op. A new row-producing path needs its own cache entry. (ADR-0099)
- Keep `HistoryPager.fetchPage`'s `employeeId` and `HistorySearchKey.employeeId` though every caller passes null — they mirror `historyScope` (`.claude/rules/appointments.md`); not dead code. (ADR-0099)
- Read Job history (`ClientJobHistorySection`) via `clientJobHistoryProvider` (re-fetch on `onRecordWrite`, not `onLocalWrite` — a photo or crew note changes nothing listed): `fetchClientHistory` with `pastOnly: true` ordered `startTime` DESC server-side on `(clientId ASC, startTime DESC)` — without `orderBy` the limit takes an arbitrary slice. (ADR-0100)
- Keep the render bound in the provider: the section is a non-lazy `Column`, so a taller list needs a builder, not a bigger number. (ADR-0100)
