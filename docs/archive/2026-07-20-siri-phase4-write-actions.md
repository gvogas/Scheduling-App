# Siri Phase 4 — voice write actions (execution doc)

> **CANCELLED 2026-10-09 (owner): not needed.** Nothing from this doc was ever landed.

Companion to [`2026-07-19-siri-app-intents-implementation.md`](./2026-07-19-siri-app-intents-implementation.md)
(Phase 4 section) and the design doc. Phases 1–3 are read-only and Firebase-free;
**Phase 4 is the inflection point** — the first authenticated Firebase client
inside the `SiriIntents` extension. Architecture chosen 2026-07-20:
**direct writes from the extension** (true hands-free "Hey Siri, cancel my 2 pm"),
not app-handoff.

This doc resolves the two paper blockers, surfaces a third the earlier plan
missed, and lays out the exact console / Xcode / code steps. **Nothing here is
landed in the repo yet** — most of it (entitlements, SPM, a 2nd Firebase app)
would break the currently-green build until the owner-side console/portal work is
done in lockstep, so it is specified here to execute as one Mac session.

---

## The three decisions

### Decision A — Auth credential sharing (keychain) ✅ mechanical

`firebase_auth` (Dart) exposes no keychain-group API; the mechanism is native:

- Add **Keychain Sharing** capability to the Runner App ID **and** the
  `net.vogas.scheduling.SiriIntents` App ID in the Apple Developer portal, group
  `$(AppIdentifierPrefix)net.vogas.scheduling`.
- `ios/Runner/Runner.entitlements` and `ios/SiriIntentsExtension.entitlements`
  each gain:
  ```xml
  <key>keychain-access-groups</key>
  <array><string>$(AppIdentifierPrefix)net.vogas.scheduling</string></array>
  ```
- `Auth.auth(app:).useUserAccessGroup("$(AppIdentifierPrefix)net.vogas.scheduling")`
  in `AppDelegate.swift` **and** the extension bootstrap.

⚠️ Landing the entitlement XML **before** the portal capability exists breaks
signed builds (`flutter run`) with a provisioning mismatch — do the portal step
first, in the same session.

### Decision B — App Check / App Attest per bundle id ✅ resolved: 2nd Firebase app

App Attest keys are bound to `{TeamID, BundleID}`. Firebase App Check validates
an attestation against the **registered Firebase iOS app's** bundle id. Runner's
Firebase app is `net.vogas.scheduling`; the extension's process bundle id is
`net.vogas.scheduling.SiriIntents`. With App Check **enforced** on Firestore
(it is — `AppleAppAttestProvider` in `main()`), the extension's writes are
rejected with an opaque `permission-denied` unless it presents an App Check
token minted for **its own** bundle id.

Resolution: **register a second Firebase iOS app** in project
`schedulingapp-88727` with bundle id `net.vogas.scheduling.SiriIntents`, enable
**App Attest** for it (Firebase Console → App Check → the new app; App Attest
needs no `.p8`), and have the extension init a Firebase app with that app's
`FirebaseOptions` + `AppAttestProvider`.

### Decision C — the tension the earlier plan missed ⚠️ Auth vs. App Check

Decisions A and B **conflict**. Firebase Auth's `useUserAccessGroup` persistence
is keyed by the **Firebase app** (app id / name), so it only auto-restores the
signed-in user when the extension uses the **same** Firebase app as Runner. But
Decision B forces the extension onto a **different** Firebase app (2nd app id,
for App Check). A different Firebase app will **not** pick up Runner's
keychain-stored user, even in the same access group — so the extension boots
unauthenticated and every write fails the rules' `request.auth` check.

Two coherent ways out (pick one on the Mac; **custom-token is recommended**):

