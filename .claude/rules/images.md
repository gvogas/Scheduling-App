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

- **Employee photo uploads must not overwrite existing objects.** Storage's
  create rule requires `resource == null` on the assignee branch; operation
  names alone are insufficient because a byte upload can be evaluated as
  create even at an existing path. Only admins may replace bytes, edit
  metadata or delete objects. The emulator checks under
  `functions/__tests__/emulator/` exercise all of these operations.

- **Image validation:** Reject uploads where first 4 bytes aren't JPEG
  (`FF D8 FF`) or PNG (`89 50 4E`). Extension alone is not sufficient.
- **An uploaded photo's `cacheControl` is `private`, never `public`** (2026-08-25).
  The bytes are fetched with an Authorization header (render-from-bytes via
  `ref.getData()`), and RFC 9111 §3.5 lets a SHARED cache store an
  authenticated response only when it is marked `public` — so `public` is
  precisely the token that re-authorizes an intermediary to keep and reuse one
  entitled user's photo for the whole `max-age` (it was a year). Nothing is
  lost by `private`: offline and session reuse are owned by
  `AppointmentImageDiskCache` and the session map, which key on the write-once
  `storagePath`. Don't "restore" `public` to fix a perceived cache miss.
- **Image upload pipeline:** Single stage — `ImagePickerService` resizes +
  JPEG-compresses at pick time (`image_picker` `maxWidth/maxHeight: 1600`,
  `imageQuality: 70`); `ImageStorageService` then validates magic bytes and
  uploads. `ImageCompressService` was removed — don't reintroduce a second
  compression pass. Background dispatch via `AppointmentImageUploadService`
  after appointment save; the picker's temp files are deleted in a `finally`.
