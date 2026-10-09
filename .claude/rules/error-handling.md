---
alwaysApply: true
---

# Error Handling

- Never swallow an error: log or rethrow, naming the operation. Catch `FirebaseAuthException`/`FirebaseException` specifically; no raw codes or stack traces in UI.
- Give every async call in `initState` and every stream subscription a `.catchError` or `try/catch` — unhandled, they crash silently.
- Retry transient errors with backoff; fail fast on auth/permission errors — except a read right after sign-in (`permission-denied` until the token propagates): wrap it in `retryAsync`/`retryStream` (`lib/core/utils/retry.dart`), as the appointments stream (`retryStream`) and `sign_in_controller.dart`'s `findUserByUid` (`retryAsync`) do. (ADR-0035)
- Keep the defaults `isAuthPropagationDenied` (`retryWhen`) and `kAuthPropagationDelays` (`delays:`) sole owners — no local predicate, inline `catch (FirebaseException)`-then-delay or per-site budget. (ADR-0035)
- Log `permission-denied` clearly — usually a `firestore.rules` issue, not a bug.

## Cause notices (generic catch sites)

- Typed-`Failure` branches first, else `composeErrorNotice(context, intro:, error:)` (`lib/core/errors/error_cause.dart`): `"{intro}. {cause}"` from 7 sanitized causes. Never `error_somethingWentWrong` at a new site.
- Never put a support tag in user-facing text; it lives only as the `logger.warn` label prefix, so the label MUST start with it (`'CLI-DEL deleteClient failed'`). (ADR-0031)
- Call `warn` BEFORE any `if (!mounted) return;` — the log must survive unmount.
- Read the logger (`loggerProvider`) and any provider a post-await path needs (`noticeServiceProvider`, a repository) BEFORE the first `await` — Riverpod 3 `ref.read` on an unmounted consumer throws a `StateError`, exactly when the mounted guard matters. A `ref.read` in a braced `catch` or `.catchError` body is CI-checked (`tool/check_rules.dart`, `ref-read-in-catch`); the before-await half is not. (ADR-0033)
- From a callback that OUTLIVES its widget (notice action, timer), use `composeErrorNoticeFor(l10n, ...)` with `AppLocalizations` read up front; no `context` or `ref` past the await. (ADR-0033)
- New operation ⇒ new tag + `error_intro*` key in both ARBs; the intro opens `error_noticeWithCause`, so it is CAPITALIZED, unpunctuated, and says only WHAT failed ("Couldn't load clients").
- A cause is one capitalized, actionable sentence — why AND what to do, joined by an em dash ("You appear to be offline — check your connection and try again."). `error_causeUnknown` is just "Please try again in a moment." — the intro named the failure. (ADR-0031)
- Never log inside list/item builders (rebuild spam); `CLI-LIST`'s first-page error indicator composes without logging.
- Pair every notice-only or `return false` catch with a `warn` (`catch (_) { return false; }` hides a broken plugin). Exceptions: item builders; the FCM background isolate (`writeWidgetPayloadJson` — no Riverpod container, nowhere to surface); `firebaseReadyProvider.future.catchError((Object _) {})` at its four gates (`account_status_provider`, `push_registration_controller`, `live_activity_registration_controller`, `presence_sync_controller`) — `splash_screen.dart` logs that shared future once, so per-gate logs would file four non-fatals for one event.

## Log-tag registry

