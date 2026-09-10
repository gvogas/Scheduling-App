# Crew record and role gates

**Status: SHIPPED AND DEPLOYED — ARCHIVED 2026-09-09.** All eight changes are
in the code and the rules half is live. Built 2026-09-06/07 across thirteen
commits — the live admin gate (`b3ca82a2`), the Day Route selector
(`240102b6`), History made admin-only (`c9e5812e`), Recent removed
(`d3440af1`), the job-address toggle (`261efdd6`), the filter back control
(`47b52e2d`), the photo gate (`c17fda1f`, `916e27ab`), the `FieldNote` model
and store (`5697408e`), the subcollection grant (`7a43a7bb`), repository and
provider (`ea3fb808`), the notes UI (`93fde0c7`), the attached client dropdown
(`7159fd26`) and the read/identity failure hardening (`051a6b6d`).
**`firestore.rules` carrying the `appointments/{id}/fieldNotes` grant was
deployed 2026-09-07 at `462a1907`** — until that deploy the feature was inert
in prod regardless of the app build; the note cap is 250, not 200, because
`composeEmployeeName` legitimately reaches 201. See that row in
`docs/DEPLOYMENT.md`, which is the only authority on what production runs. The
implementation plan is
`2026-09-06-crew-record-and-role-gates-implementation.md`; shipping the app
build is tracked in `docs/plans/README.md`, not here.
**Date:** 2026-09-06
**Branch:** `redesgin`
**Mockup:** https://claude.ai/code/artifact/b12a97dd-0058-4d1c-be3c-3e766b0626d3

Eight changes to the appointment flow, the employee interface and the field
record. Three carried real design alternatives and were decided from labelled
A/B/C mockups; the rest had one defensible shape.

---

## 1 — Add New Appointment: remove Recent

Delete the whole path, not just the UI (repo rule: no dead code).

- Delete `calendar/application/recent_clients_provider.dart`,
  `calendar/domain/models/recent_client.dart`,
  `AppointmentsRepository.fetchRecentClientBookings` + its Firebase
  implementation, and `test/features/calendar/recent_clients_provider_test.dart`.
- Strip `ClientPicker.recentClients` / `onSelectRecent` / `_recents()`;
  `AppointmentFormFields.recentClients` / `_selectRecent`;
  `AppointmentFormCallbacks.onResolveRecentClient`.
- Call sites: `add_appointment_sheet.dart:329,355`,
  `details_edit_body.dart:185,236`.
- Drop `clients_recentClients` from both ARBs.

Search is untouched. `ClientPicker._body()` routes to `_recents()` when the
query is empty or the phone is still short; that branch becomes
`SizedBox.shrink()`. The mode switch, the "n of 10" tally, the results panel,
the add-new row and the failure/retry branch all stay.

## 2 — Job address follows the toggle

The toggle is `SelectedClientCard`'s "Use this address for the job", rendered
only when the client has a non-empty address. In `appointment_form_fields.dart`
the non-personal branch skips both the `calendar_jobAddress` label and
`_jobAddress()` when it is present and on:

```dart
bool get _clientAddressInUse =>
    !useCustomAddress &&
    (selectedClient?.fullAddress.trim().isNotEmpty ?? false);
```

The `fullAddress.trim().isNotEmpty` half is load-bearing: a client with **no**
address on file also sits at `useCustomAddress == false`, shows no toggle, and
needs the field on screen or the job can never get an address at all.

Saving is unaffected — `_useClientAddress()` already writes
`client.fullAddress` into `controllers.address` on toggle, and both save paths
read the controller, not the widget. The personal-job branch keeps its
always-visible optional field.

## 3 — Client filter: back button

`ClientsFilterSheet`'s title row gains a leading back arrow that pops with **no
value**. `showClientsFilterSheet` already returns `ClientsFilterPick?` and the
caller treats null as dismissed, so the active filter, the building label and
the list scroll position all survive untouched. Uses the existing `common_back`
key and `AppBackButton`.

## 4 — Day Route crew selector: gate on the live role

The selector is already gated on `widget.isAdmin`, but that is a **route
argument snapshot** — it can be stale, argless, or arrive from a deep link.

