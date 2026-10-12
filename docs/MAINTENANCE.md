# Maintenance mode

The app is feature-complete. This page is the whole job of keeping it alive:
what expires, what alerts you, and what to do when something breaks. Detail
lives in [DEPLOYMENT.md](DEPLOYMENT.md); this is the index.

Project `schedulingapp-88727`, region `us-central1`, Firestore `nam5`.

## Renewals (put each in a calendar)

| Item | Cadence | If it lapses |
|---|---|---|
| Apple Developer Program | yearly, turn on auto-renew | App removed from the App Store |
| Distribution certificate + provisioning profile | yearly | Can't upload a new build (installed app keeps working) |
| APNs key (`APNS_AUTH_KEY`, a `.p8`) | never expires; revoke only if leaked | Push + Live Activities stop |
| Cloud Functions runtime (Node 24) | ~April 2028 | Deploys blocked, then runtime retired; bump `engines.node` in `functions/package.json` and redeploy |
| Xcode / iOS SDK minimum | every spring (Apple raises it) | Only matters when uploading a new build |
| Wave full-access token (`WAVE_FULL_ACCESS_TOKEN`) | when Wave revokes it | Sync dead-letters; app keeps working |
| Domain + email behind the Apple ID / Firebase | yearly, auto-renew | Account recovery and Auth emails break |

## What watches it for you

| Signal | Where | Set up |
|---|---|---|
| Spend over CAD $1/month | GCP Billing budgets (project + Maps) | yes |
| Crashes / new issues | Crashlytics email alerts | check the inbox |
| Cloud Functions errors (max 1 email/hour; excludes the benign `Invalid request, unable to process.` scanner noise) | Cloud Monitoring alert policy "Cloud Functions errors" | yes, 2026-10-12 |
| Daily Firestore backup, 7-day retention | Firestore → Disaster recovery | yes, 2026-10-12 |

## If X breaks, do Y

| Symptom | First move | Detail |
|---|---|---|
| A feature misbehaves in prod | Flip its kill switch, in BOTH Remote Config templates | [DEPLOYMENT.md "Flip a kill switch"](DEPLOYMENT.md#flip-a-kill-switch) |
| A bad app build is on phones | Raise `min_supported_build` (Client template) to force an update | same section |
| Functions regressed after a deploy | Redeploy the previous source | [DEPLOYMENT.md §7](DEPLOYMENT.md#7-rollback) |
| Data deleted or corrupted | Restore the latest backup into a NEW database, copy the docs back | `gcloud firestore databases restore` |
| Invite / password setup fails | Check the Auth console password policy first | — |
| Wave invoices stop syncing | Settings → Wave → Retry; check `functions:log` for `WAVE-` | `functions/scripts/drain-wave-queue.js` |
| Bill jumps | Look at Billing → Reports by SKU; Maps is the usual suspect | — |
| A scheduled job seems dead | Cloud Scheduler page shows job STATE (paused jobs look fine elsewhere) | [DEPLOYMENT.md](DEPLOYMENT.md#purgeexpiredhistory-was-paused-and-nobody-knew-found-2026-08-23) |

## Rules for maintenance mode

- No new features, secrets or Scheduler jobs; each adds cost or upkeep.
- Deploy only from `main` via the `Deploy backend` workflow.
- About 1–2 hours a quarter: skim Crashlytics, the bill and the Functions error rate.
