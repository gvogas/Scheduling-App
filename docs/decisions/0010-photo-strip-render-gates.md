# 0010. Photo strip and detail-sheet render gates

**Date:** 2026-09-06 (pending gate, caught in review before it shipped), 2026-09-07 (`isLoadingPictures` scope) · **Rules file:** `.claude/rules/images.md`

## Context
Loaded bytes are positional, and a Storage round trip per photo is a real window, not "a frame or
two": a partial or stale list shifted every index beside it, so removing photo 0 rendered the deleted
photo, an untapped placeholder opened a new photo, and the viewer's `initialIndex` (composed as
`existingBytes.length + i`) ran past the provider list and threw a `RangeError` out of Save/Share.

`DetailsPhotosView` rendered `SizedBox.shrink()` with nothing listening for a job with zero
existing/new/failed photos, so a background upload from the read-only field-record path
(`DetailsFieldRecordView._addPhotos` → `uploadInBackground` → `reportPending`) gave the crew no sign
their first photo existed for the whole upload; a plain non-reactive read of `pendingCount` has the
same hole. The old rule described the gate as a `ValueListenableBuilder` on `notifier.pending`;
the code is a `ListenableBuilder` over `notifier.pending` and `notifier.failures` merged.

Raising `isLoadingPictures` on the read every sheet open fires made a job with NO photos render the
PHOTOS header over an empty strip and collapse it a round trip later, on every open.

The per-job cap was measured before the pick, the longest await in the app, so a background upload
landing inside it went uncounted and the job overshot; a notice naming the total cap fires only near
the limit, which is exactly when "only 10 more photos can be added" is false.

## Decision
Bytes are keyed to the list they were loaded for; the pending gate counts and watches `pendingCount`;
`isLoadingPictures` is raised only for upload-driven re-reads; the cap is measured after the pick and
the notice names the room left.

## Consequences
Don't offset a viewer index by `existingImages.length`, read `pendingCount` non-reactively, or pass
`showLoading: true` from the build-time read.
