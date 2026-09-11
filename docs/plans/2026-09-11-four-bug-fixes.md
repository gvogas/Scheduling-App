# Four bug fixes — client search, cancelled job counts, Done row badge, filter re-apply

**State: PLAN ONLY — nothing built, nothing deployed.** Written 2026-09-11 from
four parallel read-only investigations plus one follow-up pass. Owner approved
the scope decisions in §6; **implementation approval not yet given.** Issue 3
needs one more owner decision — see §3.

Branch at time of writing: `dev` (clean), last commit `ae72ce83`.

| Issue | Layer | Deploy needed? | Ready to build |
|---|---|---|---|
| 1 — one search bar in Add Appointment | Dart UI only | **No** | Yes |
| 2 — cancelled jobs counted as jobs | Cloud Function + index + backfill | **Yes** | Yes (deploy gated separately) |
| 3 — Done row shape in the agenda | Dart UI only | No | Yes |
| 4 — filters don't re-apply | Dart UI only | No | Yes |

---

## 1. Issue 1 — one search bar matching name AND phone

### Root cause

There were never two inputs. `ClientPicker`
(`lib/features/clients/widgets/fields/client_picker.dart:17`) renders **one**
`TextFormField` plus a two-segment mode switch (`_ModeSwitch`, `:163-198`) that
reconfigures it. Phone is the **default** mode
(`client_search_status.dart:15`), and it installs `PhoneInputFormatter`
(`lib/core/validators/phone_format.dart:105-119`), which reduces input through
`phoneDigits` and **discards letters outright**. A name is untypeable until the
user finds and taps the other segment — and switching segments clears the field
(`add_appointment_sheet.dart:139`), so a half-typed query is lost.

The search layer below is **already a single query**. `searchClients`
(`appointment_form_concerns.dart:117-212`) re-derives the mode from the query
text on every keystroke (`:119-121`) and both branches call the **same** callable
with one free-text `query` key (`functions/indexed_search.js:84-120`).
`searchQueryTokens` emits both `t:` and `p:` token families from one string
(`lib/core/search/search_tokens.dart:7-17`), and both suites already pin
`searchQueryTokens('Marc 514') == ['t:marc','t:514','p:514']`
(`test/core/search/search_tokens_test.dart:12-17`,
`functions/__tests__/search_tokens.test.js:20-22`). **The index and server have
supported one bar since 2026-09-04.** The mode switch is a UI artifact of the
1.58.0 phone-first picker, not a search-layer limitation.

### Fix

1. `client_picker.dart` — delete `_ModeSwitch` (`:163-198`), `_Segment`
   (`:200-240`) and the render at `:55`. Make `keyboardType` and
   `inputFormatters` unconditional (`:59-60`): `TextInputType.text`, no
   formatter. **Removing the formatter is the change that makes a partial name
   and a partial phone both typeable in one query** — `canonicalDigits`
   (`phone_query_policy.dart:28-34`) and `ClientSearchPolicy.digitsOnly` already
   strip dashes, parens and spaces from whatever was typed.
2. New hint key `clients_searchNameOrPhone` ("Search by name or phone") in both
   ARBs with its `@key` block; retire `clients_modePhone` and
   `clients_modeNameOrAddress` from both. An ARB edit fires the auto gen-l10n
   hook — do not re-run `flutter gen-l10n` manually.
3. Remove the now-dead plumbing, all in one commit or the build breaks:
   - `AppointmentFormCallbacks.onClientQueryModeChanged`
     (`appointment_form_fields.dart:73`, `:93`, `:396`)
   - `_onClientQueryModeChanged` in **both** hosts
     (`add_appointment_sheet.dart:134-141`, `:373`;
     `details_edit_body.dart:98-105`, `:226`)
   - `AppointmentFormConcerns.setClientQueryMode`
     (`appointment_form_concerns.dart:92`)
4. **Keep `_resetSearch`** — `searchClients` calls it at `:126`, `:132` and
   `:210`; the `:210` failure path is what stops a failed search rendering as
   "no clients found" and inviting a duplicate client.
5. Keep everything else in `searchClients` untouched: the derived mode, the
   <7-digit hold (a cost guard with a visible tally, **not** a result-dropping
   branch), the `ClientSearchWindow` narrowing, and the `PhoneQueryPolicy` rung
   ladder that rescues a transposed digit.

`status.mode` stays — the result rows and the tally key off it
(`client_picker.dart:77-80`, `:120-140`). With no switch it only flips once a
search has run, so the first keystroke of a phone query renders text-mode rows
for one frame. Cosmetic; the widget tests assert on it.

### Owner decisions applied

- **Standard text keyboard accepted.** The numeric keypad goes. This is a known
  regression against the deliberate 1.58.0 "admin on a call, client reads out ten
  digits" workflow (`docs/archive/2026-09-05-add-job-client-picker.md`), taken
  knowingly in favour of one bar.