- **New:** `isActiveAdminProvider` (`features/auth/application/`) —
  `role == 'admin' && status == 'active'`, derived synchronously off the
  already-live app-wide `currentUserDocProvider`, so there is no loading
  flicker.
- `DetailsViewBody._canRecordFieldWork` re-routes through it instead of keeping
  its own inline `identity.role == 'admin'`.
- `DayRouteScreen` resolves `widget.isAdmin && ref.watch(isActiveAdminProvider)`
  **once**, and that value — not `widget.isAdmin` — feeds the crew picker, the
  `appointmentsInRangeProvider` vs `myAppointmentsProvider` choice,
  `buildDayRoute`, the tour scope and `showEventDetails(showActions:)`.

A non-admin holding a forged `isAdmin: true` argument now gets the employee
screen instead of an all-crew range query Firestore rejects with
`permission-denied`.

Everything else at the top of the interface (drawer, calendar FAB, crew filter,
push-back, edit chip) is already correctly gated — leave it alone.

## 5 — Crew notes, visible to admins — **Option A, chronological thread**

Today `fieldNotes` is one string on the appointment doc, written by the crew and
rendered **only inside the crew's own edit box**. An admin cannot see it, and a
second assignee overwrites the first.

**New subcollection** `appointments/{id}/fieldNotes/{noteId}` —
`{text, authorId, authorName, createdAt}`. Mirrors `appointments/{id}/images`
deliberately, including its additive posture:

| | rule |
|---|---|
| read | admin **or** assignee |
| create | admin or assignee, **and** `authorId` == the caller's bridge `docId` — a note cannot be filed under someone else's name |
| update / delete | **admin only** — a field record must not be quietly editable by the person whose work it documents |
| caps | `text` <= 4000, `authorName` <= 200, `createdAt == request.time`, `hasOnly` the four keys |

`appointment_employee_update_rules_test.dart` pins the parent's assignee
disjunct count at three; this adds no parent disjunct, because the note write
never touches the parent doc.

**Code:** `FieldNote` model + `AppointmentFieldNotesStore` (sibling of
`AppointmentImagesStore`), `appendFieldNote` / `fetchFieldNotes` on the
repository, `appointmentFieldNotesProvider(appointmentId)`.

**UI:** `DetailsFieldRecordView`'s box becomes *add a note* — Save becomes Post,
posting clears the field rather than diffing against a saved string. A new
read-only `DetailsFieldNotesView` renders the thread oldest-first (avatar,
author name, relative time, text) **for anyone who can read the job**, so the
admin sees exactly what the crew wrote, with no compose box. Photos stay their
own section.

**Legacy:** the existing single `fieldNotes` string still renders, unattributed,
at the top of the thread when non-empty. Nothing writes it any more. Its
`allow update` disjunct and `updateFieldNotes` stay — older builds in the fleet
still write that field, and removing the disjunct would break them. No backfill.

*Rejected:* B (panelled entries in `SheetPanel`) — denser but costs a tap to
compose. C (notes + photos + lifecycle stamps on one timeline) — best record of
a job, but the only option that changes the photo model.

## 6 — Employee photos stay visible

Rules and storage already grant assignees read + create on
`appointments/{id}/images` and the bytes at the matching path. This is purely a
client refresh gap, in two halves:

- `DetailsPhotosView` returns `SizedBox.shrink()` when `existingImages`,
  `newImages` and `failedCount` are all empty — and `pendingCount` is not in
  that test. An employee adding the **first** photo to a job watches the whole
  section stay invisible during the upload. **Fix:** count `pendingCount` in
  `hasPhotos`. `PhotoPickerSection` already draws the waiting row.
- Nothing re-reads the subcollection when the background upload lands;
  `_loadStoredPictures` runs once at controller build. **Fix:**
  `EventDetailsController` subscribes to `repo.onLocalWrite` — the same
  singleton repository the uploader appends through, so the event does arrive —
  and re-runs `_loadStoredPictures`. Its existing `_lastKnownImages` guard
  already refuses to adopt a server list over photos the user has edited in the
  sheet.

## 7 — History is removed for employees