1. **Custom-token handoff (recommended).** The extension uses its own Firebase
   app (app id B) purely so App Check passes, and gets its *user* from a
   short-lived **custom token**:
   - New callable `mintSiriExtensionToken` (App Check + auth + active-user
     guard) → `admin.auth().createCustomToken(uid)`; called by the **app**
     (which is already App-Check-valid) on every account-doc emission +
     hourly-ish, and the token is stored in the **shared keychain access group**
     (NOT the App Group — a bearer credential must not sit in a
     readable-when-locked container).
   - The extension, before a write, reads the token and
     `Auth.auth(app: ext).signIn(withCustomToken:)`. A custom token is ~1 h TTL;
     if it is missing/expired the intent fails **closed** with "Open ES Pro to
     enable Siri actions" (a stale credential can never leak a write).
   - Sign-out / deletion clears the keychain token (beside the existing
     snapshot + push-to-start teardown), so a signed-out device can't write.
   - Cost: one Cloud Function + a token-lifecycle. This is the "earlier draft"
     the Phase-4 plan waved off — it turns out to be **required** once App Check
     forces a 2nd Firebase app. It is not optional under Decision B.

2. **Verify same-app App Check first (cheaper if it works).** Before building
   the custom-token path, test empirically whether the extension can use
   **Runner's** Firebase app (app id A, so keychain Auth "just works") while
   still passing App Check — i.e., whether an App Attest attestation for bundle
   `.SiriIntents` is accepted by app A's App Check when the extension's bundle
   id is added to app A's App Attest config. Firebase's console models one
   bundle id per iOS app, so this **likely fails**, but it is a 30-minute test
   on the Mac that, if it passed, would delete the entire custom-token path.
   If it fails (expected), fall back to option 1.

**Do C's 30-minute test first.** Its outcome decides whether Phase 4 is "2nd app
+ entitlements + intents" or "…+ a whole custom-token subsystem."

---

## Write-shape parity (the review invariant)

Siri writes go through the **same Firestore shape** the Dart repo produces, so
`firestore.rules` and the status allowlist apply unchanged. Swift calls
Firestore directly, so parity is enforced by review, not by shared code.