- **No `+1` handling needed.** Owner: "There will be no phone with a +1." The
  known mixed-query gap (a `+1` inside `"Marc +1 514 562 8332"` produces an
  11-digit `p:` token that is not a substring of a stored bare-10 number) is
  therefore **out of scope**, which is what keeps this issue deploy-free.
  Pure-digit `+1…` queries already work via `canonicalDigits`.

### Blast radius

- The **edit-appointment** flow shares the picker via
  `appointment_form_fields.dart:390` and must be re-tested; its handlers are
  byte-equivalent to the add flow's and must be deleted in the same commit.
- `PhoneQueryPolicy` and `ClientSearchWindow` keep every caller and every test.
  **Do not delete the ladder along with the switch.**
- Known residual, unchanged: a mixed query matches with **OR** semantics
  server-side (`functions/search_tokens.js:210-211`) and `relevanceScore` scores
  a phone-prefix hit at tier 2 regardless of the name half, so `"marc 514"`
  returns every 514 client without floating Marc. Results stay usable (the
  requirement) but are not well ranked.
- Untouched: `clients_screen.dart`'s `AppSearchBar`, `searchHistory`,
  `findAppointmentConflicts`, the Wave import's `searchTokens` write.

### Tests

- `test/features/clients/widgets/client_picker_test.dart:49` (asserts both
  segments and the "Tap Phone to start" hint), `:58` (tally), `:130`.
- Add: a query containing letters AND digits returns results.
- `add_event_controller_test.dart:250-320` needs no change — it drives
  `searchClients` directly and its derived-mode assertions still hold.

---

## 2. Issue 2 — cancelled jobs counted as jobs

### Root cause — two mechanisms, both required

**A. The aggregate has no status filter.** `recountOne`
(`functions/client_job_count.js:72-95`) computes
`total − laterRunDays(dayIndex > 1)`. Only the later days of a multi-day run are
subtracted; **status is never consulted**, so a cancelled appointment is a job.

**B. The trigger never fires on a cancellation.** `clientsToRecount` (`:56-64`)
returns `[]` unless `clientId` **changed**. Cancelling sets `status` and leaves
`clientId` alone, so `recountClientJobs` (`:147-185`) exits at `:160` having
written nothing. **Fixing the aggregate alone changes nothing.**

