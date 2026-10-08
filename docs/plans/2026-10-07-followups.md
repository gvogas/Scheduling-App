# Follow-ups (2026-10-07)

Things left over from the rules cut-down and its code follow-up pass.

**Status: items 1–4 DONE 2026-10-08.** Item 5 is new and open.

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

## 5. Dashboard hero overflows at 260 px with 2x text — OPEN

At the 260 px / 2x harness `CLAUDE.md` asks for, `dashboard_hero.dart`'s
`_StatusLegend` `Row` (line ~171) overflows by 57 px. Fix it, then move the
"2x text on a narrow phone" group in `dashboard_screen_test.dart` from 375 px
to 260 px.
