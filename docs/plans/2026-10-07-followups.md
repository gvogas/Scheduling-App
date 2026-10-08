# Follow-ups (2026-10-07)

Things left over from the rules cut-down and its code follow-up pass. Pick any
one up on its own.

## 1. Run the touched tests in isolation

The code follow-up fixes were committed 2026-10-07 after a green full run
(`check_rules` 0, analyze clean, functions lint clean, jest 2237,
`tool/test.dart` 4052). Not yet done: run each touched test file on its own,
as `/ship` requires, to prove it doesn't depend on a shard-mate:

- `test/features/feature_tour/domain/tour_definitions_test.dart`
- `test/features/calendar/event_details_view_test.dart`
- `test/features/dashboard/screens/dashboard_screen_test.dart`
- `test/features/calendar/domain/models/appointment_prefill_test.dart`

## 2. Dashboard overflows at 2x text on a 375 px phone

Found while testing tours, not fixed. At `TextScaler.linear(2)` and 375 px
wide:

- `_WorkloadRow`'s `Row` (`lib/features/dashboard/...`) overflows by 258 px.
- The showcase tooltip's action `Row` overflows by 117 px.

Fix both. Add an overflow test at 260 px with 2x text, using the file's local
`_harness` (see "Testing" in root `CLAUDE.md`).

## 3. Owner decision: `/users` create denylist

The `firestore.rules` `/users` `allow create` denylist doesn't include
`setupRequiresPassword`, although `allow update` does. An admin-created doc
could therefore carry it. The effect looks harmless, since it only forces
coordinated setup.

To close it:

- Add the field to the create denylist.
- Update `employees.md` (line ~86).
- Add a rules test.
- Deploy rules via the `Deploy backend` workflow.

## 4. Owner decision: move Flutter-only rules out of `appointments.md`

About 7 KB of Flutter-only rules could move into
`lib/features/calendar/CLAUDE.md`, so a `functions/` or rules session stops
loading them:

- the clash-alert dialog internals
- the assignee picker rules
- the action-bar and tour wiring

Not decided. See the "Open owner decision" in
`2026-10-06-rules-docs-cut-down.md`.
