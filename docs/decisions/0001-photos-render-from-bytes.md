# 0001. Photos render from bytes; no download URL is ever minted

**Date:** 2026-08-15 (render path), 2026-08-11 (no fallback on rejection), CONTRACT step (upload-side mint) · **Rules file:** `.claude/rules/images.md`

## Context
`getDownloadURL()` mints a `?alt=media&token=…` URL whose `firebaseStorageDownloadTokens` value is
stable per object and never expires, and fetching it serves the bytes over plain HTTPS with no auth
and no rules evaluation. The 2026-08-08 scheme re-minted that URL at render time, which put
`storage.rules` in front of the MINT but handed back the same permanent string: a URL rendered while
an employee was active sat in the on-disk image cache, was copyable, and kept working after
`deactivateEmployee` revoked the credential and the `status == 'active'` gate refused new reads. The
render-from-bytes change (owner call, 2026-08-15) replaced that scheme rather than extending it;
`AppointmentImageLoader` was formerly `AppointmentImageUrlResolver`.

Even after the render path stopped, `ImageStorageService.uploadImage` went on calling
`getDownloadURL()` and persisting the result into `pictures[]`, which every assigned employee's
device received, so the app kept manufacturing a permanent rules-free link per photo. At the CONTRACT
step that write went with the builds that rendered from it. With it went `rotateAssignedImageTokens`
(`functions/appointment_image_tokens.js`, called from `syncUsersByUid`'s deactivation branch) and its
`(employeeIds CONTAINS, endTime DESC)` composite, and `downloadUrlFor` — the offline queue's mint for
re-linking an uploaded image whose doc-link append didn't land — with its re-resolve step and the
failure branch that guarded against a blank-url duplicate. A carried image is now appended as it
stands, which spares a Storage round trip per photo on the offline→online flip.

A rules rejection must not fall back (2026-08-11): the old `catch` was unconditional, so a
`permission-denied`/`unauthorized` from the `status == 'active'` gate was converted straight back into
a working, rules-free token URL. A doc written before `storagePath` was stored had only its `url`,
resolved back into a `Reference` via `refFromURL` so it stayed rules-evaluated; that fallback went
2026-08-22 (ADR-0002).

## Decision
`AppointmentImageLoader` fetches with `ref.getData()` on `storagePath` alone, so `storage.rules` is
evaluated on every fetch. Nothing mints or persists a download URL, on the render path or anywhere
else. Empty bytes are a refusal, never a pending load, and no URL-shaped fallback exists for any error.

## Consequences
Two limits are not fixable in code: a URL captured under an old build stays live on its object unless
rotated by hand, and an entitled person can still screenshot or share a photo they can see. Don't
reintroduce `getDownloadURL()` or a fallback.
