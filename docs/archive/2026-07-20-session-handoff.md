# Session handoff — Siri Phases 2–4 + Live Activity verification

**Date:** 2026-07-20 · **Branch:** `notification` · **Machine:** Mac (Xcode 26.6,
Flutter 3.44.2). Everything below is committed; working tree clean.

Resume-here doc. Read this first, then the linked plans for detail.

## Commits this session
- `e0658a0` — Siri Phases 2–3 + Live Activity APNs sandbox fallback
- `dc5e86e` — appointments `(employeeIds, endTime)` index for the travel origin-context query
- `3a5f176` — Siri Phase 4: blockers resolved on paper + execution runbook
- (`e4fc211` "update version ios" is yours, interleaved.)

---

## Where each workstream stands

| Workstream | State | Next action |
|---|---|---|
| **Siri Phases 1–3** | Built, compile-verified, **installed on the plugged-in iPhone**. | On-device phrase pass (you speak them). |
| **Siri Phase 4 (writes)** | **Design complete, no code landed.** Blockers resolved on paper. | Execute the Mac runbook — see below. |
| **Live Activity card** | **Deployed + card-start VERIFIED on device.** | Finish the device checklist. |
| **Firestore indexes** | All deployed; `(employeeIds, endTime)` was building at pause. | Confirm the `travel: context query failed` log stopped. |

## Verified on device this session
- Live Activity **Lock Screen card starts** end-to-end (server → APNs → ActivityKit), with correct client/address/drive text.
- The **amber→red lapse** state (the card went red because the test job's leave-at was already past — correct behavior; owner chose to keep the red styling as-is).

## NOT yet verified (device pass, yours to drive)
- **Siri:** all 6 intents spoken, EN + FR; employee-vs-admin scoping; empty-day; lock-screen answers. Checklist in [`ios/SiriIntents/README.md`](../../ios/SiriIntents/README.md).
- **Live Activity:** travel→on-site **green flip** + elapsed timer; **Directions** button opens Maps from lock screen; **Complete** deep-links; card **ends** on done/cancel; **degradation** (iOS<17.2 / Live-Activities-off → plain push). Checklist in [`ios/ScheduleWidget/LIVE_ACTIVITY_README.md`](../../ios/ScheduleWidget/LIVE_ACTIVITY_README.md).
- **Live Activity — Dynamic Island:** cannot be tested on the current device (base **iPhone 14** has no Dynamic Island — Pro-only). Use **George's iPhone (16 Pro, `iPhone17,1`)** to verify the Island presentation.

---

## Resume point: Siri Phase 4 (the real remaining work)

Full runbook: [`2026-07-20-siri-phase4-write-actions.md`](./2026-07-20-siri-phase4-write-actions.md).
Architecture chosen: **direct writes from the extension** (hands-free).

**Do these in order on the Mac (this is a console/portal-heavy session):**
1. **30-min App Check test FIRST** — does Runner's Firebase app accept the
   extension's App Attest? If yes (unlikely), the custom-token subsystem is
   deleted and Phase 4 shrinks a lot. If no (expected), proceed with the 2nd
   Firebase app + custom-token path.
2. Portal: Keychain Sharing on both App IDs; App Attest capability on the
   extension App ID.
3. Firebase Console: register 2nd iOS app `net.vogas.scheduling.SiriIntents`;
   enable App Attest for it.
4. **If step 1 failed:** build `mintSiriExtensionToken` callable + the
   keychain-token lifecycle (app mints, extension signs in with custom token,
   fails closed when absent/expired).
5. Entitlements → SPM (Firebase into the extension target) → the four write
   intents (Cancel/Complete first, then Reschedule, then Book).
6. Phase-4 device verification checklist.

**The one thing to decide before touching code:** the outcome of step 1 decides
whether Phase 4 is "small" (same-app) or "large" (custom-token subsystem). The
whole increment is un-verifiable until the console/portal pieces exist, so land
code only as each prerequisite lands (keeps the build green).

---

## Environment gotchas (bit us this session)
- **Deploying functions from THIS Mac fails at predeploy.** node 26 / npm 11.17
  crashes the `npm run lint` hook (`Cannot read properties of undefined (reading
  'stdin')`) *after* eslint passes. Workaround used transiently: swap the
  `firebase.json` predeploy to `cd "$RESOURCE_DIR" && ./node_modules/.bin/eslint .`
  for the deploy, then revert. Permanent fix: install a node LTS (18/20/22).
- **Live Activity on a dev build needs the sandbox APNs fallback** (already
  shipped in `apns_client.js`): `flutter run` is dev-signed → sandbox
  push-to-start token → the production-only client got `BadDeviceToken` → no
  card. The client now retries sandbox on `BadDeviceToken`. TestFlight/App Store
  builds hit production first and never retry.
- **Always deploy `firestore:indexes` with functions** — the card path silently
  degraded to "push, no card" because the composite indexes were never deployed.
- Devices: plugged-in = **iPhone 14** (`iPhone14,7`, no Dynamic Island);
  wireless = **George's iPhone 16 Pro** (`iPhone17,1`, has Dynamic Island).

## Deploy state (prod, project `schedulingapp-88727`)
- `sendUpcomingJobReminders` + `notifyAppointmentChanges` redeployed with the
  APNs sandbox fallback; **diagnostic logging was added then reverted** — prod is
  clean.
- `firestore:indexes` deployed (incl. the new `(employeeIds, endTime)`).
- No other functions changed.
