---
alwaysApply: true
---

# Error Handling

- Never swallow errors silently. Log or rethrow with added context about what operation failed.
- Catch specific Firebase exceptions (`FirebaseAuthException`, `FirebaseException`) and surface meaningful messages to the UI.
- Never expose raw Firebase error codes or stack traces directly in UI text.
- Async calls in `initState` / stream subscriptions must have `.catchError` or `try/catch`. Unhandled stream errors crash the app silently.
- Retry transient Firebase errors (network timeouts) with backoff where appropriate. Fail fast on auth and permission errors — with one sanctioned exception: a Firestore read/stream fired right after sign-in can return `permission-denied` until the freshly minted auth token propagates, so retry *that* case via `lib/core/utils/retry.dart` (`retryAsync` for a one-shot read, `retryStream` for a live query). The appointments stream (`retryStream`) and `sign_in_controller.dart`'s `findUserByUid` read (`retryAsync`) are the reference uses; a new query fired immediately post-sign-in must wrap through one of them or it can spuriously fail the first time. **The `retryWhen` predicate is `isAuthPropagationDenied`, exported from that same file, and it is now the DEFAULT on both helpers** — it was copied byte-identically into three repositories, two of which carried a "keep in sync" comment naming only ONE twin, so neither author knew there were three, and `retryAsync` had no predicate at all, so it retried a genuine rules rejection three times before surfacing it. Never re-declare it locally, and never hand-roll a `catch (FirebaseException)`-then-delay inline — that is exactly what `_retryOnAuthPropagation` was, sitting under a rule that named it as the *reference use* of the shared helper it did not call. **The delay ladder has one owner too, `kAuthPropagationDelays`** (beside the predicate) — it is the default for `delays:` on both helpers, so a call site names it only to be explicit, never to pick a different budget.
- `FirebaseException` with code `permission-denied` usually means a Firestore rules issue, not a bug — log clearly.

## Cause notices (generic catch sites)

- When no typed `Failure` applies, surface via
  `composeErrorNotice(context, intro:, error:)`
  (`lib/core/errors/error_cause.dart`) — renders `"{intro}. {cause}"` from 7
  sanitized causes (offline / permission-denied / not-found / signed-out /
  too-many-attempts / invalid-data / unknown).
  Never `error_somethingWentWrong` directly at new catch sites.
- **The notice carries NO support tag** (owner call, 2026-08-04, when the app
  stopped being a testing build). It used to end `. (CLI-DEL)` so a user
  screenshot mapped to a Crashlytics line; that is developer scaffolding on a
  screen a customer reads, and it cost the room the message needed to say what
  to do next. Tags survive **only** as the `logger.warn` label prefix — don't
  re-add one to a user-facing string, here or anywhere.
- The site's `logger.warn` label MUST still start with its tag
  (`'CLI-DEL deleteClient failed'`) — it is now the only place the tag lives, so
  a Crashlytics search still finds the operation. Call `warn` BEFORE any
  `if (!mounted) return;` guard — `AppLogger` is context-free, and the log must
  survive unmount.
- **But resolve the logger BEFORE the first `await`, never inside the `catch`:
  `final logger = ref.read(loggerProvider);`.** The two halves of this rule
  fight each other otherwise, and the loser is a crash. `AppLogger` is
  context-free, but `ref` is not: under Riverpod 3 `ref.read` on an unmounted
  consumer **throws a `StateError`** (`flutter_riverpod/lib/src/core/consumer.dart`,
  `_assertNotDisposed` — an unconditional throw, not a debug assert, and it
  guards `read`/`watch`/`listen`/`invalidate`/`refresh`). So
  `ref.read(loggerProvider).warn(...)` above a mounted guard throws exactly in
  the case the guard exists for. In `address_autocomplete_field.dart` that
  escaped a `Debouncer` timer callback into the zone handler as a **FATAL**,
  every time an address lookup failed after its sheet was dismissed. Hoisting
  the read satisfies both halves: the log still survives unmount, and nothing
  touches `ref` after the await. The same applies to any other provider a
  post-await path needs (`noticeServiceProvider`, a repository) — read it up
  front. `ref.read` inside a `catch` is mechanically greppable; treat a new one
  as a bug.
