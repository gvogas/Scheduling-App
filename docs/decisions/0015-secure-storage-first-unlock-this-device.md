# 0015. Secure storage uses `first_unlock_this_device`

**Date:** 2026-07-21 (rule recorded, `952eaead`) · **Rules file:** `CLAUDE.md`

## Context
The default `unlocked` Keychain class made every `SecureStorageService` read throw -25308 when a
content-available push cold-started the app on a locked phone — Crashlytics noise AND the biometric app
lock silently not engaging that session. `first_unlock_this_device` fixes that, and the `_this_device`
suffix additionally keeps the cached identity out of device/iCloud backups (the cache self-rebuilds on
the next sign-in after a restore).

## Decision
The service lazily migrates old items before any operation (backup slot, then delete-then-rewrite,
marker `ios_keychain_accessibility_v2`), so `_ensureMigrated` runs first in every public method and
every key is listed in `SecureStorageKeys.all`. `isKeychainLockedError` classifies the residual -25308
(pre-first-unlock) as log-only at the three flag-read catch sites.

## Consequences
A public method that skips `_ensureMigrated`, or a key missing from `SecureStorageKeys.all`, never
migrates and keeps the old accessibility class.
