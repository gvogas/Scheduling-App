# Follow-ups (2026-10-07)

Things left over from the rules cut-down and its code follow-up pass.

**Status: ALL DONE 2026-10-08.**

## 1. Run the touched tests in isolation — DONE

All four files pass when run alone with `flutter test <path>`.

## 2. Dashboard overflows at 2x text on a 375 px phone — DONE

`_WorkloadRow`'s counts text is `Flexible` (bar column `flex: 2`). The tour
tooltip's skip/next are `TourActionButton`s capped at 1.2× text, because
showcaseview's `ActionWidget` Row doesn't flex. Pinned in
`dashboard_screen_test.dart` ("2x text on a narrow phone") at 375 px, where both
overflows reproduced.

## 3. `/users` create denylist — DONE (rules deploy pending)

`setupRequiresPassword` is on the create denylist; the emulator safety check
pins it (shown failing against the old rules). Goes live with the next
`Deploy backend` run.

## 4. Flutter-only rules out of `appointments.md` — DONE

Action bar/tours, time-off clash dialog and picker dimming moved to
`lib/features/calendar/CLAUDE.md`; the live admin gate (`isActiveAdminProvider`)
to `frontend.md`, since it governs Settings, the nav drawer and `/history` too.

## 5. Dashboard at 260 px with 2x text — DONE

The 375 px tests now run at 260 px, the tooltip one in every supported locale.
Fixed there: the hero and weekly-chart legend labels flex; a new-client row
folds its date under the name on `context.isCompact`; on `isCompact` the tour
tooltip drops its step counter, caps its pills at 1× and shows Skip as a
labelled close icon (French "Passer"/"Suivant" didn't fit otherwise).
