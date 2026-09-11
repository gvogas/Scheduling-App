# Fresh header and Clients list redesign

**Date:** 2026-09-11
**Status: PLAN, NOT STARTED.** Design finalised 2026-09-11 on the canvas below;
no code written yet.
**Mockup:** https://claude.ai/code/artifact/ed4167b6-9b21-4dbf-a950-d05d292a2347
(page "Clients page" holds the six screens, light and dark; page "Header
options" holds the four directions that were compared).
**Chosen option:** D — "Fresh": no coloured bar. The header sits on the page
colour with a large title, ghost controls and a pill search field. Applied to
every screen. Clients also takes a new grouped list layout with type chips.

## Problem

The inner screens (Clients, History, Employees, Dashboard, Settings, the
sub-screens) use `AppTopBar`: a solid `primary` blue bar with white text. The
right-hand controls on it are `AppHeaderPair`, which was designed for the
calendar's WHITE header and paints `primaryContainer` (pale blue) tiles with
blue glyphs. On the blue bar those tiles clash, and the `AppSearchBar` in the
bar's `bottom` slot is a grey `surfaceContainerHighest` field sitting directly
on the blue. Three colours in one strip, and the top of the screen flips from
white to blue on every tab change.

## Decision

One header vocabulary everywhere, in both themes:

- **Surface:** the header is painted in `scaffoldBackgroundColor` (`paper` /
  `darkPage`). No bar, no divider under it.
- **Top row (44 px):** back chevron left (ink, no tile) when the screen has a
  back action; on the right the ghost controls — `surface` fill, 1 px
  `outlineVariant` border, ink glyph, 38 px tall, full radius. The Calendar
  pill keeps its calendar glyph in `primary` and its "Calendar" label; the menu
  and the calendar's crew-filter / route buttons are 38 px circles.
- **Title row:** `displayLarge` (26 / w700 / −0.65) in ink, with an optional
  count beside it in `monoType.metric` recoloured `textTertiary` (Clients,
  Employees, History). The calendar keeps its `SCHEDULE` eyebrow and month
  picker as the title row.
- **Search (where the screen has one):** 44 px pill, `surface` fill, 1 px
  `outlineVariant` border, `search` glyph and hint in `textTertiary`, 14 px
  below the title. It is part of the header, not the list.
- **Status bar:** the header's `AnnotatedRegion` follows the page surface (dark
  icons in light, light icons in dark) — the same rule
  `CalendarHeaderBlock` already applies.

Per-screen bodies stay as they are today, except:

- **Clients** gets the new list: a chip row, a count-and-sort line, and the
  list grouped by initial into white cards, each row carrying the avatar,
  name, a type badge, the address line, the phone in mono and the job count.
  The **Filter button stays** at the front of the chip row as a round
  outlined button and still opens the existing filter sheet — that is where
  the building filter lives. An active building filter renders as a
  removable tinted chip beside the button (with a dot on the button) and
  the list narrows to that building under a single address group.
- **Employees** rows keep their exact anatomy but sit in the same white card as
  the Clients groups, so the two rosters read as one family.
- **Dashboard** hero becomes an inset rounded card (radius 16, 16 px margins)
  instead of a full-bleed band, because it no longer sits under a blue bar.

Everything else (calendar grid, agenda, History rail, Settings cards) is
untouched.

## Scope and phases

### Phase 1 — the shared header (every screen except Clients' list)

1. `lib/shared/widgets/app_bars/app_top_bar.dart`: replace the `AppBar` with
   the fresh header. Keep the constructor shape (`title`, `onBack`, `actions`,
   `bottom`, `compact`) so the eleven call sites need no change beyond the new
   optional `count`. `preferredSize` must add up the real rows (top inset +
   44 + title row + search + paddings) and honour `compact` (landscape) by
   dropping the large title to `titleLarge` on the top row. Paint the
   `AnnotatedRegion<SystemUiOverlayStyle>` here — the `AppBar` used to do it.