**Owner call (2026-09-06): don't filter it, take it away.** The list itself
worked — an employee saw their own completed jobs — but no filter control ever
reached them: `showYear` needs more than one year of history, `showEmployee`
more than one assignee, and a technician's History is scoped to their own jobs,
so both selects hide themselves. Rather than build a filter, History becomes an
admin surface.

A technician can still reach a finished job through the calendar, where closed
jobs sink to the bottom of the day's agenda. This removes a screen, not the
record.

- **Drawer:** `drawerGroups`'s Today row becomes `if (isAdmin) HubTab.liveMap` —
  employees get a two-row group. History stays in the admin Business group
  beside the dashboard.
- **Route:** `AppRoutes.history` takes the same live-Firestore admin gate as
  change 4, degrading to `InvalidRouteScreen` for a non-admin. There is no
  deep-link path to History, so the drawer plus the route is the whole surface.
- **Dead code goes:** `scopeEmployeeId` and its four uses in
  `AppointmentHistoryView`, the employee branch of `_historyQuery`, the
  `employeeId` parameter threaded through `HistoryPager`/`HistorySearchKey`, and
  `test/features/clients/widgets/appointment_history_scope_test.dart`.
  `test/features/navigation/domain/drawer_catalog_test.dart:29` asserts Today
  *contains* History and has to flip.

**What deliberately STAYS — do not let a later audit clean these up:**

- `searchHistory` keeps its server-side `historyScope` guard. It is deployed and
  shipped builds still call it, so removing it is a breaking change
  (`docs/DEPLOYMENT.md` §4a).
- The `emp:<id>:` entries in `historySearchScopes` stay. Changing
  `searchIndexTokens` means changing its hand-mirrored JS twin
  (`functions/search_tokens.js`) and re-running the backfill, and the per-scope
  token budget divides by the scope count.
- `.claude/rules/appointments.md` mentions "the technician's History scope" —
  that sentence needs updating when this lands.

## 8 — Client search: dropdown as you type — **Option A, the address-field idiom**

Results render today as a titled section block *below* the field once the
debounce settles. Chosen: `AddressAutocompleteField`'s exact treatment, so the
client picker and the address picker behave identically.

- `ClientPicker._results` stops building a titled `_Panel` and draws an attached
  bordered list instead — same container, radius and dense rows as the address
  field, at a `sp4` gap under the field.
- The spinner moves into the field's suffix. Searching no longer replaces the
  results with a centred progress indicator, so the previous results stay put
  while the next ones load and the list never jumps.
- The header and match count go, **with one carve-out**: the fallback rung keeps
  a single muted caption, `NO EXACT MATCH · CLOSEST NUMBERS`. Those rows answer
  a query nobody typed and must never read as matches
  (`.claude/rules/appointments.md`). A single canonical phone hit needs no
  caption — it *is* the match.
- Phone mode keeps the number as the mono headline with the name beneath; text
  mode leads with the name and puts the phone beneath.
- The "n of 10" tally stays below the field; "None of these — new client" stays
  the last row of the list.
- Two states the dropdown must still say out loud: a number too short to be
  selective shows the tally and **no list**, and a *failed* search shows the
  error + Retry, never "no clients found" — that is how a duplicate gets created
  for a client already on file.

Nothing behind it changes: same debounce, same `searchClients` callable, same
`ClientSearchStatus`.

*Rejected:* B (header strip inside the dropdown). C (floating overlay) — needs
`OverlayPortal` + `LayerLink` and its own keyboard-inset handling inside a
scrolling sheet.

---

## Testing planned

Widget tests for: the picker with no recents; the address section under both
toggle states including the no-address-on-file case; the filter sheet's back
button preserving the filter; the Day Route gate under a live employee role;
notes visibility for both roles; the photos section with pending-only; the
employee drawer without History and the `/history` route refusing a non-admin.

`firestore.rules` tests for the four `fieldNotes` subcollection grants,
including refusal of a note whose `authorId` is not the caller's.

## Deploy note

Change 5 adds `firestore.rules` grants, so it needs a rules deploy before the
app build that writes crew notes ships. No new callables, no new indexes, no
backfill.
