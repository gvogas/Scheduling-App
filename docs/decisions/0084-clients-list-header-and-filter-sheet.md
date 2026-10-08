# 0084. Clients list header: Filter button in the row, no chips, sealed one-of filter

**Date:** 2026-09-04 (button never scrolls), 2026-09-11 PM (chips removed) · **Rules file:** `.claude/rules/clients.md`

## Context
On 2026-09-11 chips "came back" in the morning and were removed again that afternoon (owner call). They were
a second copy of the sheet's vocabulary that could only show a subset of it, and cost a whole line of list;
the count sentence (`clients_showingType`, "45 Commercial clients", or "50 of 120 Commercial clients" while
paging) already says which filter is on. The sort control sat in a `Flexible` beside the sentence's
`Expanded`; two flex-1 children split the row 50/50, truncating the sentence and floating the control
mid-row. `ClientsListView`'s chrome-free split was once justified by the view doubling as the booking
picker; it never did (only caller: `clients_screen.dart`, verified 2026-09-11).

## Decision
One header row: the Filter button (`ClientsFilterBar`, keeping its name because `TourStepId.clientsFilter`
targets it), the sentence, a ✕ only while a filter is on, and the sort control in a `ConstrainedBox` at 55%
of the row. The header takes `leading`/`sortWrap` because `clientsFilter` and `clientsSort` are two tour
steps in one row and a showcase nested in a showcase does not resolve. `ClientsFilter` stays sealed, so the
sheet is one radio group across its two sections. Rows are ghost `rFull` pills (`scheme.surface` fill, `outlineVariant` border, filling with `scheme.onSurface` when picked) with the radio glyph kept. Type options are the fixed `ClientType.pickable` set.

## Consequences
Re-adding chips or wrapping the header breaks the tour or duplicates the sentence. Multi-select means
changing the sealed model, how the type and address queries compose, and the `firestore.rules` read clauses.