- **Photos are RENDERED FROM BYTES held in memory. No renderable URL is ever
  produced** (owner call, 2026-08-15, which replaced the 2026-08-08
  render-from-`storagePath` scheme rather than extending it).
  `getDownloadURL()` mints a `?alt=media&token=…` URL whose
  `firebaseStorageDownloadTokens` value is **stable per object and never
  expires**, and fetching it serves the bytes over plain HTTPS with **no auth
  and no rules evaluation**. The previous scheme re-minted that URL at render
  time, which put `storage.rules` in front of the MINT — but handed back the
  same permanent string every time, so a URL rendered while an employee was
  active sat in the on-disk image cache, was trivially copyable, and kept
  working indefinitely for anyone holding it after `deactivateEmployee` had
  revoked the credential and the `status == 'active'` gate had started refusing
  *new* reads. **`AppointmentImageLoader` (`core/images/`, formerly
  `AppointmentImageUrlResolver`) calls `ref.getData()` instead** — an
  authenticated SDK fetch, so `storage.rules` is evaluated on **every fetch**,
  and nothing shareable is produced ON THE RENDER PATH or left in a cache.
  **Nothing mints one ANYWHERE either, as of the CONTRACT step** — that was the
  last half of this guarantee to land, and it was missing for a while:
  `ImageStorageService.uploadImage` went on calling `getDownloadURL()` and
  persisting the result into `pictures[]`, which every assigned employee's
  device received, so the app kept MANUFACTURING a permanent rules-free link
  per photo long after it stopped doing so as a side effect of rendering. That
  write existed for builds that rendered from it, and it went with them; the
  `rotateAssignedImageTokens` control that covered the gap
  (`functions/appointment_image_tokens.js`, called from `syncUsersByUid`'s
  deactivation branch) was deleted at the same time, along with the
  `(employeeIds CONTAINS, endTime DESC)` composite it needed.
  **That deletion's premise — "there is no stored link left to invalidate" —
  was TRUE OF NEW PHOTOS ONLY for a while, and is now true outright.** A LEGACY
  `appointments/*/images` row that never had a `storagePath` used to keep its
  `url`, and three things kept that alive: the backfill preserved it
  deliberately, `firestore.rules` accepted the field up to 1000 chars, and
  `AppointmentImageLoader` had a `refFromURL` fallback documented as permanent.
  Each such string was a rules-free, non-expiring, transferable link surviving
  deactivation with nothing left to rotate it. **The deciding fact was a count of the SUBCOLLECTION,
  and it came back ZERO** (2026-08-22,
  `functions/scripts/count-legacy-image-urls.js`: 14 image documents scanned,
  0 with a url and no storagePath), so all three went with it — the rules
  allowlist is `['storagePath', 'fileName', 'uploadedAt']`, the loader keys and
  fetches on `storagePath` alone, `AppointmentImagesStore` never writes the
  field, and the backfill SKIPS a url-only array entry instead of copying a
  document that could never render. **If a url-only row ever reappears, re-home
  its bytes under a real `storagePath` — do not re-add the field to make a
  write pass.** Run that count script again to check; it is read-only.
  **Note the count script scans rather than queries on purpose:** `images.url`
  is index-EXEMPT in `firestore.indexes.json`, so a `where("url", ...)` fails
  outright.
  Two further limits remain and neither is fixable in code: this does **not**
  revoke a URL somebody captured under an old build (those tokens are still
  live on their objects unless rotated by hand), and it does **not** stop an
  entitled person screenshotting or sharing a photo they can legitimately
  see.
  **Photos render OFFLINE again as of 2026-08-16, and this was never in
  tension with the rule above.** The render-from-bytes change was written up as
  costing the on-disk cache outright — "photos re-download once per session and
  do not render offline at all" — and that cost was paid for a day on the one
  use case the app exists for: a tech in a basement or an underground garage
  opening a job they looked at that morning. But `cached_network_image` cached
  BYTES too; what made it unacceptable was the HANDLE it cached them against, a
  permanent rules-free token URL. **`AppointmentImageDiskCache`
  (`core/images/appointment_image_disk_cache.dart`) keys on `storagePath` and
  stores nothing shareable**, so the offline win is back without the leak.
  `cached_network_image` / `flutter_cache_manager` are still not imported
  anywhere in `lib/` and must not come back — the point was never to restore
  that package, only the property it happened to provide.
  **Two caches, two distinct jobs — don't collapse them.** The session map
  (below) keeps the fetch from being paid per widget State; the disk cache keeps
  it from being paid per SESSION. `load` reads disk BEFORE the network and
  writes back after a successful fetch; the write is deliberately **not**
  awaited, so a file write and its eviction sweep never sit in front of a first
  render.
  **Be precise about the residual, which is real:** a cache HIT of either kind
  is not rules-evaluated, so bytes fetched while entitled stay renderable on
  that device until they are evicted or the session is forgotten. That is the
  accepted cost and it is bounded by three things — the entries live in the
  platform CACHE directory (iOS excludes it from device and iCloud backups, the
  same posture as the Keychain `first_unlock_this_device` rule), the folder is
  budgeted at `maxCachedBytes` (128 MB, oldest-first by INSERTION, matching the
  memory cache rather than paying a write per render to track use), and
  `clear()` wipes disk as well as memory.
  **Entries never need revalidating, and that is what makes the whole thing
  safe:** `ImageStorageService.uploadImage` composes every file name from
  `DateTime.now()`, so a `storagePath` is written exactly once and never
  overwritten. Every disk
  operation is best-effort — a failure degrades to a cache miss and a log,
  never to a photo that fails to render — and the resolved directory is
  memoized with its REJECTION explicitly forgotten, or one hiccup at launch
  would silently disable offline photos for the whole process.
  **The session cache holds the BYTES** (`Map<key, Future<Uint8List>>` keyed on
  `storagePath` alone; there was a second `'url:<url>'` key space for legacy
  entries with no storage path, and it went with the fallback on 2026-08-22 —
  such an entry now has no handle to key or fetch, and `load` returns early on
  the empty key without touching either cache; the provider is a
  singleton) — that is what keeps the fetch from being paid
  per widget State, i.e. on every sheet open AND again on every View→Edit
  toggle, which is the whole win the URL cache was built for. It is
  **byte-budgeted** (24 MB, oldest evicted first) because bytes are far heavier
  than the strings they replaced; a session that opens fifty jobs would
  otherwise retain every photo of every one of them. `loadAll` keeps its
  concurrency bound of 4, and `appointment_image_loader_test.dart` now asserts
  that bound rather than only the ordering that survives it. **BOTH caches are
  cleared by `deregisterThisDevice`** (`core/app/device_deregistration.dart`),
  the single owner of "forget this session" — the provider is a plain
  `Provider`, so its bytes otherwise live for the whole process and one user's
  job photos stay in the heap across sign-out into the next user's session on
  a shared device, **and the DISK half outlives the process entirely**, which
  is what turns this from a memory-forensics footnote into a real leak on a
  shared handset. Not a rules bypass (serving them still needs the next
  reader to be entitled to the same `storagePath`), which is why it sits after
  the credential-dependent steps rather than before them. `clear()` is
  therefore `Future<void>` and goes through that function's isolating `step`
  like every other teardown — it touches the file system now, so it can fail.
  The memory half is emptied first and synchronously, so an awaited disk delete
  cannot delay it. A disk write whose session ended mid-flight is **dropped**
  via a generation counter that `clear()` bumps: the loader's write-back is
  unawaited, so a fetch resolving just after sign-out would otherwise re-seed
  the cache that was just emptied — on disk, where it outlives the process, for
  whoever signs in next on a shared handset.
  **The generation must be read where the FETCH starts, not inside `write`**
  (S2, 2026-08-19). `AppointmentImageDiskCache` exposes a `generation` getter
  and `write(key, bytes, {required int generation})` takes it back — **required,
  so a call site cannot silently opt out**; it defaulted to the cache's own
  current generation, which always passes the check, making the parameter that
  protects the invariant opt-in;
  `AppointmentImageLoader._resolve` reads `_disk.generation` BEFORE
  `await _fetch(...)` and passes that value to `write`, which drops the write
  when `clear()` has run since. Capturing it inside `write` was a **no-op for
  exactly the case the guard exists for**: the loader only calls `write` after
  the Storage fetch resolves, so the value captured there already equalled the
  current one and the bytes landed on disk regardless. The required parameter is what makes that unrepresentable
  at a new call site.
  Pinned by `test/core/images/appointment_image_disk_cache_test.dart` ("a write
  already in flight when the session ends is dropped" / "a write started after
  the session ended is kept").
  A doc written before `storagePath` was stored had only its `url`, and that
  URL was unavoidably the handle — resolved back into a `Reference` via
  `refFromURL` so even the legacy path stayed rules-evaluated. **That fallback
  is GONE (2026-08-22, zero such rows in prod)**; an entry reaching the loader
  without a `storagePath` now has no handle and resolves to empty bytes.
  **A RULES REJECTION MUST NOT FALL BACK** (2026-08-11, still the point): the
  old `catch` was unconditional, so the one error it existed to convert into a
  blank tile — a `permission-denied`/`unauthorized` from the `status ==
  'active'` gate — was converted straight back into a working, rules-free token
  URL. There is now no URL-shaped fallback at all, for a rejection or for
  anything else, so **EMPTY BYTES ARE A REFUSAL, not a pending load**:
  `PhotoPickerSection` renders the error tile and keeps it untappable, and
  `buildImageProviders` substitutes a 1×1 transparent image rather than dropping
  the entry — the viewer opens at an INDEX, so dropping one would shift every
  photo beside it. The rejection/transport branch survives in the loader only to
  say which happened in the log; **neither result is cached** — entitlement can
  change mid-session, and the network can come back.
  `ImageStorageService` **writes no `url` at all** since the CONTRACT step, and
  `downloadUrlFor` — the one remaining mint, used by the offline queue when
  re-linking an already-uploaded image whose doc-link append didn't land — is
  deleted with it. A photo document carries no url for that re-link to
  reproduce, so the re-resolve step went too, along with the failure branch
  that guarded against appending a blank-url duplicate: a carried image is
  appended as it stands, which also spares a Storage round trip per photo on
  exactly the offline→online flip where the connection is worst. A stored url
  is now only ever READ, on documents written before `storagePath` existed.
  **Loaded bytes are POSITIONAL, so they must be carried with the list they
  were loaded for** — `PhotoPickerSection` keys them on `_resolvedFor` and
  serves `const []` until that matches `existingImages`. A Storage round-trip
  per photo is a real window, not "a frame or two": a partial or stale list
  shifts every index beside it, so removing photo 0 rendered the *deleted*
  photo, an untapped placeholder opened a NEW photo, and the viewer's
  `initialIndex` (composed as `existingBytes.length + i`) ran past the end of
  the provider list and threw a `RangeError` out of Save/Share. Offset a
  viewer index by the entries actually handed to the viewer, never by
  `existingImages.length`; `ImageViewer.open` also clamps, as depth.
  **Decode size is now the app's problem, not the network layer's.** The strip
  decodes through `Image.memory`'s `cacheWidth`/`cacheHeight` and the carousel
  through `ResizeImage`, so a thumbnail costs ~0.3 MB decoded rather than the
  ~10 MB a full 1600×1600 frame would; only the full-screen viewer decodes at
  full size, exactly as it did before. Never render a stored photo through a
  bare `Image.memory` with no cache bound.
  **Save/Share spool to a temp file.** `ImageViewer._currentImageFile` used to
  hand `DefaultCacheManager` a URL; a `MemoryImage` has no file, so its bytes
  are written to `getTemporaryDirectory()` for the platform channel — and the
  1×1 refusal stand-in is excluded by identity, or Save/Share would hand over a
  blank pixel as if it were the job.
  **The `isLoadingPictures` half of that gate is scoped to UPLOAD-driven
  re-reads, never the build-time one** (2026-09-07). `_loadStoredPictures`
  takes `showLoading`, and only the `onLocalWrite` listener passes true: the
  flag exists to hold the section on screen across the gap between the pending
  count dropping to 0 and the refreshed list arriving, and raising it on the
  read every sheet open fires made a job with NO photos render the PHOTOS
  header over an empty strip and collapse it a round trip later, on every open.
  **The per-job photo cap is measured AFTER the pick, never before**
  (`_roomForPhotos`, and `remainingSlots` on `pickAndAddAppointmentImages`).
  The pick is the longest await in the app, so a background upload landing
  inside it goes uncounted and the job overshoots. **And the notice names the
  room LEFT, not the total cap** — it only fires when the pick was trimmed,
  i.e. when the job is at or near its limit, which is exactly when "only 10
  more photos can be added" is false; at zero room it is
  `calendar_photosLimitFull` instead, since "only 0 more" is not a sentence.
  **`DetailsPhotosView`'s render gate must COUNT `pendingCount` and WATCH it**
  (2026-09-06, caught in review before it shipped). The gate sits inside a
  `ValueListenableBuilder` on `notifier.pending`, not a plain read: a job with
  zero existing/new/failed photos renders `SizedBox.shrink()` with nothing
  listening, so a background upload started from the read-only field-record
  path (`DetailsFieldRecordView._addPhotos` → `uploadInBackground` →
  `reportPending`) left the crew with no sign their first photo on a job
  existed for the whole upload — a plain non-reactive read of `pendingCount`
  has the same hole, since nothing would rebuild the shrunk section when the
  count changed.
  **`EventDetailsController` subscribes to `repo.onLocalWrite` and re-runs
  `_loadStoredPictures()`** so an open sheet learns when a background upload
  lands, instead of only ever reading the subcollection once at `build()`.
  `onLocalWrite` is the ONE broadcast stream on the singleton repository, poked
  by nine write paths (see the root `CLAUDE.md`'s `_patchWindow`/
  `_notifyLocalWrite` rule), so this subscription also means posting a crew
  note or flipping a status costs an `appointments/{id}/images` subcollection
  read while a detail sheet is open — bounded and accepted, but previously
  unstated. `_loadStoredPictures`'s existing `_lastKnownImages` guard already
  refuses to adopt a server list over photos the user has edited in the sheet,
  so this poke needed no change on that side.
- **Photos live in `appointments/{id}/images`. The `pictures` array is GONE
  (the CONTRACT step).** Every appointment document used to carry its whole
  photo array — a `url` alone was ~215 of a ~290-byte entry — while the
  calendar reads up to 1000 appointments at a time and only the detail sheet
  ever shows a photo. Phase 1 (2026-08-13) wrote both stores; the array was
  retired once no device ran a build that read it, the same gate the
  `#compat-1.37.1` shim waited on. What is left on the parent is
  `pictureCount`.
  **`appendAppointmentPictures`/`removeAppointmentPictures` write the
  subcollection and touch the parent's `updatedAt` only.** They must never
  write `pictureCount` — `recountAppointmentPictures` owns it and the rules
  reject a client update that moves it.
  **The subcollection document id is DERIVED from the photo —
  `appointmentImageDocId` (`calendar/domain/policies/`), hand-mirrored as
  `functions/appointment_image_ids.js`.** That is what makes the write
  idempotent, and it REPLACED the `arrayUnion` dedupe the array form depended
  on (which worked only because every image serialized its exact `uploadedAt`
  and `arrayUnion` compares maps by deep equality — one field serialized a hair
  differently and it silently stopped deduping). It keys on `storagePath`,
  falling back to `url` for the legacy documents that have no storage path, so
  those don't all collide on one id. The two implementations share worked
  examples in their tests; change them together.
  **The subcollection doc never carries `url` at all** — photos render from
  bytes fetched off `storagePath`, so `storage.rules` is evaluated on every
  fetch and a persisted download URL is a permanent rules-free token with no
  reader. A LEGACY entry with only a `url` used to keep it as the sole handle
  on its bytes; that carve-out and the loader fallback behind it were removed
  2026-08-22 once a prod count found zero such rows, and the rules now reject
  the field.
  **`pictureCount` backs the card's photo INDICATOR and nothing else. It must
  never gate a READ, and it briefly did.** The counter is function-owned and
  DEBOUNCED — `debouncedRecountPictures` settles for 2 s before it even runs
  the aggregate, and a parent `update()` that exhausts its retry budget leaves
  it wrong forever with only a server-side log. Gating the detail sheet's
  subcollection read on it therefore made a just-added photo invisible on
  reopen and a failed recount invisible permanently, which is the exact failure
  this migration was shaped to avoid; the sheet now reads unconditionally and
  pays one bounded `get`. Being a couple of seconds behind costs an indicator
  nothing, which is why the counter is still worth having.
  Three things keep it as close to right as it gets: `addAppointments` writes
  an explicit `0` at create (the one client write the rules allow — `allow
  create` accepts the key only as 0), `recountAppointmentPictures` owns it from
  the first photo onwards as an absolute `count()` aggregate, and
  `functions/scripts/clear-appointment-picture-arrays.js` re-stamps it from the
  subcollection on **every** document it scans — including the ones carrying no
  array, which it used to `continue` straight past (`needsRecount`, pinned).
  `toMap()` must never emit it, and the rules reject an update that touches
  it.
  **`EventDetailsController` seeds the sheet with NO photos and fills it from
  the subcollection read**, adopting the result only while the list is still
  what `build()` seeded — a removal made during the round trip must not be
  silently put back.
  **`cascadeDeleteAppointmentImages` deletes the Storage BYTES as well as the
  photo documents, and it is now the ONLY thing that deletes either.** The
  client used to enumerate `appointment.pictures` on delete to know which
  objects to remove; with no array to enumerate, a client-side cleanup would
  delete nothing while looking like cleanup. Removing ONE photo from a job that
  still exists stays client-side (`EventDetailsSavePipeline.applyPhotoChanges`)
  — that caller knows exactly which photo it removed.
  **Nothing bounds how many photos a job can hold, and that is the one thing
  the array was doing that was NOT replaced by an equivalent.** The rules
  capped the array at 100 to keep the parent document under its 1 MB ceiling,
  and moving the photos out is precisely what makes that unreachable, so it was
  not reinstated as a ceiling — rules cannot count documents in a subcollection
  anyway. **The array clause itself is NOT gone**: `firestore.rules` still
  enforces `d.pictures.size() <= 100`, and it is still reachable — about 45
  prod appointments carry an EMPTY `pictures: []` that rides along in
  `request.resource.data` on every ordinary edit. That residue is permanent:
  the clear script early-returns on `pictures.length === 0` before its delete,
  so no run will ever remove it (verified 2026-09-06 — no prod doc holds a
  NON-empty array, so the migration is complete and the clause now guards only
  empty lists). Read "not reinstated" as "no equivalent on the SUBCOLLECTION", never as
  "the clause was deleted". What replaces it is visibility at the same number:
  `AppointmentImagesStore.scanLimit` (100) bounds the read and warns at the
  cap, and `PICTURE_COUNT_WARN_CAP` (`functions/appointment_images.js`) makes
  the recount warn past it. The picker's own
  `AppointmentFormConcerns.maxImagesPerAppointment` (10) means only a modified
  client gets near either. Keep the two hundreds equal.
  Scripts: `functions/scripts/backfill-appointment-images.js` copies an array
  into the subcollection (copy-only, `--dry-run`, atomic per appointment) and
  `clear-appointment-picture-arrays.js` deletes the array afterwards (its work
  is DONE as of 2026-09-06 — a prod run now clears nothing). They are
  deliberately separate: a script that copied and deleted in one pass could not
  be dry-run meaningfully, since the dry run would report a coverage it was
  about to create. The clear script REFUSES any appointment whose subcollection
  does not already cover every array entry, and refuses one holding an entry
  with no identity at all (no `storagePath`, no url) — unrenderable and
  uncopyable, so clearing it would destroy the only record it existed.
- **`_currentOwner` throws a bare `StateError`, and that is deliberate**
  (owner call, 2026-09-05). `ImageUploadFailure` is the typed family for
  everything a USER sees; these two ("signed out", "no users doc for uid") are
  internal preconditions on a background drain with no surface to fail on —
  the drain catches them, logs under `IMG-UPLOAD` and re-queues. Wrapping them
  in a `Failure` would put two members in the sealed family that no
  `toLocalizedMessage` branch can ever be reached for. Don't file it as drift.
- **A queue entry is OWNED, and drains only for its owner** (2026-09-04). Every
  `PendingUpload` carries the Firebase `uid` and the employee doc id that staged
  it, `_attempt` skips an entry whose owner is not the person currently signed
  in, and `deregisterThisDevice` clears the queue AND its staged files with the
  rest of the caches. A queue keyed on nothing survived sign-out with the staged
  JPEGs still on disk, and the NEXT account to sign in on that phone drained it
  — someone else's photos, published under their name, onto a job they may not
  even be on. Shared and handed-over devices are the normal case here, not the
  edge one. **The owner is resolved ONCE per drain and memoised** (`_drainOwner`,
  cleared in the `finally`): `_employeeIdForUid` is a Firestore read and both
  `_attempt` and `_publishPending` ask, so a queue of N entries otherwise spent
  2N+1 reads answering a question that cannot change mid-pass.
  **A PRE-UPGRADE entry — one written before the queue carried an owner — is
  PARSED, not dropped.** `PendingUpload.hasOwner` is false for it, so
  `_attempt` and `_publishPending` both skip it and it can never upload under
  the wrong account; but it stays in the queue, which is the only thing that
  lets `prune` reach it and delete its staged files. Rejecting it in
  `fromJson` looked like the safe reading and was the opposite: it stranded
  those JPEGs on disk with nothing left pointing at them. Adopting it for
  whoever is signed in is the other wrong answer, and is exactly the incident
  the owner field exists to prevent.
- **Offline photo-upload queue:** a failed/incomplete photo batch is persisted
  by `PendingUploadStore` (one JSON list under the SharedPreferences key
  `pending_photo_uploads`, entries pruned after 7 days) so uploads survive
  going offline. `AppointmentImageUploadService.drainPending()` retries the
  queue — it's reentrancy-guarded, re-queues the *unsent*
  paths on a transient failure (preserving `enqueuedAtMs` so a batch can't
  retry past the prune window), and appends through
  `appendAppointmentPictures`, whose derived document ids mean a concurrent
  edit or the batch's other half is never clobbered.
  **When the uploads land but the doc-link append itself throws transiently,
  the already-uploaded images are carried forward on the queue entry's
  `uploaded` field for an append-only retry — NOT re-uploaded (their local temp
  files are already gone), and NEVER dropped, or the Storage bytes orphan
  invisibly on the job.** That re-link is idempotent because the photo's
  document id is derived from it, so an append that actually committed
  server-side rewrites the same document rather than adding a second. (Before
  the subcollection it rested on `arrayUnion`'s deep-equality dedupe, which is
  why each carried image still serializes its exact `uploadedAt` — ISO-8601 in
  the JSON, round-tripped by `AppointmentImage.fromMap`.) An entry with no
  paths AND no carried `uploaded` images is the only genuinely-empty one that
  drains away.
  **Staging and draining share ONE serialized path** (`drainPending`, guarded
  by `_draining` + `_pendingDrain`): a save that stages a batch does NOT upload
  it directly, because a listener-driven `drainPending()` firing in that window
  would load the just-added entry and upload it concurrently — and since
  `ImageStorageService` mints each file name from `DateTime.now()`, the two
  passes produce different storage paths, so they derive different document
  ids and the photo lands twice. No dedupe of any kind catches that: the two
  really are two different objects. A request arriving mid-drain sets `_pendingDrain` so the
  in-flight pass repeats (coalesce, never drop).
  **`PendingUploadStore`'s mutations are serialized inside the store**
  (`_serialized`, one `_mutations` chain) — `add`/`remove`/`prune` are each
  `load()` → mutate → `_save()` over ONE SharedPreferences key, so two
  overlapping mutations both read the same list and the second save erases the
  first's change: a save staging a batch while a drain removed a finished one
  wrote `[E1, E2]` then `[]`, stranding E2's files with no queue entry and no
  failure notice. Keep new mutating methods inside `_serialized`, and never
  "simplify" it away by serializing at the call site — the requeue inside a
  drain is a caller too. `AppSyncListeners`
  (`core/app/app_sync_listeners.dart`, registered from `main.dart`)
  drives the drain on the offline→online flip AND when the account doc first
  arrives (Storage rules need an authed user — a signed-out drain just
  re-queues); both transitions are covered by
  `test/core/app/app_sync_listeners_test.dart`. Method-channel plugin —
  device-only verification of the upload itself.

  **S1 IS CLOSED as of 2026-08-27, and it was the CLEAR SCRIPT that closed it,
  not the retirement of the field.** Keep that distinction even now it is
  historical, because it is the one this rule got wrong three times. The
  subcollection count coming back zero (2026-08-22) was only ever about the
  SUBCOLLECTION: the parent `pictures[]` arrays were the larger set, and a
  pre-CONTRACT upload wrote a `url` ALONGSIDE the `storagePath` into every
  entry — so they were never url-ONLY and a scan for url-only rows could not
  see them. Each was a permanent, non-expiring, rules-free link readable off
  the appointment document by any assigned employee and surviving
  deactivation, with nothing left to rotate it.
  `clear-appointment-picture-arrays.js` ran against prod on 2026-08-27 and
  cleared **14 entries across 11 appointments (67 scanned)**, so no such link
  remains in the database at all. `countArrayUrls` in
  `count-legacy-image-urls.js` is how you re-check that, and it is read-only.
  **What this does NOT reach, and never could:** a URL somebody captured under
  a pre-1.49 build is still live on its object unless rotated by hand. "No
  rules-free link remains" is a statement about the DATABASE, not about every
  copy that ever left it.

## Server side

- **`cascadeDeleteAppointmentImages` + `recountAppointmentPictures`** (`appointment_images.js`, added 2026-08-13 with the photo-subcollection move; +2 exports). **The cascade is not cleanup — it is the reason this feature needs a server component at all: Firestore does NOT delete a subcollection when its parent document is deleted.** Without it every appointment delete leaves `appointments/{id}/images/*` orphaned under a parent that no longer exists: invisible in the console, unreachable by every query the app makes, and with nothing anywhere reporting it. It must cover all three delete paths — the client's single delete, its series delete, and `purgeExpiredHistory` (Admin SDK deletes fire triggers too). **It deletes the Storage BYTES too, and that half is not cleanup either**: the client used to enumerate `appointment.pictures` to know which objects to remove, and at the CONTRACT step that array stopped existing — a client that no longer reads the photos cannot list what to delete, so without this every appointment delete orphans its photos in Storage, paid for monthly and reachable by no query. The prefix (`appointments/{id}/images/`) is derived from the appointment id rather than from any stored path, so it also sweeps bytes whose document link never landed. **`deleteAppointmentImageBytes` OWNS that prefix** — it composes it from `IMAGES_SUBCOLLECTION`, and `purgeExpiredHistory`'s best-effort `deleteAppointmentImages` (`maintenance.js`) is a `try`/`catch`→`false` wrapper over it rather than a second spelling; spelled twice, with `maintenance.js` hard-coding the literal `"images"`, a rename would leave the purge deleting an empty prefix and reporting success on the one path that has no other way to find those bytes. ORDER: bytes first, documents second — the same rule `purgeExpiredHistory` follows, since the documents are the last thing pointing at those objects. It uses `deleteFiles({prefix})` for the bytes and `recursiveDelete` for the documents (the same Admin-SDK bulk writer `syncUsersByUid` already uses for `liveActivityTokens`) and **RETHROWS** on either half, deliberately unlike the best-effort cleanup elsewhere here — a swallowed error leaves exactly the permanent invisible orphans it exists to prevent, and rethrowing is what makes `retry: true` mean anything. `recountAppointmentPictures` maintains the denormalized `pictureCount` on the parent that `AppointmentCard`'s photo indicator reads (the card renders on every range-query surface and cannot afford a subcollection read each): an **absolute `count()` aggregate, never an increment**, same rule and same reason as `recountClientJobs` under `retry: true`, written with `update()` so an appointment deleted in the window is never resurrected as a count-only stub (a `NOT_FOUND` there is the normal path, not an error — the cascade has just removed the photos). **It recounts on EVERY write, including an update that cannot have moved the count, and that is deliberate.** An `if (before.exists && after.exists) return` guard was written and then removed: the only paths it skips are the offline queue replaying `set(..., {merge: true})` on the DERIVED doc id and a backfill re-run, and those two are the ONLY self-heal this counter has — a recount whose parent `update()` keeps failing exhausts its retry window and leaves `pictureCount` wrong forever, where an idempotent replay repairs it silently. It also buys nothing against the real write amplification: `appendAppointmentPictures` writes N image docs in ONE batch, so N recounts hit the SAME parent within milliseconds (against Firestore's ~1 write/sec/document guidance), but those are genuine CREATES that any such guard must let through. **That bit, and the fix was to DEBOUNCE the recount, never to suppress the replay** (2026-08-15): `debouncedRecountPictures` claims the parent in the Admin-SDK-only `appointmentRecountClaims/{appointmentId}` ledger (`create()`-fails-if-exists, same shape as `claimSeriesNotice`), so the first trigger of a batch does the one recount and the other N−1 return having written nothing — which also collapses the second-order fan-out, since every parent write re-fires `notifyAppointmentChanges` (10 photos was 10 recounts AND 11 notification invocations for one user action). **The ORDER is the whole safety argument: the claim is released BEFORE the aggregate runs.** A suppressed sibling's photo was committed before its trigger fired, and its trigger fired before the release, so a strongly-consistent `count()` after the release necessarily sees it — nothing a debounce suppressed can be missed. Count first and release after and a photo written in that gap is both suppressed and uncounted, which is the one way this optimization could corrupt the number it maintains. **The claim PROTOCOL is not in `appointment_images.js` — it is `functions/recount_claim.js`, the ONE owner shared with the client `jobCount` counter** (migrated 2026-08-28; until then this module carried a byte-identical second copy of all six bodies, which is precisely the drift the shared module was extracted to prevent, and the module's own header said so). What stays here is the adapter: the ledger name (`RECOUNT_CLAIM_COLLECTION`), `RECOUNT_SETTLE_MS`, and the `{skipped, count}` shape. `CLAIM_STALE_MS`/`CLAIM_TTL_MS` live there now — don't go looking for `RECOUNT_CLAIM_STALE_MS`/`_TTL_MS` here. Note one deliberate asymmetry with the client counter: `recountClientJobs` GATES its debounce on `mayShareABatch` (a run day-document or a repeat-series member), because the settle costs 2 s of billed wall-clock plus a claim create AND delete on writes that can never be batched; a photo write is always part of a batch, so this one stays unconditional. **The replay self-heal survives because the claim never outlives its batch**: it is deleted on the normal path, `CLAIM_STALE_MS` (15 s) takes over one abandoned by a killed invocation, and the `expiresAt` TTL policy (`firestore.indexes.json`, offset 0) is housekeeping behind both — so a later, separate write (the offline queue's replay, a backfill re-run) always claims afresh and always recounts. The claim path FAILS OPEN on any ledger error: an extra parent write is exactly the old behaviour, where a skipped recount is a wrong count with nothing left to notice it. Releasing first is also what lets a `retry: true` retry of a failed parent `update()` re-claim instead of suppressing itself. Both bodies (`purgeAppointmentImages`, `recountPictures`) take an injected `db` and are jest-tested. `IMAGES_SUBCOLLECTION` is hand-mirrored by `AppointmentImagesStore.imagesSubcollection` (`calendar/data/appointment_images_store.dart` — the photo surface split out of `firebase_appointments_repository.dart` so the CONTRACT step was a file to open rather than a diff through a 900-line class) AND by the literal `match /images/{imageId}` in `firestore.rules`; renaming one alone points the trigger at a collection nothing writes and the cascade silently stops cascading. The doc-id helper lives in the dependency-free `appointment_image_ids.js`, hand-mirrored from `appointment_image_doc_id.dart` and sharing its worked examples so a divergence fails a test rather than putting one photo at two ids.