2. `lib/shared/widgets/app_bars/app_header_pair.dart`: ghost styling
   (`surface` + `outlineVariant` border, ink glyph) for the pill and the menu
   tile; the tap targets stay 48. The pill's calendar glyph stays `primary`.
3. `lib/shared/widgets/fields/app_search_bar.dart`: pill shape, `surface`
   fill, 1 px border, `textTertiary` hint. Its `preferredSize` is unchanged
   (16 + 44 × text scale). Any screen that puts it in `bottom:` gets the new
   look for free (Clients, History, Employees).
4. `lib/features/calendar/widgets/views/calendar_header_block.dart`: surface
   → page colour, drop the bottom border, controls go ghost (the crew-filter
   active state keeps `primary` fill / white glyph). The week-strip slot and
   the `AnimatedSwitcher` are untouched.
5. `lib/core/theme/themes.dart`: `appBarTheme` stays for the framework
   surfaces that still use a raw `AppBar` (dialog routes, `InvalidRouteScreen`)
   but switches to `surfaceTintColor: transparent`, background
   `scaffoldBackgroundColor`, foreground `onSurface`, so nothing blue survives
   by accident. `test/core/theme/themes_test.dart` pins the new values.
6. Dashboard hero: `dashboard_hero.dart` gains the 16 px inset and radius 16;
   `_StatsList` drops the "hero bleeds edge-to-edge" zero padding.
7. Sub-screens that pass `onBack` (`day_route_screen`, `my_details_screen`,
   `text_size_screen`, `location_sharing_screen`, `live_map_screen`,
   `settings_screen`) are covered by step 1 — verify each once on device for
   the status-bar icon colour and the landscape `compact` row.

### Phase 2 — the Clients list