- **A callback that OUTLIVES its widget composes through `composeErrorNoticeFor(l10n, ...)`,
  resolving the `AppLocalizations` up front.** `composeErrorNotice` takes a
  `BuildContext` only to reach `context.l10n`, and a notice ACTION runs by
  definition after the surface that raised it may be gone — the mark-complete
  Undo fires from a timer callback with the sheet already popped. Same rule as
  the logger and the repository: read what you need BEFORE the await, and never
  touch `context` or `ref` on the far side. An `AppLocalizations` is a plain
  object with no element behind it, so it is safe to keep.
- Typed-Failure branches stay first; the composer is the generic fallback only.
- New operation ⇒ new log tag + an `error_intro*` key in both ARBs. **The intro
  is the first sentence of `error_noticeWithCause` (`"{intro}. {cause}"`), so it
  is CAPITALIZED and carries no trailing punctuation** — every shipped key reads
  "Couldn't save the employee", "Couldn't load clients". It says WHAT failed and
  nothing else.
- **A cause says why AND what to do about it**, in one sentence, joined by an em
  dash: "You appear to be offline — check your connection and try again." They
  are full capitalized sentences (they follow the intro's period), not the
  lowercase fragments they were before. `error_causeUnknown` is deliberately
  just "Please try again in a moment." — the intro already named the failure, so
  repeating "something went wrong" there adds nothing. Keep a new cause
  actionable or don't add it.
- Never log inside list/item builders (rebuild spam) — e.g. CLI-LIST's
  first-page error indicator composes without logging.
- **Existing log tags — this list is meant to be EXHAUSTIVE.** Since notices
  stopped carrying a support code (2026-08-04) the tag lives ONLY here and in
  the `logger.warn` label, so a stale registry makes Crashlytics triage
  guesswork. **Regenerate it by grepping `lib/` for the TAG LITERAL, never for
  `logger.warn('`** — most sites do not spell the two together, and the shapes
  that hide a tag from that grep are:

  - a named `tag:` parameter on a helper that logs for you —
    `launchExternalUri` (`LAUNCH-TEL`, `LAUNCH-MAPS`, `LAUNCH-URL`,
    `LAUNCH-EMAIL`), the shared `resolveUserDocId`
    (`core/app/device_deregistration.dart`), which the three device-registration
    controllers pass `PUSH` / `LIVE-ACT` / `PRESENCE` into and which then
    INTERPOLATES it (`'$tag resolve users doc failed'`), so the tag hides from
    the grep twice over, and every `Debouncer.tagged` call site. **A
    `tag:` parameter earns its keep only where the helper has more than one
    caller** — the save pipeline's photo cleanup took one, lost its second
    caller when the whole-job delete moved server-side, and the parameter then
    hid `APPT-SAVE` from the grep for the sake of a single possible value;
  - a POSITIONAL first argument to a helper that logs —
    `image_viewer.dart`'s `_runExclusive` (`IMG-SAVE`, `IMG-SHARE`);
  - built by interpolation — `wave_settings_section.dart`'s `'WAVE-$tag'`,
    where the three suffixes are spelled as bare `tag:` values (`CONNECT`,
    `SYNC`, `RETRY`) and the prefix is added at the logging site,
    so neither half greps as the whole tag;
  - spelled inside a ternary — `appointment_image_loader.dart` (`IMG-LOAD`,
    twice);
  - a named `logContext:` parameter on a helper that logs for you —
    `splash_controller.dart`'s `_guard` (`SPLASH`), whose call sites pass the
    tag as part of a longer sentence;
  - a named `label:` parameter on a helper that logs for you —
    `sign_in_controller.dart`'s `_bestEffortSignOut` (`AUTH-SIGNIN`, twice).
    Same shape as `tag:` under a different name, which is exactly why the
    grep has to be for the TAG, not for the parameter.

  This paragraph previously claimed there were exactly four `tag:` sites and
  named two (`IMG-SAVE`/`IMG-SHARE`) that are positional, not named. Following
  it as written missed seven tags — and it is the procedure that keeps the
  registry EXHAUSTIVE, so describing the shapes beats counting the sites.

  **Notice-bearing tags** — the site logs AND composes a user-facing notice, so
  each has an `error_intro*` ARB key:

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
  | `ME-SAVE` | `error_introSaveMyDetails` · `error_introSaveAvailability` · `error_introSaveTravelAlerts` · `error_introSaveLocationSharing` |
  | `ME-EMAIL` | `error_introChangeEmail` |
  | `ACCT-DEL` | `error_introDeleteAccount` |
  | `APPLOCK` | `error_introSaveAppLock` |
  | `ACCT-SIGNOUT` | `error_introSignOut` |

  Six of those carry a per-tag caveat. CLI-ARCH covers archive AND un-archive,
  which share one tag because they are one toggle. CLI-DEL's typed
  `ClientsFailureHasHistory` branch runs FIRST — "archive it instead" is
  actionable where the generic cause notice is not — and the composer is the
  fallback; both live in the shared `ClientActionsHost` mixin, so the list and
  the detail can't drift on either tag. APPT-STATUS = mark-done/cancel;
  `event_details_controller`'s status setters return a sealed
  `EventDetailsActionOutcome`, so the widget composes the notice. APPT-REVIEW = the
  overdue review's bulk Complete / Not done; `OverdueReviewController` logs it
  and returns a sealed `OverdueReviewOutcome`, so the screen composes the
  notice, and the screen's load listener and the repository's cap warn log under
  the same tag. EMP-DELETE =
  removing a pending account, P4c's replacement for the retired EMP-REVOKE; its
  typed `EmployeesFailureAccountNoLongerPending` branch runs FIRST and the
  composer is the fallback. ACCT-SIGNOUT is spelled at TWO layers and only one of them composes a notice: `delete_account_flow.dart` surfaces `error_introSignOut`, while `auth_service.dart`'s two sites are log-only (a sign-out failing during teardown has no screen left to notify). It is listed here rather than below because the intro key exists; don't move it back on the strength of the service's uses alone. **`EMP-SAVE` is GONE** — the employee save path logs
  under EMP-CREATE now; don't re-add it from an older copy of this list.

  **Log-only tags** — no notice intro, so no ARB key. Everything else:

  - App shell / lifecycle: `ACCOUNT-EXIT`, `APP-SYNC`, `CARPLAY`, `DEEP-LINK`,
    `NOTICE`, `SETTINGS`, `SPLASH`, `TOUR`, `ONBOARD-GATE`
  - Auth / account: `AUTH-SETUP`, `AUTH-SIGNIN`, `AUTH-PREFILL`, `AUTH-RESET`
    (`AUTH-SIGNIN`/`AUTH-PREFILL` added 2026-08-25, replacing six `login.*`
    dotted-lowercase tags that were in no registry at all — the whole sign-in
    path was invisible to a Crashlytics search by tag. That sweep MISSED
    `auth.forgot_password`, the seventh, which survived until 2026-09-05 and is
    `AUTH-RESET` now. `AUTH-SETUP` also covers `resumeAfterSignUp`, which is
    named for the sign-up flow P4c deleted and actually serves account SETUP,
    and — since the same pass — the four `auth_service.dart`
    `completeAccountSetup:` labels, which carried NO tag at all; one of them is
    the breadcrumb for `AuthFailureStartingPasswordReused`, the load-bearing
    guard.)
  - Appointments: `APPT-BUSY`, `APPT-COUNT`, `APPT-IMG`, `APPT-RANGE`
  - Clients / history: `CLI-SEARCH`, `CLI-CONTACT-SAVE`, `CLI-CONTACT-SYNC`,
    `HIST-SEARCH`
  - Employees / self: `EMP-EMERGENCY`, `EMP-LOAD`, `EMP-TODAY`, `MYDET`
  - Presence / map: `LIVEMAP-MARKERS`, `PRESENCE`
  - Images: `IMG-DEL`, `IMG-DISK`, `IMG-LOAD`, `IMG-PICK`, `IMG-SAVE`,
    `IMG-SHARE`, `IMG-UPLOAD`
  - Address / launchers / maps: `ADDR-AUTO`, `ADDR-DETAILS`, `ADDR-PLACES`,
    `MAPS-KEY` (`main.dart`'s `_provideIosMapsApiKey`, which is one of the very
    few sites that logs through a bare `AppLogger()` rather than
    `loggerProvider` — it runs before `runApp`, so there is no container yet),
    `LAUNCH-TEL`, `LAUNCH-EMAIL`, `LAUNCH-MAPS`, `LAUNCH-URL`
  - Devices / delivery: `FCM`, `PUSH`, `PUSH-TAP`, `LIVE-ACT`, `WIDGET`,
    `WIDGET-TAP`, `SIRI`
  - OS permissions: `PERM-LOCATION`, `PERM-MEDIA`
  - Wave: `WAVE-BOOT`, `WAVE-CONN`, `WAVE-CUST`, `WAVE-RETRY`
    (all `wave_service.dart`), `WAVE-BADGE` (`wave_sync_badge.dart`),
    `WAVE-BLOCKED` (`firebase_clients_repository.dart`'s `watchBlockedClients`), plus the
    three `WaveSettingsSection` composes by interpolation — `WAVE-CONNECT`,
    `WAVE-SYNC`, `WAVE-RETRY`. Note `WAVE-RETRY` is spelled at two layers.
    `WAVE-SCHED` and `WAVE-SCHEDULE` are GONE from the app with the import
    cadence (2026-09-13). The Settings-layer three are the
    `WaveNetwork().toLocalizedMessage` carve-out from `composeErrorNotice`, so
    they surface a message without an `error_intro*` key.
- **A user-visible failure notice is not a substitute for a log.** A `catch` that
  only pushes a notice (or only returns `false`) is invisible in Crashlytics —
  every swallowed failure needs a `warn` beside it. The sanctioned exceptions are
  list/item builders (rebuild spam), the FCM background isolate
  (`writeWidgetPayloadJson` — no Riverpod container, nowhere to surface), and
  **`firebaseReadyProvider.future.catchError((Object _) {})`** at the four gate
  points that await it (`account_status_provider`, `push_registration_controller`,
  `live_activity_registration_controller`, `presence_sync_controller`):
  `splash_screen.dart` already logs that shared future's failure once, and Dart
  delivers the same settled error to every listener, so logging at each gate
  would file four non-fatals for one event. A
  fail-closed `catch (_) { return false; }` is the easiest one to miss: it hides
  a permanently-broken plugin channel behind a feature that just "doesn't work".

## A catch only reaches what is inside it

Three fatals shipped in one release from catches that existed, looked right,
and did not cover the throw (2026-08-31). Each shape is worth recognising:

- **An `await` hoisted ABOVE the `try`.** `_loadClientIfNeeded` awaited
  `currentUserDocProvider.future` above its try, inside a DISCARDED
  `Future.microtask`, and `PushRegistrationController._syncGuarded` awaited
  `_refreshSub.cancel()` above its own. A `hasError` guard covers a SETTLED
  error, not one arriving during the await. Nothing awaits a discarded future
  or an unawaited `sync()`, so the throw goes straight to the zone handler and
  is filed as an app-level FATAL from a sheet that merely failed to prefill a
  name. Put every await the guard is for INSIDE the try —
  `PresenceSyncController` already does, which is how the drift was visible.
- **A `catch` narrowed to one type.** `WaveSettingsSection` caught only
  `WaveFailure`, so any other throw escaped with NO notice shown: the admin
  taps Sync and nothing visibly happens. Keep the typed branch first and a
  generic branch behind it — that is what `composeErrorNotice` is for.
- **Safety that depends on a property of a DIFFERENT file.** The photo picker's
  preload relied on `loadAll` swallowing its own per-image failures. That is
  true today and is not a guarantee: an OOM decoding a large batch, or one
  refactor there, and an unawaited future takes the app down from a gallery
  that merely failed to render.

- **A `ValueChanged` wired to an `async` method discards its future**, so the
  work after the await has no caller left and no `mounted` to check. The
  recents row is the worked example: `onSelectRecent` is `void`, the handler
  awaits a Firestore read, and the controller writes on the far side would
  throw "used after being disposed" into the zone as a FATAL if the sheet was
  dismissed meanwhile. In a `StatelessWidget` there is no `mounted` — take the
  `BuildContext` from the build that wired the callback and gate on
  `context.mounted` after the await.

The common tell is an unawaited or discarded future: it has no caller left to
catch anything, so its `try` is the only thing between a routine failure and a
fatal. Treat `unawaited(...)`, `Future.microtask(...)` and a fire-and-forget
`sync()` as requiring the whole body inside the guard.

## Notices that carry an action

- **A success notice may carry ONE action, through
  `noticeServiceProvider.successWithAction(message, actionLabel:, onAction:)`**
  (`core/notices/notice_service.dart`). It renders as a button inside the
  notice and DISMISSES it before running, so the action can push a notice of
  its own. `AppNotice.info`/`.error` deliberately take none — an error already
  says what to do next in its cause sentence, and an action on a notice that
  auto-dismisses is a race the user loses.
- **Only an undo belongs there.** The one caller is mark-complete, whose Undo
  calls `restoreAppointmentStatus`. A notice is not a menu: anything the user
  might want to do deliberately belongs on the screen, not on a banner that
  disappears.

## Action outcomes vs. errors

- A controller action whose result has more than two states returns a **sealed
  outcome**, never a bare `Object?`/`bool`. `EventDetailsController`'s status
  setters return `EventDetailsActionOutcome` (`Ok` / `Busy` / `Failed(error)`)
  beside the existing `EventDetailsSaveOutcome`. They previously returned
  `Object?` with `null` = success, so a write **skipped by the reentrancy
  guard** was indistinguishable from one that committed — the sheet announced
  "marked as complete" and closed without having written anything. A sealed
  family makes the compiler force the third branch at every call site; a
  sentinel compared with `identical()` does not.
- **A reentrancy skip is a `Busy` member, never a fabricated exception.**
  `EmployeeSaveBusy` and `ClientSaveBusy` join `EventDetailsActionBusy` for this.
  All three save controllers previously returned
  `XSaveFailed(SocketException('in-flight'))`, and `_classifyError`
  (`error_cause.dart`) keys on the `SocketException` **type** — so a double-tap
  rendered "Couldn't save … — you appear to be offline" while perfectly online,
  with the real save succeeding behind the error. Note the sibling
  `SocketException('offline')` sentinel in the client controller is correct and
  stays: there the offline classification is the intended one.
- A no-op outcome (`Busy`) surfaces **nothing** — neither a success notice nor
  an error. Only a real failure composes a notice.

## Typed failures

- Each feature defines a sealed `Failure` family at
  `lib/features/<f>/domain/<f>_failure.dart` (see `AuthFailure`,
  `EmployeesFailure`, `MapsFailure`); cross-cutting ones live in `core`
  (e.g. `ImageUploadFailure` in `lib/core/images/`). The base `Failure`
  (`lib/core/errors/failure.dart`) `implements Exception` so throwing one
  satisfies `only_throw_errors` — keep that when adding failure families.
  Repositories throw the typed failure; catch sites surface via
  `noticeServiceProvider.error(failure.toLocalizedMessage(context))`.
  Don't reach for `throw Exception(...)` — the string leaks to UI/logs.
- `AuthErrorMapper.map` passes through `AuthFailure` instances unchanged, maps
  `FirebaseAuthException` by code, and converts
  `FirebaseException(code: 'permission-denied')` to `AuthFailurePermissionDenied`;
  anything else becomes `AuthFailureUnknown` → "Something went wrong." Throw typed
  `AuthFailure`s directly from services — don't wrap them in another exception.
  When a rules rejection surfaces in the auth/sign-up flow, check
  `firestore.rules` first, not Firebase Auth error codes.
- Failure UX strings already exist — `somethingWentWrong`,
  `somethingWentWrongPleaseTryAgain`. Reuse before adding new ones. (Most
  generic catch sites now compose via `composeErrorNotice` instead.)

## Logging & surfacing

- Catch blocks log via `ref.read(loggerProvider).warn('label', e, st)`. For
  user-visible failures (save/delete/status), also push
  `noticeServiceProvider.error(<l10n string>)` from the widget layer.
- Services that log from catch blocks inject `AppLogger` as an optional ctor
  param (default `AppLogger()`) — never call `FirebaseCrashlytics.instance`
  directly. `AppLogger.warn` only fires Crashlytics in `kReleaseMode`, so tests
  pass without Firebase init.
- One-shot side effects on `AsyncValue` transitions (e.g., stream goes
  data → error) belong in `ref.listen`, not in `.when`'s error branch.
  The `.when` error branch fires on every rebuild and would spam the
  notice surface.

## Crashlytics severity

Not every failure is a defect. Filing routine outcomes as error records buries
the real ones, so severity is classified in exactly two places — don't
re-decide it at a call site.

- **Expected auth failures leave a breadcrumb, not an error record.**
  `AuthFailure.isExpected` (`features/auth/domain/auth_failure.dart`) buckets
  each variant of the sealed family: user-correctable outcomes (wrong password,
  bad/expired signup code, offline, rate-limited) are `true`; misconfiguration,
  a rules rejection, an unmapped error, and a half-created account are `false`
  and keep recording. Adding a variant forces a bucket at compile time.
- **Every auth catch site logs through `logger.authFailure(label, failure,
  error, st)`** (the `AuthFailureLogging` extension on `AppLogger`, beside
  `isExpected`) — never hand-roll the `if (failure.isExpected)` branch. The
  sites (`sign_in_controller`, `account_setup_screen`, `forgot_password_screen`,
  `auth_service`, `my_details_screen`, `delete_account_flow`) previously
  double-filed the same failure from two layers. (This said "the four sites"
  and named `create_account_screen`, which P4c deleted; the delete-account
  branch was the one that had no log at all, and it lives in
  `settings/widgets/views/delete_account_flow.dart` — this bullet named
  `settings_screen`, where it has never been.) `label` stays the Crashlytics warn tag, and the
  breadcrumb carries only the label plus `failure.runtimeType` — never the
  email, password, or code.
- `AppLogger.breadcrumb` is the no-error-record variant of `warn`: it keeps a
  trail for whatever crash follows without filing a non-fatal of its own.
- **An unhandled Firestore `permission-denied` is a non-fatal, not a crash.**
  `isFatalUnhandledError` (`core/logging/unhandled_error_severity.dart`) gates
  the `fatal:` flag on both global handlers in `main.dart`
  (`PlatformDispatcher.onError` + `runZonedGuarded`). That error is the
  signature of auth teardown racing a live listener — revoking the token
  (sign-out, account deletion, the signup-code rollback) denies any snapshot
  stream still attached, and the app keeps running. It is still *recorded*, and
  the stream that owns the query logs its own tagged `warn`, so a genuine rules
  rejection surfaces twice. `FlutterError.onError` stays unconditionally fatal —
  that path is framework/build errors, not this race.
- **A raw `Stream.listen()` must pass `onError`.** Without it the error escapes
  to the zone handler and is stamped as an app-level crash from a stream that
  had a perfectly good place to log it. Use
  `onError: (e, st) => logger.warn('<TAG>', e, st)`.
