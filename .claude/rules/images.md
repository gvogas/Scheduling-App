---
paths:
  - "lib/core/images/**"
  - "lib/features/calendar/**"
  - "functions/appointment_image*.js"
  - "functions/maintenance*.js"
  - "test/core/images/**"
---

# Photos and image uploads

Loaded when working on the image pipeline. Root context: `../../CLAUDE.md`.

## Storage and upload

- Let only admins replace bytes, edit metadata or delete objects; an employee upload must never overwrite — `storage.rules`' assignee create branch requires `resource == null`, since a byte upload can be evaluated as create at an existing path, so operation names alone are not enough. The emulator checks under `functions/__tests__/emulator/` exercise every operation.
- Reject an upload whose first bytes aren't JPEG (`FF D8 FF`) or PNG (`89 50 4E`) in `ImageStorageService`; the extension alone is not sufficient.
- Set an uploaded photo's `cacheControl` to `private`, never `public` — `public` re-authorizes a shared cache to reuse an authenticated photo. Don't "restore" it for a perceived cache miss. (ADR-0005)
- Keep the upload pipeline single-stage: `ImagePickerService` resizes and compresses at pick time (`image_picker` `maxWidth/maxHeight: 1600`, `imageQuality: 70`), then `ImageStorageService` validates magic bytes and uploads. Never reintroduce a second pass (`ImageCompressService` is gone). `AppointmentImageUploadService` dispatches in the background after the appointment save, and the picker's temp files are deleted in a `finally`.
- Keep `ImageStorageService.uploadImage` composing every file name from `DateTime.now()`, so a `storagePath` is written exactly once and never overwritten — that is why cache entries never need revalidating.

## Rendering from bytes

- Render photos from bytes: `AppointmentImageLoader` (`core/images/`) fetches with `ref.getData()` on `storagePath` alone, so `storage.rules` is evaluated on every fetch. Never call `getDownloadURL()` or persist a `url` anywhere — a download URL is a permanent, rules-free link that survives `deactivateEmployee`. (ADR-0001)
- Never fall back to a URL on any error, a rules rejection above all. Treat EMPTY BYTES as a refusal, not a pending load: `PhotoPickerSection` renders the error tile untappable, and `buildImageProviders` substitutes a 1×1 transparent image rather than dropping the entry, because the viewer opens at an INDEX. (ADR-0001)
- Let an entry with no `storagePath` resolve to empty bytes: `load` returns early on the empty key without touching either cache. Keep the rejection/transport branch only to say which happened in the log, and cache neither result — entitlement and the network can change mid-session. (ADR-0001, ADR-0002)
- Carry loaded bytes with the list they were loaded for — they are POSITIONAL: `PhotoPickerSection` keys them on `_resolvedFor` and serves `const []` until it matches `existingImages`. Offset a viewer index by the entries actually handed to the viewer, never by `existingImages.length`; `ImageViewer.open` also clamps. (ADR-0010)
- Never render a stored photo through a bare `Image.memory` with no cache bound: the strip decodes through `cacheWidth`/`cacheHeight` and the carousel through `ResizeImage` (~0.3 MB vs ~10 MB); only the full-screen viewer decodes at full size.
- Spool Save/Share bytes to `getTemporaryDirectory()` in `ImageViewer._currentImageFile` (a `MemoryImage` has no file), and exclude the 1×1 refusal stand-in by identity, or Save/Share hands over a blank pixel as the job. (ADR-0003)

## Caches

- Keep two caches with two jobs — don't collapse them: the session map stops a fetch per widget State, `AppointmentImageDiskCache` (`core/images/appointment_image_disk_cache.dart`) stops one per SESSION. Both key on `storagePath` and store nothing shareable. (ADR-0003)
- Never import `cached_network_image` / `flutter_cache_manager` in `lib/` again; the point was the offline property, not the package. (ADR-0003)
- In `load`, read disk BEFORE the network and write back after a successful fetch, deliberately unawaited, so a file write and its eviction sweep never sit in front of a first render.
- Budget the disk cache at `maxCachedBytes` (128 MB, oldest-first by INSERTION, matching the memory cache rather than a write per render) in the platform cache directory, which is excluded from device/iCloud backups; budget the session map (`Map<key, Future<Uint8List>>`, singleton provider) at 24 MB, oldest first, because bytes are far heavier than the URL strings it once held. Keep `loadAll`'s concurrency bound of 4, asserted by `appointment_image_loader_test.dart`. (ADR-0003)
- Keep every disk operation best-effort — a failure degrades to a cache miss and a log, never a photo that fails to render — and memoize the resolved directory with its REJECTION explicitly forgotten, or one launch hiccup disables offline photos for the process.
- Clear BOTH caches from `deregisterThisDevice` (`core/app/device_deregistration.dart`), the single owner of "forget this session", after the credential-dependent steps. `clear()` is `Future<void>` and runs through the isolating `_step` because it touches the file system and can fail; it empties memory first and synchronously, so an awaited disk delete cannot delay it. (ADR-0003)
- Drop a disk write whose session ended mid-flight: `AppointmentImageLoader._resolve` reads the `generation` getter (`_disk.generation`) BEFORE `await _fetch(...)` and passes it to `write(key, bytes, {required int generation})` — reading it inside `write` is a no-op for that case. Keep the parameter required. (ADR-0004)
- Accept the residual: a cache hit is not rules-evaluated, so entitled-time bytes stay renderable on that device until evicted or cleared. (ADR-0003)