1. `ClientsFilterBar` → chip row: the round Filter button first (keeps
   `onOpen`, the active dot replaces today's 6 px circle-in-label), then one
   `FilterChip` per `ClientType` that has clients (Residential, Commercial,
   Building) and Archived, selected chip in ink fill / page-colour label.
   Tapping a chip sets `ClientsFilterType(type)` / `ClientsFilterArchived`;
   "All" sets `ClientsFilterAll`. A `ClientsFilterBuilding` renders as the
   tinted removable chip; its × calls the existing `onClear`. The sealed
   `ClientsFilter` family does not change.
2. `ClientsListHeader`: "Showing all N clients" / "N clients in this building"
   / the type variant on the left, the existing sort `PopupMenuButton` on the
   right with a `sort` glyph. New l10n keys `clients_showingAll`,
   `clients_inThisBuilding`, `clients_showingType` (EN + FR, `@` blocks).
3. `ClientTile` → the new row: 40 px avatar (keep `AppAvatar` and the crew-hue
   rule — the mockup's pastel tint is a palette choice to make in
   `AppAvatar`, not a per-row colour), name `titleMedium`, type badge
   (`StatusPill` with a `home` / `apartment` glyph, `surfaceContainerHighest`
   for residential, `primaryContainer` for commercial and building), address
   `bodySmall`, phone in `monoType.data`, job count `monoType.micro` right;
   Archived keeps its pill. The trailing chevron goes; the whole row stays
   an `InkWell`. Slidable actions unchanged.
4. Grouping: `ClientsListView` inserts a letter header (`monoType.label`)
   and wraps each run in a `appCardDecoration` card when the sort is **Name**;
   under "Most jobs" / "Recently added" the list is one card with no letter
   headers; under a building filter the single group is headed by the
   building's street. Do this in the paged builder over the settled page —
   never re-sort the page (it is `orderBy('name')` server-side already), and
   keep the separator a 1 px `outlineVariant` row divider inside the card.
5. Empty / skeleton / error states: unchanged widgets, but the skeleton rows
   sit inside one card so the settle does not jump.

### Phase 3 — verification

- `flutter analyze` clean; `flutter gen-l10n` after the ARB edits.
- Widget tests: `app_header_pair_test.dart` (ghost colours, tap targets),
  a new `app_top_bar_test.dart` (preferred size with and without search, at
  2× text scale and 260 px width, `compact` row), `themes_test.dart`,
  `main_calendar_screen_test.dart` (header block still finds its tour target),
  `hub_shell_test.dart`, and Clients: chip → filter mapping, building chip ×
  → `onClear`, letter grouping only under Name sort.
- Feature tour: the `TourStepId.clientsFilter` / `clientsSearch` /
  `clientsSort` targets move with their widgets; the keys are unchanged so no
  tour replays.
- Device pass (Mac): status-bar icon colour on every screen in both themes,
  landscape on Clients and Settings, the drawer opening from the ghost menu,
  Dynamic Type at the largest setting on the Clients chip row (it scrolls
  horizontally, it must not wrap).

### Phase 4 — sheets, forms and dialogs (added 2026-09-11, owner call)

Originally out of scope; the owner asked for them in the same programme so
the app does not end up with two header languages. Same vocabulary as
Phase 1, applied to the surfaces that open OVER a screen:

1. `SheetHeaderBar` (`shared/widgets/sheets/sheet_header_bar.dart`) — the bar
   every detail sheet and form sheet uses (appointment details, client
   details, employee details, add/edit forms, the clients filter sheet, the
   History year / staff pickers): title in `headlineLarge` on the sheet
   surface, close and action controls as the same 38 px ghost tiles, no
   coloured band. Nothing about what the sheets do changes.
2. `FormSheetFrame` and `AppBottomSheet` — grab handle, top padding and the
   sheet surface stay; only the header row restyles through step 1.
3. The **clients filter sheet** keeps its three sections (type, building,
   archived) and its logic; it takes the ghost header and the same chip
   styling as the Clients screen so the two read as one control.
4. `AppDialogFrame` / `ConfirmDialog` — title to `headlineMedium` in ink,
   buttons unchanged. Only if a dialog carries a coloured title band today;
   otherwise no change.
5. Detail sheets keep their body layouts. Do not redesign them here.
6. Tests: the existing sheet-header widget tests plus an overflow pass at 2×
   text on `SheetHeaderBar` with a long title and two actions.

Behaviour that stays exactly as it is, in every phase: filtering logic, the
filter sheet's options, search, sorting, paging, and the blue brand accent
elsewhere (FAB, buttons, selected calendar day).

## Two decisions taken at build time (2026-09-11)

Both were raised because the plan as written contradicted a rule younger than
it. Recorded here so neither is re-litigated from the rules file alone.

- **The type badge goes BACK on the Clients row, reversing the 2026-09-07 owner
  call.** `.claude/rules/clients.md` had reduced the row to ONE badge (Archived)
  because archived, type, Building and the job count were "all competing under
  one name"; the canvas design approved 2026-09-11 shows the badge again, and
  the owner confirmed it is deliberate. What makes it survivable this time is
  the rest of the redesign: the row is no longer a flat `ListTile` competing for
  one line, and the Building pill and the shared-address count are still gone.
  The two `client_tile_test.dart` tests that pinned the absence
  ("no longer renders a type chip", "no longer marks a shared address as a
  building") are rewritten to assert its PRESENCE, and the rules file records
  the reversal — a test deleted without its rule updated is what makes the next
  audit read this as drift.
- **Grouping is opt-in: `ClientsListView` takes `grouped`, defaulting to
  `false`.** The plan put the letter headers and group cards in that view
  unconditionally, but it is also the booking flow's client picker, and the
  chrome rule keeps the Filter button and list header in `clients_screen.dart`
  precisely so the picker is suppressed for free. The Clients screen passes
  `grouped: true`; the picker keeps today's flat list inside its sheet, where
  vertical space is tight.

## Notes for the build

- `AppTopBar` has eleven call sites; the `compact == context.isLandscape`
  assert stays.
- Nothing here touches `functions/`, rules or indexes — an app-only release.
- The mockup's client names, phones and figures are placeholders.