- **Cancel** / **Complete** — mirror `updateAppointmentStatus`
  ([`firebase_appointments_repository.dart:233`](../../lib/features/calendar/data/firebase_appointments_repository.dart#L233)):
  ```
  appointments/{id}.update({ status: <'cancelled'|'done'>, updatedAt: serverTimestamp() })
  ```
  Only the four allowlisted statuses are legal; the extension must hard-code
  `'cancelled'` / `'done'` (never echo a read-back `overdue`/`confirmed`).
- **Reschedule** — a full re-serialize (mirrors `updateAppointment`): re-write
  the record with new `startTime`/`endTime`, **status normalized via the
  allowlist**, and **original `employeeIds` preserved** (CLAUDE.md invariant —
  the picker only shows active staff). Heaviest; lands after cancel/complete.
- **Book** — `addAppointment` shape: new doc, `status: 'pending'`,
  `createdAt`/`updatedAt` server timestamps, client resolved by name, default
  duration. Lands last (needs client resolution + duration default).

All four: resolve the target by the snapshot `id` already carried in
`schedule_snapshot` (booking resolves a client by name), `requestConfirmation`
reads the change back **by voice**, then commit. **Write intents MUST NOT set
`authenticationPolicy = .alwaysAllowed`** (that is for reads only) — a write
requires device unlock.

### Reconciled against the code 2026-08-10 — five constraints this doc predates

Nothing here is landed, and the write shapes above are still right. What has
changed underneath them:

- **Cancel is admin-only, in the rules.** `allow update` on `/appointments` gives an
  assigned employee exactly one power: flipping `status` to `'done'`, with the diff
  restricted to `status` + `updatedAt`. So "Hey Siri, cancel my 2 pm" **fails with
  `permission-denied` for a technician** and always will — the phrase set must either
  be admin-gated or the intent must answer "only your admin can cancel a job" rather
  than surfacing a rules rejection as a Siri error. **Complete** is the one write every
  role can do. Decide this before writing the phrases; it changes which intent ships first.
- **A `done` write must carry NOTHING but `status` and `updatedAt`.** The employee rule is
  `affectedKeys().hasOnly([...])`, so a stray field — a client-side timestamp, a
  `seriesOpId`, an analytics breadcrumb — turns a working write into an opaque
  `permission-denied`. The Dart repo stamps `seriesOpId` on **cancel only** for exactly
  this reason. A Siri cancel is a single occurrence, so it needs no op-id; if a future
  "cancel the whole series" intent appears, it does.
- **The Live Activity ends itself.** `endCardOnTerminal` in the appointment write trigger
  ends the Lock Screen card on done, cancelled, deleted and unassigned, unconditionally.
  A Siri write inherits that for free — do **not** add an `endAllActivities()` call to the
  extension, which is device-wide and would kill the card for a different job.
- **Reschedule now edits a RUN, not a slot.** An appointment may span up to
  `maxAppointmentSpanDays` (14) and its two times are a **daily window** — 9–5 means 9–5 on
  each day, and an end at or before the start means the window crosses midnight. A voice
  reschedule that rewrites `startTime`/`endTime` must resolve the pair the way the app does
  (`appointmentSpan`), respect the cap, and — if it does a conflict check at all — compare
  **daily windows** (`dailyWindowsOverlap`), never raw instants, or it will report a phantom
  clash for any evening job inside a multi-day run. Given that, reschedule is a bigger step
  than "heaviest of the four" implied in July.
- **Book resolves a client that may be archived.** Archived clients stay **searchable and
  bookable** by design (2026-08-03), so a name match hitting one is correct, not a bug —
  but the confirmation read-back should say so, since the admin archived them for a reason.

One thing that got easier: the snapshot already drops records with a null/empty `id`, so
"resolve the target by the snapshot `id`" is now guaranteed rather than hoped for.
**But if Plan 2 lands first the snapshot is v3**, carrying per-day slices — check
`scheduleSnapshotVersion` before writing the decoder against v2's shape.

---

## Mac execution runbook (one session, in order)

1. **Portal** — add Keychain Sharing to both App IDs (Runner +
   `…​.SiriIntents`); confirm App Attest capability on the extension App ID.
2. **Firebase Console** — register the 2nd iOS app
   (`net.vogas.scheduling.SiriIntents`); App Check → enable **App Attest** for
   it. Download its `GoogleService-Info.plist` (or note its `GOOGLE_APP_ID` +
   `API_KEY` to build `FirebaseOptions` in Swift, matching the env-based style
   in `lib/firebase_options.dart`). Carry the plist out-of-band; gitignore it.
3. **Decision C 30-min test** — try Runner's app id + the extension's App Attest
   against App Check enforcement. Pass → skip the custom-token subsystem; fail
   (expected) → build `mintSiriExtensionToken` + the keychain-token lifecycle.
4. **Entitlements** — add `keychain-access-groups` to both entitlement files;
   add `appattest-environment=production` to the extension entitlements.
5. **SPM** — add `firebase-ios-sdk` products **FirebaseAuth, FirebaseFirestore,
   FirebaseAppCheck** to the `SiriIntents` target only (keep the product set
   minimal — extension memory budget). The package is already resolved for
   Runner; this is adding target membership, not a new package.
6. **Code** — add `FirebaseExtensionBootstrap.swift` + the write intents to the
   `SiriIntents` folder AND the target (explicit file refs — see the Siri
   README). Reference implementations below.
7. **Build + device** — `flutter build ios`; then the Phase-4 verification
   checklist.

---

## Reference Swift

### `FirebaseExtensionBootstrap.swift`
```swift
import FirebaseCore
import FirebaseAuth
import FirebaseAppCheck
import FirebaseFirestore

@available(iOS 16.0, *)
enum FirebaseExtensionBootstrap {
    private static let appName = "siriExtension"
    private static let accessGroup = "$(AppIdentifierPrefix)net.vogas.scheduling"

    /// Idempotent. Returns a Firestore handle authed as the signed-in user, or
    /// nil when no credential is available (fails closed — the intent then tells
    /// the user to open the app).
    static func ready() async -> Firestore? {
        let app = configuredApp()
        // App Attest for THIS extension's bundle id (2nd Firebase app).
        AppCheck.setAppCheckProviderFactory(ExtensionAppCheckFactory())
        guard await restoreAuth(app: app) else { return nil }
        return Firestore.firestore(app: app)
    }

    private static func configuredApp() -> FirebaseApp {
        if let existing = FirebaseApp.app(name: appName) { return existing }
        // Options for the 2nd Firebase app (bundle .SiriIntents). Prefer a
        // bundled GoogleService-Info-Siri.plist; or build FirebaseOptions from
        // the env-style values, mirroring lib/firebase_options.dart.
        let options = FirebaseExtensionOptions.make()
        FirebaseApp.configure(name: appName, options: options)
        let app = FirebaseApp.app(name: appName)!
        try? Auth.auth(app: app)
            .useUserAccessGroup(accessGroup)   // Decision A / C-option-2
        return app
    }

    // Decision C: custom-token path. Reads the app-minted token from the shared
    // keychain group and signs in; nil credential => nil Firestore => fail closed.
    private static func restoreAuth(app: FirebaseApp) async -> Bool {
        if Auth.auth(app: app).currentUser != nil { return true }
        guard let token = SharedKeychain.customToken() else { return false }
        do {
            try await Auth.auth(app: app).signIn(withCustomToken: token)
            return true
        } catch { return false }
    }
}
```

### `CancelAppointmentIntent.swift` (reference; Complete is identical bar the status)
```swift
import AppIntents

@available(iOS 16.0, *)
struct CancelAppointmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel an appointment"
    static var openAppWhenRun = false
    // NOT .alwaysAllowed — a write requires unlock.

    @Parameter(title: "Which appointment")
    var position: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = ScheduleSnapshot.load() else {
            return .result(dialog: IntentDialog(stringLiteral: SiriStrings.noData))
        }
        let today = snapshot.today?.appointments ?? []
        guard position >= 1, position <= today.count else {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.nthOutOfRange(
                    count: today.count, admin: snapshot.isAdmin)))
        }
        let target = today[position - 1]
        // Voice confirmation reads the change back before committing.
        try await requestConfirmation(
            result: .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.confirmCancel(target))))
        guard let db = await FirebaseExtensionBootstrap.ready() else {
            return .result(dialog: IntentDialog(
                stringLiteral: SiriStrings.openAppToEnableWrites))
        }
        try await db.collection("appointments").document(target.id).updateData([
            "status": "cancelled",              // hard-coded allowlist value
            "updatedAt": FieldValue.serverTimestamp(),
        ])
        return .result(dialog: IntentDialog(
            stringLiteral: SiriStrings.cancelled(target)))
    }
}
```
New `SiriStrings` keys (EN + FR): `confirmCancel`, `cancelled`, `confirmComplete`,
`completed`, `openAppToEnableWrites`, plus reschedule/book strings.

---

## Verification (device — nothing here is Dart-testable)

- Sign-out wipes the snapshot **and** drops the shared keychain custom token →
  a Siri write attempted after sign-out fails closed ("Open ES Pro…").
- Confirm-then-commit happy path (cancel, then complete).
- Offline write → spoken retry, **no partial commit**.
- Ambiguous target → disambiguation.
- Role scoping — an employee cannot mutate another tech's job (rules enforce it;
  confirm the spoken failure is graceful, not an opaque error).
- Siri **unlock gate** before commit (no `.alwaysAllowed` on write intents).
- App Check: a write from the extension is accepted (2nd app + App Attest);
  temporarily breaking the 2nd-app config reproduces the opaque `permission-denied`
  so the gate is provably active.

## App Review / privacy note

Phase 4 makes the extension an authenticated Firebase client — flag it for
security-review as a conscious surface change (design doc, Privacy §). No new App
Privacy data type (all fields already declared). The custom token is a bearer
credential: keychain-only, short TTL, cleared on sign-out.
