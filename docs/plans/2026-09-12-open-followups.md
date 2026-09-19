# Open follow-ups from the 2026-09-12 session

**Date:** 2026-09-12
**Status: OPEN — item 4 CLOSED 2026-09-12, item 5 CLOSED 2026-09-19, the other three still blocked.** Five items, each blocked on a
different thing — a design decision, a deploy, a machine permission, a commit
boundary, and a device. None is blocked on not knowing what to do.

Written because they were each raised, reasoned about and then deliberately
NOT done during the 2026-09-12 session, and a decision that only exists in a
conversation is a decision that gets re-litigated from scratch. The work that
DID land that day is in `2026-09-12-add-appointment-sheet-structure.md` and
`docs/archive/2026-09-11-fresh-header-redesign.md`.

---

## 1. The split container vocabulary on the appointment form

**Blocked on: an owner decision. This is Option B, which was declined.**

The New Appointment form speaks two container languages. `SCHEDULE` is a
`SheetPanel` — a bordered card of divided rows. `WHO` and `DETAILS` are loose
fields on the sheet ground. One form, two vocabularies, and the seam is visible
the moment you scroll past the crew chips.

This was Option B in the 2026-09-12 mockup
(https://claude.ai/code/artifact/b004fc2a-6638-4a37-951b-e5ef6700020b, version 1
holds the three-way comparison). **Option C was chosen and built; B was not, so
this is untouched by design, not by oversight.**

What it would take, and the part with real risk: putting free-text fields inside
divided panel rows is a different input pattern from `LabeledTextField`, which
owns the error shake (`AnimatedFormFieldWrapper`) and the clear button
(`ClearTextButton`). Both are pinned by tests. Either the panel grows a text-row
variant that keeps them, or the fields keep `LabeledTextField` inside a panel row
and the rhythm is reconciled by padding. That choice is the whole job.

**Next step:** decide whether the form should read as one object at all. If yes,
re-open the mockup and design the text-row variant before writing any of it.

---

## 2. Street/city split on address suggestions

**Blocked on: a Cloud Functions deploy.**

Address suggestions render as one flat line. A proper row is a bold street line
over a muted city line — the clarity win the 2026-09-12 dropdown rebuild could
not make.

The data is not there to do it. `functions/places.js` requests a field mask of
`suggestions.placePrediction.placeId` and `suggestions.placePrediction.text`
only, so `structuredFormat` (`mainText` / `secondaryText`) never reaches the
client. `AddressSuggestion` (`features/maps/domain/models/`) carries `placeId`
and a flat `description` to match.

**Cost:** one line added to the field mask, two fields on the model and its
`fromJson`, one call site in `address_autocomplete_field.dart` — then a
`firebase deploy --only functions`. The deploy is the reason this was NOT folded
into an app-side styling pass: it is a gated operation with its own runbook
(`docs/DEPLOYMENT.md`), and riding one in on a visual tweak is how a deploy
happens without anybody deciding to deploy.

**Order matters:** the backend ships FIRST. `AttachedDropdownRow` already
falls back to the flat `description`, so an app build that reads
`structuredFormat` before the function sends it degrades to today's behaviour
rather than breaking — but only if the model treats both new fields as optional.

---

## 3. Neither dropdown was ever seen running

**Blocked on: macOS Accessibility permission for the terminal.**

The client and address dropdowns were rebuilt on 2026-09-12 and verified by
**test only**. Neither was observed on a device or simulator:

- The client list has ONE partial capture, taken before the "Attach" removal, so
  it shows a label that no longer exists.
- The address list was never reached at all.

Why, precisely — this is worth recording so the next session does not spend the
same hour: synthetic clicks posted through AppleScript's System Events reach
some Flutter widgets (the FAB, `InkWell` rows, text fields sometimes) but NOT
`TextButton` or `CupertinoSwitch`, so "Change", "Remove" and the Personal-job
switch are all undrivable. Text entry works only through the pasteboard, whose
iOS paste prompt then covers the list being photographed. `CGEvent` posting —
which would drive all of it properly — is silently dropped without Accessibility
permission for the process running the shell.

