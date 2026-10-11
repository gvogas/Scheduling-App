# 0003. Offline photos via a disk cache keyed on `storagePath`

**Date:** 2026-08-16 · **Rules file:** `.claude/rules/images.md`

## Context
The render-from-bytes change (ADR-0001) was written up as costing the on-disk cache outright —
"photos re-download once per session and do not render offline at all" — and that cost was paid for a
day on the one use case the app exists for: a tech in a basement or underground garage opening a job
they looked at that morning. `cached_network_image` cached bytes too; what made it unacceptable was
the HANDLE it cached them against, a permanent rules-free token URL. `ImageViewer._currentImageFile`
used to hand `DefaultCacheManager` a URL.

The session map replaced a URL cache built to avoid paying a fetch per widget State (every sheet open
and every View→Edit toggle). The provider is a plain `Provider`, so its bytes otherwise live for the
whole process and one user's job photos stayed in the heap across sign-out into the next user's
session on a shared device — and the DISK half outlives the process, which turns a memory-forensics
footnote into a real leak on a shared handset. It is not a rules bypass (serving them still needs the
next reader to be entitled to the same `storagePath`), which is why the clear sits after the
credential-dependent teardown steps rather than before them. The old rule called the isolating
teardown helper `step`; it is `_step` in `core/app/device_deregistration.dart`.

## Decision
`AppointmentImageDiskCache` keys on `storagePath` and stores nothing shareable; the session map and
the disk cache stay two caches with two jobs; `deregisterThisDevice` clears both.

## Consequences
A cache hit of either kind is not rules-evaluated, so bytes fetched while entitled stay renderable on
that device until evicted or the session is forgotten — the accepted residual, bounded by the platform
cache directory (iOS excludes it from backups, the same posture as `first_unlock_this_device`),
`maxCachedBytes` and `clear()`. Don't bring back `cached_network_image` / `flutter_cache_manager`;
the point was the property, not the package.