Keep it EXHAUSTIVE — the tag lives ONLY here and in the warn label, so a stale registry makes Crashlytics triage guesswork. Regenerate by grepping `lib/` for each TAG LITERAL, never `logger.warn('`, which misses a tag passed as a named `tag:` (`launchExternalUri`, every `Debouncer.tagged`, `resolveUserDocId` in `core/app/device_deregistration.dart`, which interpolates `'$tag …'`), `label:` (`sign_in_controller.dart`'s `_bestEffortSignOut`; `auth_service.dart`'s `_renewSession` / `_refuseIfStillTheStartingPassword`) or `logContext:` (`splash_controller.dart`'s `_guard`) param, a `label` handed to a `_logFailure` wrapper (`google_places_repository.dart`, `wave_service.dart`), an interpolated label (`analytics_service.dart`'s `'ANALYTICS $label failed'`), a positional first arg (`image_viewer.dart`'s `_runExclusive`), interpolation (`wave_settings_section.dart`'s `'WAVE-$tag'` over bare `CONNECT`/`SYNC`/`RETRY`), or a ternary (`appointment_image_loader.dart`). Add a `tag:` param only to a helper with more than one caller. (ADR-0032)

**Notice-bearing tags** (log AND compose a notice):

| Tag | Intro key |
|---|---|
| `APPT-CREATE` | `error_introCreateAppointment` |
| `APPT-SAVE` | `error_introSaveAppointment` |
| `APPT-DEL` | `error_introDeleteAppointment` |
| `APPT-LOAD` | `error_introLoadAppointments` |
| `APPT-OPEN` | `error_introOpenAppointment` |
| `APPT-STATUS` | `error_introUpdateAppointmentStatus` |
| `APPT-FIELDNOTE` | `error_introSaveFieldNotes` |
| `APPT-REVIEW` | `error_introReviewOverdue` |
| `CLI-ADD` | `error_introAddClient` |
| `CLI-SAVE` | `error_introSaveClient` |
| `CLI-DEL` | `error_introDeleteClient` |
| `CLI-ARCH` | `error_introArchiveClient` |
| `CLI-LIST` | `error_introLoadClients` |
| `HIST-LOAD` | `error_introLoadHistory` |
| `DASH-LOAD` | `error_introLoadDashboard` |
| `LIVEMAP-LOAD` | `error_introLoadLiveMap` |
| `EMP-CREATE` | `error_introSaveEmployee` |
| `EMP-STATUS` | `error_introChangeEmployeeStatus` |
| `EMP-DELETE` | `error_introRemoveAccount` |
| `EMP-RESETPW` | `error_introResetPassword` |
| `ME-SAVE` | `error_introSaveMyDetails` · `error_introSaveAvailability` · `error_introSaveTravelAlerts` · `error_introSaveLocationSharing` |
| `ME-EMAIL` | `error_introChangeEmail` |
| `ACCT-DEL` | `error_introDeleteAccount` |
| `APPLOCK` | `error_introSaveAppLock` |
| `ACCT-SIGNOUT` | `error_introSignOut` |

- `CLI-ARCH` = archive AND un-archive (one toggle).
- `CLI-DEL`: typed `ClientsFailureHasHistory` FIRST ("archive it instead" is actionable), composer as fallback; both live in `ClientActionsHost` (`client_actions_host.dart`), so the list and the detail can't drift on either tag.
- `APPT-STATUS` = mark-done/cancel; `event_details_controller` returns an outcome, the widget composes.
- `APPT-REVIEW` = overdue bulk close; `OverdueReviewController` logs and returns `OverdueReviewOutcome`, the screen composes; load listener and cap warn share it.
- `EMP-DELETE` = remove a pending account; typed `EmployeesFailureAccountNoLongerPending` FIRST.
- `ACCT-SIGNOUT`: `delete_account_flow.dart` composes; `auth_service.dart`'s two sites only log (a sign-out failing during teardown has no screen left to notify). It stays here because the intro key exists — don't move it to log-only on the strength of the service's uses.
- Gone, don't re-add: `EMP-SAVE` (now `EMP-CREATE`), `EMP-REVOKE`, `WAVE-SCHED` / `WAVE-SCHEDULE` (gone from the app 2026-09-13; `WAVE-SCHED` lives on only as the `runWaveDaily` drain's log labels in `functions/wave/triggers.js`). (ADR-0032)

**Log-only tags** (no intro key):

