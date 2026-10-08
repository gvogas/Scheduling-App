# 0120. One appointment link opener for push, widget and app links

**Date:** 2026-08-19 (audit I4) · **Rules file:** `.claude/rules/notifications.md`

## Context
`_setupWidgetTapHandling`, `_setupPushTapHandling`, `_handleWidgetTap`, `_handlePushTap`,
`_openAppointmentDeepLink` and `_awaitLiveHub` lived in `lib/main.dart` as private `State` methods, where
none could be tested. The month-end review push (ADR-0118) carries no appointment id.

## Decision
`AppointmentLinkOpener` (`core/app/appointment_link_opener.dart`, registered by `main.dart` in
`initState`) owns the entry points `app_links` does not: the `home_widget` tap channel (`widgetClicked` +
`initiallyLaunchedFromHomeWidget`) and FCM taps (`initialMessage()` + `onMessageOpenedApp`).
`DeepLinkDispatcher` is wired to its `openAppointment`, so all three converge on one opener.
`AppointmentLinkOpener.handlePushTap` checks `kind: overdueReview` BEFORE reading `appointmentId`: it
lands on the calendar and pushes the overdue review for an admin (a non-admin stops at the calendar).

## Consequences
A new id-carrying push kind needs no Dart change; a new id-less kind needs a branch there, above the id read.