## Detail sheet and photo strip

- Seed `EventDetailsController` with NO photos and fill from the subcollection read, adopting the result only while the list is still what `build()` seeded (`_loadStoredPictures`'s `_lastKnownImages` guard) — a removal during the round trip must not be put back.
- Keep `EventDetailsController` subscribed to `repo.onLocalWrite` (not `onRecordWrite`, which excludes photo/note writes) and re-running `_loadStoredPictures()`, so an open sheet learns when an upload lands; the extra subcollection read on a note or status write is accepted. See `.claude/rules/search.md`'s `_patchWindow`/`_notifyLocalWrite` rule.
- Raise `isLoadingPictures` only for UPLOAD-driven re-reads: `_loadStoredPictures` takes `showLoading`, and only the `onLocalWrite` listener passes true. (ADR-0010)
- Make `DetailsPhotosView`'s render gate COUNT `pendingCount` and WATCH it (`ListenableBuilder` over `Listenable.merge([notifier.pending, notifier.failures])`, `details_view_leaf_widgets.dart`), or a crew upload on a photo-less job shows nothing. (ADR-0010)
- Measure the per-job photo cap AFTER the pick (`_roomForPhotos`, `remainingSlots` on `pickAndAddAppointmentImages`), since a background upload can land during the pick, and name the room LEFT in the notice, using `calendar_photosLimitFull` at zero room. (ADR-0010)

## Subcollection contract (`appointments/{id}/images`)

- Store photos only in `appointments/{id}/images`; the parent's `pictures` array is gone and the parent keeps only `pictureCount`. (ADR-0006)
- Make `appendAppointmentPictures`/`removeAppointmentPictures` write the subcollection and touch only the parent's `updatedAt`; never write `pictureCount`, which `recountAppointmentPictures` owns and the rules refuse a client update to. The ONE client write the rules allow is `pictureCount: 0` on create (`addAppointments` and series-edit copies), so "absent" is never a state to interpret — the recount fires only on a photo write, so a job created without it would read count-unknown until its first photo. `toMap()` never emits it.
- Derive the doc id with `appointmentImageDocId` (`calendar/domain/policies/`), hand-mirrored as `appointment_image_ids.js` (`functions/`, dependency-free; from `appointment_image_doc_id.dart`) with shared worked examples — change both together. It keys on `storagePath`, falling back to `url` so legacy docs don't collide. It is what makes the write idempotent, so a concurrent edit or the batch's other half is never clobbered; the shared examples make a divergence fail a test rather than put one photo at two ids. (ADR-0006)
- Never put `url` on a photo document; the rules allowlist is `['storagePath', 'fileName', 'uploadedAt']`. If a url-only row reappears, re-home its bytes under a real `storagePath` — never re-add the field; to check, recover `count-legacy-image-urls.js` from git history (it scans, since `images.url` is index-exempt). (ADR-0002)
- Use `pictureCount` for `AppointmentCard`'s photo indicator only; never gate a READ on it — it is debounced and can stay wrong forever. The sheet reads unconditionally with one bounded `get`. (ADR-0006)
- Delete photo documents and bytes for a deleted appointment only via `cascadeDeleteAppointmentImages` — the client has no array left to enumerate, so a client-side cleanup would delete nothing; removing ONE photo from a live job stays client-side in `EventDetailsSavePipeline.applyPhotoChanges`. (ADR-0006)
- Keep `firestore.rules`' `d.pictures.size() <= 100` clause — ~45 prod docs carry a permanent empty `pictures: []`. Nothing bounds the subcollection; keep `AppointmentImagesStore.scanLimit` (100, warns at the cap) and `PICTURE_COUNT_WARN_CAP` (`functions/appointment_images.js`) equal. The picker's `AppointmentFormConcerns.maxImagesPerAppointment` is 10. (ADR-0006)

## Offline upload queue

- Persist failed or incomplete batches in `PendingUploadStore` (one JSON list under SharedPreferences `pending_photo_uploads`, pruned after 7 days). `AppointmentImageUploadService.drainPending()` is reentrancy-guarded, re-queues only the *unsent* paths preserving `enqueuedAtMs`, and appends through `appendAppointmentPictures`.
- Carry already-uploaded images forward on the entry's `uploaded` field when the doc-link append throws transiently — never re-upload them (their temp files are already gone) and never drop them, or the bytes orphan; append them as they stand. Keep each carried image serializing its exact `uploadedAt` (`AppointmentImage.fromMap`). Only an entry with no paths AND no `uploaded` drains away. (ADR-0001, ADR-0009)
- Stage through `drainPending` only, never upload directly (`_draining` + `_pendingDrain`; coalesce, never drop) — two passes write two `storagePath`s and the photo lands twice. (ADR-0009)
- Keep every `PendingUploadStore` mutation inside `_serialized` (one `_mutations` chain); never move serialization to call sites — the requeue inside a drain is a caller too. (ADR-0009)
- Give every `PendingUpload` an owner (`uid` + employee doc id); `_attempt` and `_publishPending` skip entries not owned by the signed-in person, and `deregisterThisDevice` clears the queue and its staged files. Resolve the owner ONCE per drain (`_drainOwner`, cleared in the `finally`). (ADR-0008)
- Parse a pre-upgrade ownerless entry (`PendingUpload.hasOwner` false): skip it for upload but keep it so `prune` deletes its files. Never reject it in `fromJson` or adopt it for the signed-in user. (ADR-0008)
- Let `_currentOwner` throw a bare `StateError` (signed out / no users doc), not an `ImageUploadFailure`; the drain catches, logs under `IMG-UPLOAD` and re-queues. Don't file it as drift. (ADR-0008)
- Drive the drain from `AppSyncListeners` (`core/app/app_sync_listeners.dart`, registered from `main.dart`) on the offline→online flip AND when the account doc first arrives, since Storage rules need an authed user and a signed-out drain just re-queues; both are covered by `test/core/app/app_sync_listeners_test.dart`. The upload itself is device-only verification.

## Server side

- Keep `cascadeDeleteAppointmentImages` (`appointment_images.js`) covering all three delete paths — single delete, series delete, `purgeExpiredHistory` (Admin SDK deletes fire triggers too) — since Firestore never deletes a subcollection with its parent. Delete bytes FIRST, documents second (`deleteFiles({prefix})`, then `recursiveDelete`), since the docs are the last thing pointing at those objects, and RETHROW on either half so `retry: true` means something. (ADR-0007)
- Let `deleteAppointmentImageBytes` OWN the `appointments/{id}/images/` prefix, composed from `IMAGES_SUBCOLLECTION` and the appointment id rather than stored paths, so it also sweeps bytes whose doc link never landed; `maintenance.js`'s `deleteAppointmentImages` stays a `try`/`catch`→`false` wrapper over it, never a second spelling. (ADR-0007)
- Rename `IMAGES_SUBCOLLECTION`, `AppointmentImagesStore.imagesSubcollection` (`calendar/data/appointment_images_store.dart`) and `firestore.rules`' `match /images/{imageId}` together, or the cascade silently stops.
- Make `recountAppointmentPictures` an absolute `count()` aggregate, never an increment (same as `recountClientJobs`), written with `update()` so a deleted appointment is never resurrected; a `NOT_FOUND` is the normal path. Recount on EVERY write — the replay is the counter's only self-heal. (ADR-0007)
- Debounce through `debouncedRecountPictures`' claim in the Admin-SDK-only `appointmentRecountClaims/{appointmentId}` ledger (rules `if false`), and RELEASE the claim BEFORE the aggregate runs — counting first lets a photo be both suppressed and uncounted. Keep it unconditional (unlike `recountClientJobs`' `mayShareABatch` gate); a photo write is always batched. (ADR-0007)
- Keep the claim protocol in `functions/recount_claim.js` only (`CLAIM_STALE_MS` 15 s, `CLAIM_TTL_MS`); this module keeps `RECOUNT_CLAIM_COLLECTION`, `RECOUNT_SETTLE_MS` (2 s) and the `{skipped, count}` shape. Delete the claim on the normal path so a later write always claims afresh; FAIL OPEN on any ledger error, since an extra parent write is harmless and a skipped recount is a permanently wrong count. The `expiresAt` TTL (`firestore.indexes.json`, offset 0) is housekeeping only. (ADR-0007)
- Keep `purgeAppointmentImages` and `recountPictures` taking an injected `db`, jest-tested.