- Shell: `ACCOUNT-EXIT`, `ANALYTICS`, `APP-SYNC`, `CARPLAY`, `DEEP-LINK`, `FLAGS`, `NOTICE`, `SETTINGS`, `SPLASH`, `TOUR`, `ONBOARD-GATE`
- Auth: `AUTH-SETUP` (also `resumeAfterSignUp`, `completeAccountSetup:`), `AUTH-SIGNIN`, `AUTH-PREFILL`, `AUTH-RESET`, `AUTH-CHANGEPW` (`ChangePasswordScreen`, `AuthService.completePasswordReset`; the route-in after a change logs under `AUTH-SETUP` via `resumeAfterSignUp`)
- Appointments: `APPT-BUSY`, `APPT-COUNT`, `APPT-IMG`, `APPT-RANGE`
- Clients: `CLI-SEARCH`, `CLI-BUILDINGS`, `CLI-CONTACT-SAVE`, `CLI-CONTACT-SYNC`, `HIST-SEARCH`
- Employees: `EMP-EMERGENCY`, `EMP-LOAD`, `EMP-TODAY`, `MYDET`
- Presence: `LIVEMAP-MARKERS`, `PRESENCE`
- Images: `IMG-DEL`, `IMG-DISK`, `IMG-LOAD`, `IMG-PICK`, `IMG-SAVE`, `IMG-SHARE`, `IMG-UPLOAD`
- Address: `ADDR-AUTO`, `ADDR-DETAILS`, `ADDR-PLACES`, `MAPS-KEY` (`_provideIosMapsApiKey`, bare `AppLogger()` before `runApp`), `LAUNCH-TEL`, `LAUNCH-EMAIL`, `LAUNCH-MAPS`, `LAUNCH-URL`. A typed Places failure logs once, as `ADDR-PLACES` (paused: breadcrumb); `ADDR-AUTO`/`ADDR-DETAILS` only untyped.
- Devices: `FCM`, `PUSH`, `PUSH-TAP`, `LIVE-ACT`, `WIDGET`, `WIDGET-TAP`, `SIRI`
- Permissions: `PERM-LOCATION`, `PERM-MEDIA`
- Wave: `WAVE-BOOT`, `WAVE-CONN`, `WAVE-CUST`, `WAVE-RETRY` (`wave_service.dart`), `WAVE-BADGE` (`wave_sync_badge.dart`), `WAVE-BLOCKED` (`firebase_clients_repository.dart`'s `watchBlockedClients`), and `WaveSettingsSection`'s `WAVE-CONNECT`, `WAVE-SYNC`, `WAVE-RETRY` (`WaveNetwork().toLocalizedMessage` carve-out, no key). A typed `WaveFailure` logs once, in `wave_service.dart` (paused: breadcrumb); the Settings three only as `(unexpected)`.

## A catch only reaches what is inside it

A discarded future has no caller, so its `try` is all that stands between a routine failure and a FATAL. (ADR-0034)

- Put every `await` the guard covers INSIDE the `try` — `hasError` sees a settled error, not one arriving mid-await.
- Keep a generic branch behind a typed `catch`, or other throws escape with no notice.
- Guard locally; never rely on another file swallowing its errors (`loadAll`).
- Keep the whole body of `unawaited(...)`, `Future.microtask(...)` or a fire-and-forget `sync()` inside the guard.
- An `async` handler on a `ValueChanged` is discarded: check `mounted` after the await (`context.mounted` from the wiring build in a `StatelessWidget`).
- Check `mounted` before `setState` after an await, even on SUCCESS — release skips the lifecycle assert, and `use_build_context_synchronously` can't see it.

## Notices that carry an action

- At most ONE action, on a success notice: `noticeServiceProvider.successWithAction(message, actionLabel:, onAction:)` (`core/notices/notice_service.dart`), which DISMISSES first so the action can push a notice of its own. `AppNotice.info`/`.error` take none — an error already says what to do in its cause sentence, and an action on an auto-dismissing notice is a race the user loses.
- Only an undo belongs there (mark-complete → `restoreAppointmentStatus`); anything deliberate goes on the screen.

## Action outcomes vs. errors

- Return a **sealed outcome** from a controller action with more than two states, never `Object?`/`bool` (`EventDetailsActionOutcome`: `Ok`/`Busy`/`Failed(error)`; `EventDetailsSaveOutcome`) — a sentinel compared with `identical()` lets a caller skip the third branch. (ADR-0036)
- Make a reentrancy skip a `Busy` member (`EventDetailsActionBusy`, `EmployeeSaveBusy`, `ClientSaveBusy`), never a fabricated exception — `_classifyError` keys on the `SocketException` type, so `SocketException('in-flight')` reads as offline. The client controller's `SocketException('offline')` stays (offline is intended there). (ADR-0036)
- Surface nothing for `Busy`; only a real failure composes a notice.

## Typed failures

- One sealed `Failure` family per feature, `lib/features/<f>/domain/<f>_failure.dart` (`AuthFailure`, `EmployeesFailure`, `MapsFailure`); cross-cutting in `core` (`ImageUploadFailure`). Base `Failure` (`lib/core/errors/failure.dart`) keeps `implements Exception` for `only_throw_errors`.
- Throw the typed failure; surface via `noticeServiceProvider.error(failure.toLocalizedMessage(context))`. Never `throw Exception(...)` — the string leaks.
- `AuthErrorMapper.map`: `AuthFailure` passes through, `FirebaseAuthException` maps by code, `FirebaseException(code: 'permission-denied')` → `AuthFailurePermissionDenied`, else `AuthFailureUnknown`. Services throw `AuthFailure`s unwrapped. Auth-flow rules rejection: check `firestore.rules` first.
- Only where the composer can't apply, reuse `error_somethingWentWrong` / `error_somethingWentWrongPleaseTryAgain` before adding a string.

## Logging & surfacing

- Push a user-visible failure (save/delete/status) via `noticeServiceProvider.error(<l10n string>)` from the widget, beside the `warn`.
- Inject `AppLogger` into services as an optional ctor param (default `AppLogger()`); never `FirebaseCrashlytics.instance`. `AppLogger.warn` hits Crashlytics only in `kReleaseMode`, so tests need no Firebase.
- Put one-shot `AsyncValue` side effects in `ref.listen`, never `.when`'s error branch (fires every rebuild).
- Pass `onError` to every raw `Stream.listen()` (`onError: (e, st) => logger.warn('<TAG>', e, st)`), or the error reaches the zone as an app crash.

## Crashlytics severity

Severity is classified in exactly two places — `AuthFailure.isExpected` and `isFatalUnhandledError` — never re-decided at a call site; filing routine outcomes as errors buries the real ones. (ADR-0037)

- Log every auth catch via `logger.authFailure(label, failure, error, st)` (`AuthFailureLogging`, `features/auth/domain/auth_failure.dart`), never a hand-rolled `if (failure.isExpected)`. `isExpected` (user-correctable) → breadcrumb; misconfig, rules rejection, unmapped, half-created → error record; a new variant picks at compile time. The breadcrumb carries only `label` and `failure.runtimeType`, never email, password or code. Sites: `sign_in_controller`, `account_setup_screen`, `change_password_screen`, `forgot_password_screen`, `auth_service`, `employee_form_controller`, `my_details_screen`, `delete_account_flow`.
- `AppLogger.breadcrumb` leaves a trail without filing a non-fatal.
- Keep `isFatalUnhandledError` (`core/logging/unhandled_error_severity.dart`) gating `fatal:` on `PlatformDispatcher.onError` and `runZonedGuarded` (`main.dart`): an unhandled Firestore `permission-denied` is auth teardown racing a live listener — non-fatal, still recorded. `FlutterError.onError` stays unconditionally fatal — that path is framework/build errors, not the teardown race.
