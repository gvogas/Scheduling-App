# Add Appointment sheet — structure options

**Date:** 2026-09-12
**Status: OPTION C BUILT 2026-09-12** on branch `fresh-header`, with the tour
retargeted. Analyzer clean, l10n clean (`untranslated.json` empty), and the
calendar / feature-tour / shared suites green at 1250. Verified on the
simulator. Merged to `dev` and SHIPPED in 1.61.0+90 (release commit
`dd8c4863`; corrected 2026-09-13).
Built on `fresh-header`, on top of the four simulator fixes below.

**Mockup:** https://claude.ai/code/artifact/b004fc2a-6638-4a37-951b-e5ef6700020b
Version 1 held the three-way comparison (three phone frames with the scroll fold
marked on a 393 pt phone); **version 2, the current one, is the refined Option C**
— the whole form in one frame with the changed region marked, plus the
personal-job state. Light and dark.

## What is already fixed, and is not in question here

A simulator pass on 2026-09-12 found and fixed four defects on this sheet. They
are recorded in `docs/archive/2026-09-11-fresh-header-redesign.md` and are shipped on the
branch; the options below sit on top of them and none of them re-opens one:

- `SheetHeaderBar` truncated "New Appointment" to "New Appoin..." on the widest
  iPhone — the side slots are measured now, not a flat `flex: 3/4/3`.
- The job address block was labelled three times over.
- Every `EmployeePicker` chip took a whole row of its `Wrap`.
- EN had "Start Time" beside "Start date".

Together they returned about 150 pt to the form, which is what makes the
remaining question a question rather than a crisis.

## Problem

Two structural things are left, and they interact:

1. **TEMPLATES owns the top of the form.** Six chips over three rows, roughly
   160 pt, before anything required. `Service / Title` and `Client` — both
   required — still open below the fold. The chips cannot simply be made
   smaller: 48 pt is the tap floor `f8072d48` deliberately holds, so density is
   not available as an answer.
2. **The form speaks two visual languages.** SCHEDULE is a `SheetPanel` — a
   bordered card of divided rows. WHO and DETAILS are loose fields on the sheet
   ground. One form, two container vocabularies.

## The three options

| | A · Templates on one line | B · One panel language | C · Templates where they act |
|---|---|---|---|
| Change | Chips become one sideways-scrolling row | Every section becomes a `SheetPanel` | TEMPLATES section deleted; chips move under `Service / Title` |
| Templates visible | 4 of 6 | 4 of 6 | 6 of 6 |
| Two languages | still there | resolved | still there |
| Build size | one widget | the whole form stack, plus field-in-row input behaviour | two widgets, one section deleted |
| Tour impact | none, `apptTemplates` keeps its target | every step's target moves | `apptTemplates` retargets onto the title field |

**A** is the smallest change and buys back ~112 pt, at the cost of hiding
templates 3–6 behind a swipe.

**B** is the only one that resolves the split vocabulary, and is the densest —
but it is the largest refactor, and putting free-text fields inside divided
panel rows is a different input pattern from `LabeledTextField`, which owns the
error shake and the clear button (`.claude/rules/frontend.md`, Forms & sheets).

**C** is the argument from what a template actually *does*: it fills the title
and the default duration and nothing else, so it belongs beside the field it
fills rather than in a section of its own. The form then opens on the first
thing that must be answered, and all six stay visible. The cost is that
templates lose top-level billing.

A and C both leave item 2 open; B addresses it. They are combinable — C's
placement with B's panels is a coherent fourth shape if that is the pick.

## Chosen: C — templates where they act

Picked 2026-09-12, straight, with nothing grafted from A or B. The artifact now
shows the refined design rather than the three-way comparison: the whole form in
one frame with the changed region marked, plus the personal-job state.

The argument that settled it: a template fills `Service / Title` and the default
duration and NOTHING else, so a top-level section of its own overstated it. Under
the field it fills, it reads as what it is — a shortcut for that field — the form
opens on the first thing that must be answered, and all six stay visible instead
of the four that fit a single scrolling row.

### What changes

- `_templatesSection` is deleted from `AppointmentFormFields`, with its
  `MonoSectionLabel` and trailing spacer.
- The chip `Wrap` moves into `_whoSection`, directly beneath the Service / Title
  field, inside the same `SheetFocusScroll` group.
- A one-line hint under the chips says what tapping one does. Nothing states
  today that the duration is set too, which is half of what a template is.
- The `onApplyTemplate == null || isPersonal` gate moves WITH the chips, so the
  edit sheet (which passes null) and personal blocks stay chip-free exactly as
  now.
- One new ARB key in both locales for the hint.

### What does not change

The six `JobTemplate` values, their labels and durations; `_applyTemplate`
itself; the 48pt chip tap floor; and the SCHEDULE panel / loose-field split.

### The feature tour — settled, retargeted