**Next step:** either grant Accessibility (System Settings › Privacy & Security
› Accessibility) and re-drive it, or simply open the sheet by hand and look. The
second costs about five seconds and is the honest recommendation.

---

## 4. Four Dart files are still CRLF — CLOSED 2026-09-12

**DONE, and the premise was half wrong.** Only TWO of the four were CRLF in git:
`appointment_form_fields.dart` (694 CRLF, 3 stray `\r\r\n`) and its test (584
CRLF, 1 `\r\r\n`) — the stray CRs made git classify both as BINARY (`-text`),
which is why `text=auto` never touched them. `add_appointment_sheet.dart` and
`details_edit_body.dart` were already LF in the index; the CRLF seen was only
the working copy under `core.autocrlf=true`. Check `git ls-files --eol`, not
the bytes on disk. Converted in binary mode in `8ddf6bd7`, a commit touching nothing else
(`git diff -w --ignore-cr-at-eol` empty). The text below is the original entry.

**Blocked on: a commit boundary, not a decision.**

`.gitattributes` says `* text=auto`, and 825 of 829 tracked `.dart` files are
LF. These four are not:

- `lib/features/calendar/widgets/sections/appointment_form_fields.dart`
- `lib/features/calendar/widgets/sheets/add_appointment_sheet.dart`
- `lib/features/calendar/widgets/views/details_edit_body.dart`
- `test/features/calendar/widgets/sections/appointment_form_fields_test.dart`

**Git will never fix these on its own.** `text=auto` deliberately does not
normalize a file already stored with CRLF, which is why they have survived every
commit since. Verified 2026-09-12: re-hashing the unchanged blob through
`git hash-object --path` returns the identical hash.

This is a live trap, not cosmetics. It bit during this very session: a Python
edit opened one in text mode, which normalized the whole file AND expanded its
`\r\r\n` runs into stray blank lines — an 8-line change became a 1080-line diff
carrying three silent insertions. It was caught and reverted only because the
diff size looked wrong.

**Why not now:** all four have uncommitted changes. Converting them today turns
the session's real diffs into full-file rewrites and makes the work
unreviewable.

**Next step:** after the current branch lands, convert all four in a single
commit that touches nothing else, so the diff is self-evidently mechanical.
Until then, edit these four in BINARY mode.

---

## 5. Phase 3's device pass on the fresh-header redesign — CLOSED 2026-09-19

**Done (owner, 2026-09-19).** Was blocked on: a device.

Carried over from `docs/archive/2026-09-11-fresh-header-redesign.md`, which is the authority
— not repeated here beyond the pointer. Status-bar icon colour on every screen
in both themes, landscape on Clients and Settings, the drawer from the ghost
menu, Dynamic Type on the Clients chip row, plus three things a full-branch
review flagged for the device specifically (the ghost tile's contrast on a form
sheet, the group card's corners under an ink splash, and the filter bar under
the tour on a TABLET).

Nine defects have already been found on that branch by looking at it — five in
a post-build review, four more in the 2026-09-12 simulator pass, one of which
(`SheetHeaderBar` truncating "New Appointment") reached every sheet in the app.
That hit rate is the argument for finishing the pass.

---

## Not on this list, deliberately

The 2026-09-12 session also closed several things; they are recorded at their
sites and are NOT open work: the four simulator fixes and the Option C build
(`2026-09-12-add-appointment-sheet-structure.md`), the dropdown rebuild and the
"Attach" removal (same doc), the `0/4000` counter removal, the docs sweep
(counts, the stale fresh-header index row, seven unindexed archive files, the
retired rolling-audit references), and the `codebase-audit` skill's contradictory
output path.