`clients/{id}.jobCount` feeds the Clients row badge (`client_tile.dart:93-113` —
the repro's "3 jobs"), the booking form's "3 jobs · last …"
(`selected_client_card.dart:78-86`), and the **server `orderBy` behind the "Most
jobs" sort** (`clients_sort.dart:9`, `firebase_clients_repository.dart:115-138`).

Everywhere else the app already has the right owner — `countsAsWork`
(`appointment_day_slice.dart:89-94`) — and uses it. `jobCount` is the one count
expressed as a Firestore query, where that Dart predicate is unreachable.

### Fix

**Change 1 — fire on a cancellation** (`clientsToRecount`, `:56-64`). Recount
when an unchanged `clientId` had its cancelled-ness flip, tested through the
existing owner `isCancelledStatus` (`functions/time_utils.js:71-73`), never a
re-spelled `=== 'cancelled'`. Gate on **cancelled-ness, not "status changed"**,
so an ordinary `pending → done` edit keeps its documented zero-read property. A
batch run cancel fires N triggers but `mayShareABatch` (`:140-145`) already
collapses them through `debounceRecount`.

**Change 2 — exclude cancelled from the aggregate** (`recountOne`, `:72-95`).
Target set is `{clientId == X, NOT dayIndex > 1, status != cancelled}`, by
inclusion–exclusion over four `count()` aggregates:

```
jobCount = total
         − laterRunDays            (dayIndex > 1)
         − cancelled               (status == 'cancelled')
         + cancelledLaterRunDays   (status == 'cancelled' AND dayIndex > 1)
```

**The fourth term is not optional.** One live 5-day run plus one cancelled 5-day
run computes `10 − 8 − 5 = −3` without it. Clamping at 0 is also wrong — the
right answer is 1 — so the fourth aggregate is the correction, not a guard.

**Do NOT use a `status in [...]` allowlist instead.** It needs one fewer
aggregate but silently drops a legacy `confirmed` doc or one with a missing
`status` — the trap already documented for `countFutureAssignments`. Subtracting
cancelled keeps unknown statuses counted as jobs, which fails in the safe
direction.

**Accepted limitation, to be stated at the site:** a Firestore `where` cannot
lowercase, so a console- or Admin-SDK-written `"Cancelled"` still counts.
`firestore.rules`' `isValidAppointmentStatus` holds every *client* write to the
lowercase allowlist, so this is console-only.

### Index — new composite required

`clientId == , status == , dayIndex >` adds an inequality and needs
`appointments (clientId ASC, status ASC, dayIndex ASC)` in
`firestore.indexes.json`.

**Deploy indexes first and let them reach READY before the function.** That
trigger is `retry: true` and rethrows (`:91-94`), so a missing index is a
`FAILED_PRECONDITION` redelivery loop, not a silent no-op.

Unverified: whether `clientId == ` + `status == ` alone is served by index merge.
If not, add `appointments (clientId ASC, status ASC)` too. Check against the
emulator or the console's index suggestion before deploying.

### Backfill — a release prerequisite, not a follow-up

`jobCount` is lazily maintained: a client self-heals only on its **next**
appointment write. Every client with an existing cancelled visit keeps an
inflated count indefinitely, including its position under "Most jobs".

New `functions/scripts/recount-client-jobs.js` following the established
`bootstrapScript` + `scanByName` + `--dry-run` pattern, recomputing every client
through the same four aggregates, idempotent, printing old→new per doc.

**Not** an extension of `backfill-client-sort-fields.js` —
`planClientSortPatch` deliberately never rewrites a non-zero `jobCount`
(`functions/client_sort_backfill_policy.js:17-19`, pinned by
`functions/__tests__/client_sort_backfill_policy.test.js:31-34`), which is
exactly this case.

Run the `--dry-run` **immediately before** the live run — a dry-run count goes
stale, and any `clients` write fires the `runWaveDaily` rider. Record the prod
run in `docs/DEPLOYMENT.md`'s deploy log.

### Rules

**No change.** `jobCount` is already function-owned and rejected on every client
create/update (`firestore.rules:587-600`); the Admin SDK bypasses rules.

### Scope — owner decision applied

`clients.jobCount` **only**. Two other counts include cancelled *deliberately*,
each rendering the cancelled figure beside the total, and both stay as they are:

- `history_grouping.dart:56-59` (`tallyOf`) → `18 JOBS · 2 CANCELLED`, where
  cancelled is documented as a subset of total, never an addition
  (`.claude/rules/clients.md:674-686`). Excluding it makes the line read as 20
  rows.
- `dashboard_stats.dart:25` (`TodayOps.total`) → the hero's big number, whose
  legend below it breaks out a red cancelled segment (`dashboard_hero.dart:33`)
  and whose `_StatusBar` uses it as the flex denominator (`:117-140`).

### Blast radius

1. **`canDeleteClient` vs `deleteClient` will disagree reproducibly.**
   `canDeleteClient` is `jobCount == 0` (`client_delete_policy.dart:13`), but
   `deleteClient`'s gate is a **live** `count()` with no status filter
   (`functions/clients.js:42-50`). A client whose only appointments are cancelled
   will read 0, the UI will offer Delete, and the callable will refuse
   `failed-precondition / client-has-history`. **Owner default: leave the gate
   alone** — it asks "do documents point at this client", the right question for
   protecting orphanable history. Change the message, never the gate, if the
   mismatch becomes a complaint.
2. **"Most jobs" ordering changes for real clients.** A client whose corrected
   count reaches 0 does **not** vanish — the field still exists; the
   disappearance risk in `.claude/rules/clients.md:129-139` is about a *missing*
   field.
3. **Write amplification:** cancel/un-cancel now costs a debounce claim + 4
   aggregates + 1 client `update()` where it previously cost nothing. Each client
   write re-fires `propagateClientEdits`, which gates on name/phone/address
   change — harmless but real invocations.
4. `_patchWindow` unaffected: `ClientRecord.toMap()` never emits `jobCount`
   (`client_record.dart:148`), so the cached-window merge preserves the server
   value as it always did.
5. `clientRecountClaims` sees more traffic. Keep the change inside
   `client_job_count.js` — never in `recount_claim.js`, shared with
   `pictureCount`.
6. **Nothing else reads `jobCount`.** Verified: no Wave path, no Swift surface.
   `CarPlayStrings.swift:77`'s `jobCount(_:)` is an unrelated row-count
   formatter.
7. `clients_jobsCountLabel` (JOBS / VISITES) and `clients_jobsAndLastVisit` stay
   accurate; their `@key` descriptions should gain the exclusion note the
   calendar keys already carry (`app_en.arb:449`).

### Already correct — regression surface, do not touch

Verified as already excluding cancelled: the agenda header `_jobLabel`
(`main_calendar_screen.dart:409-420`), month-grid dots (`dottedJobsOn`),
`closedJobCount`, the week agenda's per-day bar, the drawer badge,
`employeeJobsTodayProvider` and `employeeTodayJobsProvider`, all four
`dashboard_aggregator` sections, `day_route.dart:61`, the home widget (both
halves of the hand-mirror), the Siri snapshot, all CarPlay counts (safe because
the snapshot already dropped cancelled), `notification_policy.js:238`, and
`countFutureAssignments`.

### Tests

`functions/__tests__/client_job_count.test.js` — `fakeDb` (`:104-145`) models
exactly **two** aggregates off one base query and asserts `calls.wheres` equals a
two-element list (`:182-185`); it must grow to model the status legs. New cases:
a cancelled single-day job doesn't count; a cancelled 5-day run counts 0; one
live + one cancelled run counts 1; a legacy/unknown status still counts. For
`clientsToRecount`: a cancel recounts, an un-cancel recounts, `pending → done`
recounts nothing (the zero-read property).

---

## 3. Issue 3 — the Done row in the agenda

### There is no sizing defect. The word "squished" points at something else.

A full constraint walk of the collapsed Done row found **no geometric defect at
all**, and this is now settled rather than assumed:

- **No asset anywhere.** `pubspec.yaml:136-143` declares one asset, the brand
  mark; there is no `flutter_svg` / `vector_graphics` dependency. Every status
  glyph is a font glyph, which layout cannot stretch.
- **Zero `BoxFit.fill`, `Transform.scale`, `AspectRatio`, `OverflowBox`,
  `FittedBox` or positioned glyph** in the card path.
- **`_kClosedMinHeight = 48` is a `minHeight`, not a max** — it can only make the
  row taller. Measured height at 1.0× on a 390 px viewport is ~64 px, so the
  floor is not even binding.
- **Non-flex children get unbounded main-axis constraints** in both the `Column`
  (`:182-185`) and the inner `Row` (`:534-541`), so the warning glyph, the photo
  glyph and the status pill all take their natural size regardless of the row's
  tight height.
- **The only clip is `ClipRRect(radius 15)`** at `:115`, and it intrudes ~0.03 px
  at the 14 px inset where the glyphs sit. Nothing is cut.
- **Both glyph wrappers are byte-identical across collapsed and full rows** —
  they share the *same* `_TitleRow` instance, built once at `:168-175` before the
  `if (model.collapsed)` branch at `:177`. The overdue warning cannot even appear
  on a Done row: `displayStatus` returns the stored status unchanged once
  `isClosed` (`appointment_record.dart:134-138`).
- **There is no status→icon map and no Done-specific icon, checkmark, badge or
  chevron.** `StatusChip` is text-only; the collapsed row has strictly *fewer*
  elements than an open card. "No chevron" is a deliberate design call
  (`docs/archive/2026-08-08-completed-jobs-agenda.md:35,65-67`).

### What is actually wrong — a zero-contrast token collision

`appointment_card.dart:160-162` tints a collapsed Done card with
`statusColors.successContainer`. `status_chip.dart:53-56` fills the "Complete"
pill with **the same token**. In light theme both resolve to
`AppColors.greenFill` `#FFE6F5EF` (`app_status_colors.dart:49`,
`design_tokens.dart:51`) — **contrast ratio 1.00**, so the pill's capsule
disappears and only its text remains.

Every other status puts a differently-tokened pill on `colorScheme.surface` —
including **cancelled collapsed rows in the very same closed block**, because the
tint branch is gated on `isDone`. So four badges sit side by side in one block,
three are rounded capsules with 10 px of side padding, and the Done one is naked
text that reads narrower and flatter than its neighbours.

In **dark** the token is `0x292BC48E` (16 % alpha,
`app_status_colors.dart:69`), so it double-composites and the capsule stays
faintly visible — which is why this is a light-mode-only complaint and why it was
never caught. Second collision on the same constant, worth knowing before picking
a fix colour: light `secondaryContainer` is *also* `greenFill`
(`themes.dart:59`), so a **selected** card and a collapsed Done card are the same
colour.

### A separate defect found on this row — recorded, NOT in scope

**The owner chose option B below, not this.** Written down so it is not
re-discovered later as new. If it is ever taken, the fix is to give the collapsed
Done row a tint that is not the chip's own fill, rather than
touching `StatusPill` (shared by the detail header, the day-off strip, History's
filter chips and `UserStatusChip`):

```dart
// The chip's own fill IS successContainer, so tinting the card with the same
// token erases the pill on exactly the rows the tint marks.
if (model.collapsed && model.status.isDone) {
  return Color.alphaBlend(
    theme.statusColors.successContainer.withValues(alpha: 0.45),
    theme.colorScheme.surface,
  );
}
```

Keeps all four owner-approved closed-ness signals (position, chip text, shorter
row, tint) and restores the badge's shape. Incidentally separates the
collapsed-Done fill from `secondaryContainer`. (Verify `.withValues` against the
pinned Flutter version at implementation time; `.withOpacity` is the fallback.)

**Rejected:** a border on `StatusPill`, or a different `StatusChip(done)` fill —
both change five other surfaces where the chip reads correctly today. A
`dense`/`onTint` flag on `StatusChip` — adds API to a shared widget for one
caller's ground. Dropping the tint — it is an approved signal and dark mode leans
on it harder than light does. A new `successContainerSubtle` field on
`AppStatusColors` is the "right" answer **if** the alpha-blend reads wrong in
dark, since `frontend.md` forbids brightness branching at call sites; it costs a
field plus `light`/`dark`/`copyWith`/`lerp`.

### What the owner is actually seeing, and the chosen fix

**The whole collapsed row reads as shrunken** — ~64 px against a full card's
~110 px, with the crew avatar stack dropped entirely (`:177-193` vs `:195-216`,
avatars dropped at `:206-209`). Every glyph on it is the same size as everywhere
else; the *row* is half-height, which is what makes its contents read small.

**This is the 2026-08-08 closed-jobs collapse working as designed**, not a
defect. `collapseWhenClosed: true` is passed by exactly one call site in the app
(`agenda_sliver_list.dart:189`); every other surface already shows Done jobs as
full cards. So this is a deliberate reversal of part of an approved design, and
was escalated rather than decided here.

**Owner decision, 2026-09-11: option B — keep the row collapsed, restore the
avatars and give the time its own line.** Rejected: option A (drop
`collapseWhenClosed` so Done rows are full cards — true parity, but finished work
takes full height again, which is the whole thing the collapse prevents) and
option C (raise the min height and padding only — smallest change, but the row
stays visibly shorter, so it likely would not resolve the complaint).

Two changes inside `appointment_card.dart`'s collapsed branch (`:177-193`):

1. **Restore the crew avatars.** They are dropped at `:206-209` on the collapsed
   path; render `_CrewAvatars` the way the full body does. Note `_CrewAvatars`
   (`:634-658`) puts a 1.5 px-bordered ring around a tight 20×20 `AppAvatar`
   inside a `SizedBox(height: 20)`, and lays out at its natural 23×23 because
   `RenderStack` gives positioned children unbounded constraints with
   `clipBehavior: Clip.none` — so it paints proud and is **not** squeezed. That
   was verified during the investigation; do not "fix" it on the way past.
2. **Give the time its own line, which also fixes a real squeeze.**
   `_ClosedMetaRow` (`:576-601`) currently puts `Flexible(time)` and
   `Expanded(label)` in one `Row`, both at flex 1, so `RenderFlex` splits the
   free space evenly and the time is capped at **half the row width even when
   the client name is short**, then ellipsised at `maxLines: 1`. A multi-day Done
   job's label is `"9:00 AM – 5:00 PM · Day 3 of 5"` (`_timeLabel`, `:220-232`)
   ≈ 190 px against ~150 px available → truncated, on exactly the rows
   `lib/features/calendar/CLAUDE.md` says must keep the `Day N of M` counter.
   Splitting the line removes the competition entirely.

Target height ~90 px: still shorter than a full card, so the collapse keeps doing
its job, but no longer half-height.

**Constraints that bind this change.** `_kClosedMinHeight = 48` is load-bearing
per `lib/features/calendar/CLAUDE.md` — the row must clear Material's 48 px
minimum. It is a `minHeight`, so restoring content raises the row naturally and
the constant needs no edit; **do not lower it**. And `appointment_card.dart:124`
forbids `LayoutBuilder`, `AutoSizeText` and `FittedBox` anywhere under the card's
`IntrinsicHeight` — so the new line must be plain `Column` children, never a
fitted box.

### Blast radius

- **The whole collapsed branch is reachable only when `collapseWhenClosed: true`,
  which exactly one call site passes** (`agenda_sliver_list.dart:189`). Verified
  against every other call site — `day_route_screen.dart:500`,
  `history_sliver_list.dart`, `client_job_history_section.dart`,
  `attention_flags_section.dart:236`, `upcoming_today_section.dart:56`,
  `employee_today_section.dart` — **none passes it**, so the day route, client job
  history, both dashboard sections and the paginated History list are untouched by
  construction. This is what keeps a row-shape change off five other surfaces.
- **Cancelled collapsed rows change too**, and that is intended: they take the
  same collapsed branch (only the *tint* is gated on `isDone`). So restoring the
  avatars and the time line affects every closed row in the sink, cancelled
  included. Confirm that is wanted — the alternative is gating the restoration on
  `isDone`, which would make cancelled the odd one out instead.
- No colour tokens, no shared widgets and no `StatusPill`/`StatusChip` changes, so
  no theme-wide risk. The light-mode pill collision above stays unfixed.
- `_kClosedMinHeight` is not edited; the row grows past it naturally.
- **`test/features/calendar/appointment_card_test.dart:646` will FAIL** — it
  asserts "a done job takes the success tint and **drops its avatars**", and the
  avatars are coming back. Update it deliberately, not reflexively: it is the test
  that pinned the approved design being reversed here. Also re-run `:400-416`
  (photo-glyph placement), `agenda_sliver_list_test.dart`, and
  `calendar_cards_localized_mobile_test.dart`.
- Re-check the agenda at **260 logical px with 2× text**: the row now carries more
  content, and at that width `_TitleRow` already switches to its `Column` branch
  (`:545-554`) when `context.isCompact`. Taller is fine; a RenderFlex overflow is
  not.

### Confidence

**HIGH** that no geometric/clipping/aspect-ratio defect exists — so the issue as
originally filed ("icons distorted, wrong aspect ratio, fix the sizing") has no
referent in the code, and was resolved by asking the owner what they were looking
at rather than by finding a bug to match the words. **HIGH** on the chosen scope
now that the owner has confirmed the row shape is the complaint: the change is a
deliberate, recorded partial reversal of approved design, with a one-call-site
blast radius.

The one thing still worth a look before building: whether restoring the avatars
and the time line to **cancelled** collapsed rows as well is wanted, or whether
the restoration should be gated on `isDone` (see Blast radius).

---

## 4. Issue 4 — filters don't re-apply

### Root cause — a structural omission, documented as intentional

```dart
// lib/features/clients/widgets/views/clients_list_view.dart:56-58
/// Order for the unfiltered paginated list. Ignored by the filter and search
/// paths, which are bounded in-memory lists ordered by the query behind them.
final ClientsSort sort;
```

`widget.sort` has exactly **two** readers, both on the `ClientsFilterAll` branch:
`_fetchPage` → `fetchClientsPage(sort:)` (`:113`), and `didUpdateWidget`'s pager
refresh (`:126`). `build` switches on the filter **first** and returns before
reaching the pager (`:448-469`), landing in `_buildFromAsync` (`:352-378`) —
which applies the text query and **never references `widget.sort`**. Order there
is fixed by `_byDisplayName` (`firebase_clients_repository.dart:290-297`), called
unconditionally by `fetchArchivedClients` (`:250`), `fetchClientsByType` (`:261`)
and `fetchClientsByBuilding` (`:278`), none of which take a `sort` parameter.

**The repro:** filter active → pick "Most jobs" → `setState`
(`clients_screen.dart:190`) → widget rebuilds with the new sort →
`didUpdateWidget` refreshes a pager **that is not in the tree** → `build` takes
the filter arm → `_buildFromAsync` re-renders the same `_byDisplayName` order.
Nothing downstream consumes the new value. (Picking "Name" while already on Name
is additionally a literal no-op — it is the default, `clients_screen.dart:49`.)

### Every hypothesis ruled out, with evidence

| Candidate | Verdict |
|---|---|
| `PagingController` never refreshed on filter change | Ruled out — `:124-127` does refresh on a sort change; it just guards a branch that isn't rendering |
| `DebouncedPagedSearch` trimmed-query diff hides it | **Ruled out** — `debounced_paged_search.dart:40-46` compares only the query, but that diff gates whether the *server text search* re-commits and has no bearing on ordering. **The mixin is innocent.** |
| `autoDispose.family` keyed only by query | Ruled out — the filter path never touches `clientSearchProvider` |
| `read` instead of `watch` on filter state | Ruled out — both are plain `State` fields with `setState` (`clients_screen.dart:48-49`) |
| Local list cached in `State` | Ruled out — the two memos are search *indexes*, keyed on list identity |
| `select()` dropping the filter | Ruled out — no `select()` on this path |
| `==`/`hashCode` ignoring a field | Ruled out — `clients_filter.dart:17-61` compares every field; `ClientsSort` is an enum; a sort change **is** seen |

### Terminology corrections, both material

- **"Building" is not the documented type filter.** Since 2026-09-04 there are no
  pickable chips: the Filter button opens **one sheet** with Type
  (`ClientsFilterType`) and Address (`ClientsFilterBuilding`) as peer sections,
  and `ClientsFilterBar` renders one read-only chip naming whatever is active
  (`clients_filter_bar.dart:38-44`). The repro applies identically to
  `ClientsFilterType` and `ClientsFilterArchived`.
- **Filters cannot combine with each other, by design.** `ClientsFilter` is a
  sealed one-of, so "archived AND commercial" is unexpressible — not broken. The
  only real combination is **filter × sort × text query**, and the sort leg is
  the missing one. Owner default: leave the sealed design alone; making Type and
  Address stack is separate, larger work.

### Fix

Give the filter path a sort, in Dart, over the bounded window it already holds —
mirroring `AppointmentHistoryView`, which composes its chips into **both** layers
(`appointment_history_view.dart:216-232`, `:442-447`). No forced rebuilds, no
invalidation, no new reads, no new indexes.

1. **One owner for the comparator:** `sortClients(List<ClientRecord>,
   ClientsSort)` as a pure function beside `ClientsSort`, folding
   `_byDisplayName`'s `displayName.toLowerCase()` key into its `name` arm so
   there is one order definition rather than two. `mostJobs` reads
   `record.jobCount`, `recentlyAdded` reads `createdAt`, both **nulls-last**,
   each tie-breaking on the display-name key so the order is total and stable.
2. **Apply it in `_buildFromAsync`** after the text-query narrowing, memoized on
   `(all, query, widget.sort)` — list by identity, query and sort by value —
   exactly like `appointment_history_view.dart:418`, so it re-sorts when the
   sort, query or source list changes and not on every keystroke rebuild.
3. **Leave `didUpdateWidget` as is.** It already reacts to `sort`;
   `PagingController.refresh()` only resets state and is harmless when the pager
   is unmounted.
4. **Leave the repository, the providers and the mixin untouched.**
   `_byDisplayName` stays as the window's stable default order.
5. **Document the divergence:** the in-Dart comparator is nulls-**last**, while
   Firestore's `orderBy` **drops** docs missing the field. Strictly better here,
   but the two paths now differ and `clients_sort.dart`'s "ONE owner" comment
   needs a sentence.

### Rejected

- **`ref.invalidate` on sort change** — the disguised force-re-render. Refetches
  identical data and renders the same `_byDisplayName` order. Fixes nothing, and
  is exactly what the owner's constraint targets.
- **Push sort server-side onto the filter queries** — forbidden by
  `.claude/rules/clients.md`: the type filter is a separate bounded read, never a
  filter over the paginated list; routing it through `fetchClientsPage` would
  filter a server page in Dart and truncate the list.
- **Key the providers by sort** — triples family instances over identical data
  purely to reorder it. Ordering is a view concern.
- **Hide the sort control while a filter is active** — honest, one line, and
  refuses the actual request.

### Blast radius

- **`DebouncedPagedSearch` is not touched, so `AppointmentHistoryView` is
  completely unaffected — zero risk to History.** The mixin looked like the
  culprit and is not; the shared seam stays frozen.
- `ClientsListView` has a **second host**: the booking flow's client picker,
  chrome-free, constructed with `sort: ClientsSort.name` and `ClientsFilterAll()`.
  With the `name` arm keeping `_byDisplayName`'s exact key, the picker's rendered
  order is byte-identical.
- Repository unchanged ⇒ `_scanWindow`, `_patchWindow`, the `SearchResultCache`
  LRU and `_pageBoundaryValues` all untouched. (The LRU key is query-only and
  that is **correct** — `searchClients` results carry no filter or sort.)
- **The search path still ignores sort, deliberately:** results are
  relevance-ranked by `scoreRecord`, and re-sorting them alphabetically would
  destroy the ranking the callable exists to apply.

### Tests

`test/features/clients/widgets/views/clients_list_view_test.dart:318-337` tests
the sort only on the **unfiltered** path; `:152-290` pumps every filter case at
the default `ClientsSort.name`. **No test crosses filter × sort, which is why
this shipped.** Add, using the existing `_wrap(repo, filter:, sort:)` harness:

> Stub `fetchClientsByBuilding` to return two records whose display-name order is
> the reverse of their `jobCount` order (Alice/1, Zoe/9). Pump with
> `ClientsFilterBuilding('k')`, assert Alice above Zoe. Pump again with the same
> key and `ClientsSort.mostJobs`, assert Zoe above Alice — **and**
> `verify(() => repo.fetchClientsByBuilding('k')).called(1)`, which proves the
> reorder came from the data dependency rather than a refetch or an invalidation.

Then the same for `ClientsFilterType` and `ClientsFilterArchived`, plus a
nulls-last case (`jobCount: null` sorts to the bottom under `mostJobs` rather
than vanishing).

---

## 5. Overlap between Issues 2 and 4 — reconciled into one change

Both investigations independently landed on the same seam, and it reconciles
cleanly:

- **"Most jobs" is today a server `orderBy` on the stored `jobCount` field**
  (`clients_sort.dart:9`, `firebase_clients_repository.dart:117`),
  cursor-paginated with the raw value in the boundary tuple (`:135`, `:143-148`).
- **There is no in-Dart count comparator anywhere in the app.** `jobCount` is
  written only by `recountClientJobs`, as an absolute aggregate, never
  incremented.
- **Therefore Issue 2's fix corrects the "Most jobs" sort for free** on the pager
  path, because the sort *is* the field. No Dart count logic exists to change,
  and none should be added.
- **Issue 4 introduces the app's first in-Dart `mostJobs` comparator**, for the
  filtered path. It **must read `ClientRecord.jobCount`** and must never derive
  or adjust a count itself. Done that way it inherits Issue 2's fix with no
  duplication and one definition of "a job".
- **The two changes touch different files.** `clients_list_view.dart` is the only
  file both reports name, and Issue 2 only *reads* it. **No stacked patches.**

Issue 2's sort fix cannot be done in Dart, for the record: `fetchClientsPage` is
a cursor-paginated server `orderBy`, so a post-query Dart re-sort would only
reorder within a page, and a Dart *filter* would shorten a server-filled page —
the documented failure that truncates the list permanently.

---

## 6. Order of implementation

| # | Step | Depends on |
|---|---|---|
| 1 | **Issue 1** — picker, ARBs, dead plumbing in both hosts, tests | nothing |
| 2 | **Issue 4** — `sortClients`, `_buildFromAsync` memo, crossed filter×sort tests | nothing |
| 3 | **Issue 3** — restore avatars + own-line time on the collapsed row, update the tint/avatars test | nothing |
| 4 | **Issue 2 code** — trigger gate, four aggregates, index entry, recount script, jest tests | nothing |
| 5 | **Issue 2 deploy** — indexes → READY → functions → backfill `--dry-run` → live | step 4 + **explicit owner authorization** |

Only real ordering constraints: index-before-function inside step 5, and
*verifying* "Most jobs" is only meaningful after step 5's backfill. All code and
tests land before any deploy. Steps 1–4 are local and reversible.

### Owner decisions on record (2026-09-11)

1. Issue 3 surface: **calendar agenda list** — which redirected the whole
   investigation and produced the finding in §3. Then, once it was established
   that nothing on that row is mis-sized: the complaint is **the row reading as
   shrunken**, and the resolution is **option B — keep it collapsed, restore the
   crew avatars and give the time its own line** (~90 px, against ~64 px today
   and ~110 px for a full card). Options A (full card) and C (padding only) were
   declined. This is a recorded partial reversal of the 2026-08-08 collapse
   design; the light-mode badge-contrast defect found alongside it is **left
   unfixed on purpose**.
2. Issue 1 keyboard: **standard text keyboard**; the numeric keypad is given up
   knowingly.
3. Issue 2 scope: **`clients.jobCount` only**; History's tally and the dashboard
   hero keep their current totals.
4. `+1` phone handling: **not needed** — "There will be no phone with a +1."
5. Defaulted, not objected to: `deleteClient`'s gate stays as-is; Type and
   Address filters stay mutually exclusive.

---

## 7. Verification plan

Each fix must be *confirmed*, not asserted.

- **Baseline:** `flutter analyze` must stay `No issues found!`; read the current
  green test counts off HEAD before touching anything (a recorded green count is
  a claim, not a fact).
- **Issue 1:** the updated `client_picker_test.dart` proving one bar, no
  segments, and that a mixed letters+digits query returns results; plus a manual
  pass typing `tremb`, `514-555-4321`, `(514) 555 4321` and `marc 514` into the
  one field.
- **Issue 2:** the new jest cases, especially **one live + one cancelled 5-day
  run = 1** (the case that proves the fourth aggregate) and `pending → done`
  costing zero reads. Then the script's `--dry-run` against prod showing old→new
  for the repro client — that count is the evidence the bug existed and is fixed.
- **Issue 3:** measure, don't eyeball. Assert `tester.getSize` on the collapsed
  Done row is in the ~90 px band and **still below** a full card's height pumped
  from the same harness — that single pair of assertions is what proves the row
  stopped reading as shrunken *without* silently becoming option A. Assert the
  avatars are present on a collapsed Done row (the inverse of the `:646`
  assertion being replaced), and that the tint survives. For the time line, pump a
  **multi-day** Done slice with a short client name and assert the full
  `"… · Day 3 of 5"` string is present and un-ellipsised — it is truncated today,
  so this fails before and passes after. Then at **260 logical px with
  `TextScaler.linear(2)`** (local `_harness` per file — there is no shared
  `_scaledHarness`): `expect(tester.takeException(), isNull)` for RenderFlex
  overflow, and the photo glyph at `Size(15, 15)` on both a collapsed Done row and
  a full pending row, equal to each other — the literal "match the other status
  icons" requirement, now serving as a regression guard rather than a fix.
- **Issue 4:** the crossed filter × sort tests above, with the
  `verify(...).called(1)` assertion that distinguishes a genuine data dependency
  from a forced refetch.
- `cd functions && npm run lint` before any deploy.

---

## 8. Open items

1. **Issue 3 — do cancelled collapsed rows get the restoration too?** They share
   the collapsed branch, so avatars and the own-line time land on them unless the
   change is gated on `isDone`. Ungated is the more consistent answer (every row
   in the sink looks the same); gated keeps the change narrower but makes
   cancelled the odd one out. Not blocking — I will go ungated unless told
   otherwise, and say so in the commit.
2. **Issue 3 — the light-mode badge-contrast defect is knowingly unfixed** (§3).
   Worth its own small change later; it is not scope creep to leave it, and it is
   recorded here so it is not re-found as new.
3. **Whether `clientId == ` + `status == ` needs its own composite** or is served
   by index merge (§2). Check before deploying.
4. **Prod size of the `jobCount` drift** — the recount script's `--dry-run`
   answers this and says whether the repro client is one straggler or the general
   case.
5. **Deploy authorization** for Issue 2 (§6 step 5). Not given.