`TourStepId.apptTemplates` had no section left to point at. **The member is
KEPT and only its target moved**, onto the Service / Title group: the name IS
the tour's storage key, so retiring it would orphan that tour for anyone who
has seen it and renaming it would replay the whole walkthrough (root
`CLAUDE.md`). The existing copy — "Start from a job type / One tap fills in the
title and a typical duration" — describes the chips wherever they sit, so no
ARB change was needed there. `tour_definitions.dart` is untouched: the step
still comes first, because Service / Title is still the first field.

The retarget is now actually TESTED. `appointment_form_fields_test.dart` grew a
`tourWrap` parameter — the harness had never passed one, so every tour wrap on
this form was uncovered — and a test asserts the `apptTemplates` target wraps
BOTH the title field and the chips.

### What the build actually bought

Honest measurement, since the four earlier fixes had already reclaimed ~150pt:
the first screenful reaches the same depth as before (SCHEDULE's date row). The
gain is **ordering, not space** — roughly 40pt from the deleted section label
and its spacers, plus the required title field now being the first thing in the
form instead of the fourth. The chips still occupy three rows; the 48pt tap
floor means that does not change.

### Left open by this pick

- **The split container vocabulary** (problem 2 above) is NOT addressed. That
  was Option B's job, and C does not touch it. It needs its own decision.
- The `0/4000` counter under Notes but not Materials.

## Also built 2026-09-12: the two attached dropdowns

Asked for separately ("a nicer and clearer dropdown for clients and address"),
same sheet, same day. Not part of the option set above.

`AttachedDropdown` was described as one owner of the chrome, and it was — but
only the PANEL was shared. The rows were not: the client picker's were
hand-built and divided, the address field's were a bare `ListTile(dense: true)`
with no dividers and a different vertical rhythm, so one form rendered two
different controls doing the same job. The panel also had **no fill and no
elevation** — a suggestion list floating over the form, separated from it in
dark by a 6%-white hairline and nothing else.

What changed:

- The panel paints `palette.sheetRow` and `cardStyle.pillShadow`, so it reads
  as a layer above the form.
- One row for both fields, `AttachedDropdownRow`, owning the dividers, the
  rhythm and the typography. The address list gains dividers it never had.
- Client results carry the `AppAvatar` the Clients list uses.
- Addresses get two lines; one line ellipsised the town off the end of most.
- The row holds the **48pt tap floor** itself. It painted about 36.
- The `tapTargetSize.shrinkWrap` "Attach" `TextButton` is gone. It sat INSIDE
  the `InkWell` that already performed the same action — a second, smaller
  target for one job, the same defect class as the ghost controls in
  `f8072d48`.

**One decision was reversed mid-build and is worth keeping straight.** The
"Attach" button was first replaced with a chevron; two tests failed, correctly,
because the WORD is what told the user an unobvious action was on offer
("attach this client to the job" is not "open this"). The verb was restored as
a plain label — one tap target, same sentence. **Then the owner called for the
word to go too** (2026-09-12), which took the `action` parameter with it (one
caller) and `clients_attach` out of both ARBs. Don't reintroduce a trailing
label here; the chevron is the whole affordance, and the rule in
`.claude/rules/frontend.md` records it as an owner call so a later audit does
not file its absence as a missing affordance.

Verified: analyzer clean, `untranslated.json` empty, **3684 tests**, six new
`attached_dropdown_test.dart` cases pinning the tap floor, the single-target
rule, the panel's fill and shadow, the dividers, and a two-line address at
260px / 2x text.

**NOT verified on a device.** Neither dropdown was seen running. Synthetic
clicks reach some Flutter widgets here but not `TextButton` or
`CupertinoSwitch`, and text entry only works through the pasteboard, whose iOS
prompt covers the list being photographed. One partial capture of the client
list exists from before the "Attach" removal. The address dropdown was never
reached at all.

### Still open, needs a deploy

A proper two-line address row — bold street, muted city — needs
`structuredFormat` in the Places field mask (`functions/places.js`, which
requests only `placePrediction.placeId` and `.text`). That is a backend change
plus a functions deploy, deliberately NOT folded into an app-side styling pass.

## Not in scope

Filtering, validation, conflict checks, the photo pipeline, and the assignee
availability rules are untouched by all three.

## Also noticed

- **The `0/4000` counter is GONE (2026-09-12).** It sat under Notes and nowhere
  else: `showCounter` had exactly one caller in the app, so one field advertised
  a 4000 cap while Materials (2000), Title (200) and Address (500) all enforced
  silently. `LabeledTextField` keeps the capability and its two tests — it is a
  real affordance, not dead code — but nothing passes it now, and the cap is
  still enforced through `LengthLimitingTextInputFormatter`.
- **STILL OPEN.** Four Dart files are still CRLF (`appointment_form_fields.dart` and its test,
  `add_appointment_sheet.dart`, `details_edit_body.dart`) while `.gitattributes`
  says `* text=auto` and 825 of 829 are LF. Editing one with a tool that
  normalises line endings turns an 8-line change into a full-file diff — it did
  exactly that once during the 2026-09-12 pass, and the read was lossy, so this
  is a trap worth clearing deliberately rather than by accident.
