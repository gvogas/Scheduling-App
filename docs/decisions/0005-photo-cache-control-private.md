# 0005. Uploaded photos use `cacheControl: private`

**Date:** 2026-08-25 · **Rules file:** `.claude/rules/images.md`

## Context
Photo bytes are fetched with an Authorization header (render-from-bytes via `ref.getData()`). RFC 9111
§3.5 lets a SHARED cache store an authenticated response only when it is marked `public`, so `public`
is precisely the token that re-authorizes an intermediary to keep and reuse one entitled user's photo
for the whole `max-age` (it was a year).

## Decision
An uploaded photo's `cacheControl` is `private`, never `public`.

## Consequences
Nothing is lost by `private`: offline and session reuse are owned by `AppointmentImageDiskCache` and
the session map, which key on the write-once `storagePath`. Don't "restore" `public` to fix a
perceived cache miss.
