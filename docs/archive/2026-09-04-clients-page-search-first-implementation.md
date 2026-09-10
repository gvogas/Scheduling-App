# Clients Page "Search First" — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: SHIPPED AND DEPLOYED — ARCHIVED 2026-09-09.** Implemented
2026-09-05 (commits `767ec99e` + `b2adc705`), released in 1.58.0+87. The deploy
gate this banner carried is **CLOSED**: both new `clients` composite indexes are
`READY` and `functions/scripts/backfill-client-sort-fields.js` ran live against
prod on 2026-09-06 (720 scanned / 658 patched, the 62 untouched being clients
that already had `jobCount`) — see the 2026-09-06 rows in `docs/DEPLOYMENT.md`.
Unticked boxes below are **not** outstanding work; this plan was executed
without ticking. Design doc:
`docs/plans/2026-09-04-clients-page-search-first.md`.

**Goal:** Replace the clients tab's five-control scrolling chip row with one search field, one pinned Filter button and a filter sheet, add a sort control, and stop the tab open from paying the ~700-doc building scan.

**Architecture:** The new chrome (Filter button, active-filter chip, list header, sort) lives in `ListInformation` (`clients_screen.dart`), NOT in `ClientsListView` — that view is also the booking flow's client picker, so keeping the chrome in the screen is what makes it suppressible for free. `ClientsListView` stops watching `clientBuildingsProvider`/`clientBuildingKeysProvider`; the filter sheet watches them instead, so the scan moves off the path everyone walks onto one almost nobody opens. `ClientsFilter` stays a sealed one-of (single-select); sort is a separate `ClientsSort` enum applied only to the unfiltered paginated list.

**Tech Stack:** Flutter/Dart 3.10, Riverpod 3 (`FutureProvider.autoDispose.family`), `infinite_scroll_pagination` 5.x, Firestore composite indexes, `gen_l10n` ARB localization.

**Design doc:** `docs/plans/2026-09-04-clients-page-search-first.md`
**Supersedes:** `docs/archive/2026-08-29-clients-address-filter.md`

---

## Three findings from reading the code that the design doc does not cover

Read these before Task 1. Each one changes what a task has to do.

### F1 — `jobCount` and `createdAt` are NULLABLE, and Firestore `orderBy` DROPS documents missing the field

`ClientRecord.jobCount` is `@Default(null) int?` — "Null until the recount
trigger has run for this client" (`client_tile.dart`). `createdAt` is
`DateTime?`, and `clients_repository.dart:58` already says "Legacy docs without
`createdAt` (old imports) are excluded."

A Firestore query that orders by a field returns **only documents that have
that field**. So "Most jobs" and "Recently added" would silently omit every
client the recount trigger has never stamped and every pre-`createdAt` import —
the client is in the list under Name, and vanishes under the other two sorts,
with no error and nothing logged. This is the same class of failure as the
`SPARSE_ALL` prefix index that broke the travel sweep for two days
(`.claude/rules/firestore-indexes.md`).

**Task 3 therefore ships a backfill**, exactly as `searchTokens` did: it is a
prerequisite for the feature, not a follow-up.

### F2 — the paging cursor is hard-coded to `name`

`FirebaseClientsRepository.fetchClientsPage` (line 103) builds
`orderBy('name').orderBy(FieldPath.documentId)` and resumes with
`startAfter([_pageBoundaryNames[after.id] ?? after.name, after.id])`.
`_pageBoundaryNames` caches the raw stored `name` per doc id because
`ClientRecord.name` is a composed value that need not equal the stored field.

Changing the sort changes the cursor tuple. The boundary cache has to be keyed
by **sort and id**, or page 2 of "Most jobs" resumes from a name and returns
garbage. Task 2 owns this.

### F3 — the design's Type list is missing a real type

The design table says the Type section is "All / Residential / Commercial /
Archived". `ClientType.pickable` is **three** values —
`residential`, `commercial`, `building`. Dropping `building` would make
building-typed clients unreachable by filter while still being labelled
"Building" on their own edit sheet.

**This plan renders `ClientType.pickable`**, so the Type section is All /
Residential / Commercial / Building, with Archived below it in the same radio
group. Note the deviation for the owner when reporting; do not silently drop a
type to match a table.

> `ClientType.building` (a type on the client doc) and `ClientsFilterBuilding`
> (a derived shared-address key) are different things that share a word. The
> sheet's two sections keep them apart: "Type" holds the former, "Shared
> address" the latter.

---

## File Structure

**Created:**
- `lib/features/clients/domain/models/clients_sort.dart` — the `ClientsSort` enum and its Firestore field mapping. Its own file beside `clients_filter.dart`, for the same reason: it is a persisted-ish UI vocabulary the repository also reads.
- `lib/features/clients/widgets/sheets/clients_filter_sheet.dart` — the modal. Owns the building scan watch.
- `lib/features/clients/widgets/sections/clients_filter_bar.dart` — pinned Filter button + active-filter chip. Replaces `client_type_filter_bar.dart`.
- `lib/features/clients/widgets/sections/clients_list_header.dart` — count left, sort menu right.
- `functions/scripts/backfill-client-sort-fields.js` — stamps `jobCount`/`createdAt` on clients missing either (F1).
- `functions/client_sort_backfill_policy.js` — the pure decision half of that script, so it is testable (`maintenance_policy.js` precedent).

**Deleted:**
- `lib/features/clients/widgets/sections/client_type_filter_bar.dart`
- `lib/features/clients/widgets/sections/client_address_filter_menu.dart`
- `test/features/clients/widgets/sections/client_address_filter_menu_test.dart`

**Modified:**
- `lib/features/clients/domain/clients_repository.dart` — `fetchClientsPage` gains `sort`.
- `lib/features/clients/data/firebase_clients_repository.dart` — sort-aware query and cursor (F2).
- `lib/features/clients/widgets/views/clients_list_view.dart` — drops the two building watches, gains `sort` and `onCountChanged`.
- `lib/features/clients/widgets/cards/client_tile.dart` — drops `_TypeChip`, `_BuildingPill` and the `buildingCount` parameter.
- `lib/features/clients/screens/clients_screen.dart` — new chrome, new search hint, sort state.
- `lib/features/clients/widgets/views/client_detail_view.dart` — receives the shared-address count.
- `lib/l10n/app_en.arb`, `lib/l10n/app_fr.arb`
- `firestore.indexes.json` — two composites.
- `.claude/rules/clients.md` — the new rules.

**Modified — tests:**
- `test/features/clients/domain/clients_filter_test.dart`
- `test/features/clients/data/firebase_clients_repository_test.dart`
- `test/features/clients/widgets/views/clients_list_view_test.dart`
- `test/features/clients/widgets/cards/client_tile_test.dart`
- `test/client_tile_test.dart`
- `test/features/clients/screens/clients_screen_test.dart`
- `test/features/clients/application/clients_providers_test.dart`
- `test/features/clients/clients_scale_sweep_test.dart`

**Created — tests:**
- `test/features/clients/domain/clients_sort_test.dart`
- `test/features/clients/widgets/sheets/clients_filter_sheet_test.dart`
- `test/features/clients/widgets/sections/clients_filter_bar_test.dart`
- `test/features/clients/widgets/sections/clients_list_header_test.dart`
- `functions/__tests__/client_sort_backfill_policy.test.js`

---

### Task 1: The `ClientsSort` vocabulary

**Files:**
- Create: `lib/features/clients/domain/models/clients_sort.dart`
- Test: `test/features/clients/domain/clients_sort_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/clients/domain/clients_sort_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';

void main() {
  group('ClientsSort', () {
    test('name is the default and orders ascending on the composed name', () {
      expect(ClientsSort.name.field, 'name');
      expect(ClientsSort.name.descending, isFalse);
    });

    test('mostJobs orders jobCount descending', () {
      expect(ClientsSort.mostJobs.field, 'jobCount');
      expect(ClientsSort.mostJobs.descending, isTrue);
    });

    test('recentlyAdded orders createdAt descending', () {
      expect(ClientsSort.recentlyAdded.field, 'createdAt');
      expect(ClientsSort.recentlyAdded.descending, isTrue);
    });

    test('every member has a distinct Firestore field', () {
      final fields = ClientsSort.values.map((s) => s.field).toSet();
      expect(fields.length, ClientsSort.values.length);
    });

    // Pins F1: the two non-name sorts query a nullable field, so a client
    // missing it is dropped by Firestore. requiresBackfill is what a reader
    // greps for when a client goes missing from one sort only.
    test('the nullable-field sorts are flagged as needing the backfill', () {
      expect(ClientsSort.name.requiresBackfill, isFalse);
      expect(ClientsSort.mostJobs.requiresBackfill, isTrue);
      expect(ClientsSort.recentlyAdded.requiresBackfill, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/clients/domain/clients_sort_test.dart`
Expected: compile failure — `Target of URI doesn't exist: '.../clients_sort.dart'`.

- [ ] **Step 3: Write the enum**

Create `lib/features/clients/domain/models/clients_sort.dart`:

```dart
/// How the unfiltered client list is ordered.
///
/// The field names are the Firestore field paths the repository orders by, so
/// this enum is the ONE owner of that mapping — a sort added here without a
/// matching composite in `firestore.indexes.json` fails the query, loudly,
/// which is the intended failure.
enum ClientsSort {
  name('name', descending: false, requiresBackfill: false),
  mostJobs('jobCount', descending: true, requiresBackfill: true),
  recentlyAdded('createdAt', descending: true, requiresBackfill: true);

  const ClientsSort(
    this.field, {
    required this.descending,
    required this.requiresBackfill,
  });

  /// The Firestore field this sort orders by.
  final String field;

  final bool descending;

  /// Whether the field is nullable on a client doc, so Firestore's `orderBy`
  /// silently omits any document missing it. True means
  /// `functions/scripts/backfill-client-sort-fields.js` must have run before
  /// this sort tells the truth.
  final bool requiresBackfill;
}
```

- [ ] **Step 4: Run the test again**

Run: `flutter test test/features/clients/domain/clients_sort_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/features/clients/domain/models/clients_sort.dart test/features/clients/domain/clients_sort_test.dart
git commit -m "feat(clients): add the ClientsSort vocabulary"
```

---

### Task 2: Sort-aware paging in the repository

Solves F2. The cursor tuple follows the sort, and the boundary cache is keyed
by sort as well as id.

**Files:**
- Modify: `lib/features/clients/domain/clients_repository.dart:52`
- Modify: `lib/features/clients/data/firebase_clients_repository.dart:103-128`
- Test: `test/features/clients/data/firebase_clients_repository_test.dart`

- [ ] **Step 1: Write the failing tests**

Add to `test/features/clients/data/firebase_clients_repository_test.dart`, inside
the existing top-level `group('FirebaseClientsRepository', ...)`:

```dart
  group('fetchClientsPage sorting', () {
    test('defaults to name ascending', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('clients').doc('b').set({
        'name': 'Bravo', 'archived': false, 'jobCount': 1,
      });
      await firestore.collection('clients').doc('a').set({
        'name': 'Alpha', 'archived': false, 'jobCount': 9,
      });
      final repo = FirebaseClientsRepository(firestore);

      final page = await repo.fetchClientsPage(limit: 10);

      expect(page.map((c) => c.id), ['a', 'b']);
    });

    test('mostJobs orders by jobCount descending', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('clients').doc('a').set({
        'name': 'Alpha', 'archived': false, 'jobCount': 1,
      });
      await firestore.collection('clients').doc('b').set({
        'name': 'Bravo', 'archived': false, 'jobCount': 9,
      });
      final repo = FirebaseClientsRepository(firestore);

      final page = await repo.fetchClientsPage(
        limit: 10,
        sort: ClientsSort.mostJobs,
      );

      expect(page.map((c) => c.id), ['b', 'a']);
    });

    // F2: page 2 must resume from the SORT field, not from the name.
    test('page 2 of a jobCount sort resumes after the jobCount cursor',
        () async {
      final firestore = FakeFirebaseFirestore();
      for (final (id, jobs) in [('a', 30), ('b', 20), ('c', 10)]) {
        await firestore.collection('clients').doc(id).set({
          'name': id.toUpperCase(), 'archived': false, 'jobCount': jobs,
        });
      }
      final repo = FirebaseClientsRepository(firestore);

      final first = await repo.fetchClientsPage(
        limit: 1,
        sort: ClientsSort.mostJobs,
      );
      final second = await repo.fetchClientsPage(
        limit: 1,
        after: first.last,
        sort: ClientsSort.mostJobs,
      );

      expect(first.map((c) => c.id), ['a']);
      expect(second.map((c) => c.id), ['b']);
    });

    test('archived clients stay out of every sort', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('clients').doc('live').set({
        'name': 'Live', 'archived': false, 'jobCount': 1,
      });
      await firestore.collection('clients').doc('gone').set({
        'name': 'Gone', 'archived': true, 'jobCount': 99,
      });
      final repo = FirebaseClientsRepository(firestore);

      final page = await repo.fetchClientsPage(
        limit: 10,
        sort: ClientsSort.mostJobs,
      );

      expect(page.map((c) => c.id), ['live']);
    });
  });
```

Add the import at the top of that file if it is not already there:

```dart
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `flutter test test/features/clients/data/firebase_clients_repository_test.dart`
Expected: compile failure — `No named parameter with the name 'sort'`.

- [ ] **Step 3: Widen the interface**

In `lib/features/clients/domain/clients_repository.dart`, add the import:

```dart
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
```

and change the `fetchClientsPage` declaration (line 52) to:

```dart
  /// One page of non-archived clients in [sort] order.
  ///
  /// [after] is the last record of the previous page; the cursor tuple is
  /// (sort field, doc id), so a page fetched under one sort can never be used
  /// to resume another.
  Future<List<ClientRecord>> fetchClientsPage({
    required int limit,
    ClientRecord? after,
    ClientsSort sort = ClientsSort.name,
  });
```

- [ ] **Step 4: Make the query and the cursor follow the sort**

In `lib/features/clients/data/firebase_clients_repository.dart`, add the import:

```dart
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
```

Replace the `_pageBoundaryNames` field declaration with a sort-aware one. Find
the existing declaration (it sits with the other private fields near the top of
the class) and change it to:

```dart
  /// The raw stored value of each page's LAST document's sort field, keyed by
  /// "<sort name>:<doc id>".
  ///
  /// Keyed by sort as well as id because the cursor tuple follows the sort: a
  /// boundary captured under `name` resumes a `jobCount` query from a string
  /// and returns the wrong slice. `ClientRecord.name` is composed and need not
  /// equal the stored field, which is why the raw value is cached at all.
  final Map<String, Object?> _pageBoundaryValues = <String, Object?>{};
```

Replace the whole body of `fetchClientsPage` (lines 103-128) with:

```dart
  Future<List<ClientRecord>> fetchClientsPage({
    required int limit,
    ClientRecord? after,
    ClientsSort sort = ClientsSort.name,
  }) async {
    var query = _clients
        .where('archived', isEqualTo: false)
        .orderBy(sort.field, descending: sort.descending)
        .orderBy(FieldPath.documentId);
    if (after != null) {
      query = query.startAfter([
        _pageBoundaryValues['${sort.name}:${after.id}'] ??
            _fallbackCursorValue(after, sort),
        after.id,
      ]);
    }
    final snapshot = await query.limit(limit).get();
    final docs = snapshot.docs;
    if (docs.isNotEmpty) {
      final last = docs.last;
      final cacheKey = '${sort.name}:${last.id}';
      _pageBoundaryValues.remove(cacheKey);
      if (_pageBoundaryValues.length >= _pageBoundaryMax) {
        _pageBoundaryValues.remove(_pageBoundaryValues.keys.first);
      }
      _pageBoundaryValues[cacheKey] = last.data()[sort.field];
    }
    return docs.map((doc) => ClientRecord.fromMap(doc.id, doc.data())).toList();
  }

  // Only reached when the boundary cache has evicted the entry — the record's
  // own value is a good enough cursor for every sort except `name`, which is
  // composed rather than stored.
  Object? _fallbackCursorValue(ClientRecord after, ClientsSort sort) =>
      switch (sort) {
        ClientsSort.name => after.name,
        ClientsSort.mostJobs => after.jobCount,
        ClientsSort.recentlyAdded => after.createdAt,
      };
```

- [ ] **Step 5: Run the repository tests**

Run: `flutter test test/features/clients/data/firebase_clients_repository_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/clients/domain/clients_repository.dart lib/features/clients/data/firebase_clients_repository.dart test/features/clients/data/firebase_clients_repository_test.dart
git commit -m "feat(clients): make fetchClientsPage sort-aware"
```

---

### Task 3: The indexes and the backfill (F1)

Without both halves the two new sorts return an incomplete list and say nothing.

**Files:**
- Modify: `firestore.indexes.json`
- Create: `functions/client_sort_backfill_policy.js`
- Create: `functions/scripts/backfill-client-sort-fields.js`
- Test: `functions/__tests__/client_sort_backfill_policy.test.js`

- [ ] **Step 1: Add the two composites**

In `firestore.indexes.json`, add these two objects to the `indexes` array,
beside the existing `clients` entries:

```json
    {
      "collectionGroup": "clients",
      "queryScope": "COLLECTION",
      "fields": [
        {"fieldPath": "archived", "order": "ASCENDING"},
        {"fieldPath": "jobCount", "order": "DESCENDING"},
        {"fieldPath": "__name__", "order": "ASCENDING"}
      ]
    },
    {
      "collectionGroup": "clients",
      "queryScope": "COLLECTION",
      "fields": [
        {"fieldPath": "archived", "order": "ASCENDING"},
        {"fieldPath": "createdAt", "order": "DESCENDING"},
        {"fieldPath": "__name__", "order": "ASCENDING"}
      ]
    },
```

> `__name__` lands at the END of the field list and is NOT redundant with a
> shorter prefix index — see `.claude/rules/firestore-indexes.md` and the
> 2026-09-01 travel-sweep regression. Do not "tidy" either entry away.

- [ ] **Step 2: Write the failing policy test**

Create `functions/__tests__/client_sort_backfill_policy.test.js`:

```js
"use strict";

const {planClientSortPatch} = require("../client_sort_backfill_policy");

describe("planClientSortPatch", () => {
  const now = new Date("2026-09-05T00:00:00Z");

  it("returns null for a doc that already has both fields", () => {
    expect(planClientSortPatch({jobCount: 3, createdAt: now}, now)).toBeNull();
  });

  it("stamps jobCount 0 when it is missing", () => {
    expect(planClientSortPatch({createdAt: now}, now)).toEqual({jobCount: 0});
  });

  it("stamps jobCount 0 when it is null", () => {
    expect(planClientSortPatch({jobCount: null, createdAt: now}, now))
        .toEqual({jobCount: 0});
  });

  it("stamps createdAt from the fallback when it is missing", () => {
    expect(planClientSortPatch({jobCount: 2}, now)).toEqual({createdAt: now});
  });

  it("stamps both when both are missing", () => {
    expect(planClientSortPatch({}, now)).toEqual({jobCount: 0, createdAt: now});
  });

  // A real count must never be overwritten by the backfill - the recount
  // trigger owns that number.
  it("never rewrites an existing non-zero jobCount", () => {
    expect(planClientSortPatch({jobCount: 7, createdAt: now}, now)).toBeNull();
  });

  it("treats an existing zero jobCount as already stamped", () => {
    expect(planClientSortPatch({jobCount: 0, createdAt: now}, now)).toBeNull();
  });
});
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `npm --prefix functions test -- client_sort_backfill_policy`
Expected: `Cannot find module '../client_sort_backfill_policy'`.

- [ ] **Step 4: Write the policy**

Create `functions/client_sort_backfill_policy.js`:

```js
"use strict";

/**
 * Decide what a client doc is missing for the sort queries to see it.
 *
 * Firestore `orderBy` returns only documents that HAVE the ordered field, so a
 * client with no `jobCount` (recount trigger never ran) or no `createdAt`
 * (pre-2026 import) disappears from the Most jobs / Recently added sorts while
 * still appearing under Name.
 *
 * @param {!Object} data The client document data.
 * @param {!Date} fallbackCreatedAt Value to stamp when `createdAt` is absent.
 * @return {?Object} The patch to merge, or null when nothing is missing.
 */
function planClientSortPatch(data, fallbackCreatedAt) {
  const patch = {};
  if (data.jobCount === undefined || data.jobCount === null) {
    patch.jobCount = 0;
  }
  if (data.createdAt === undefined || data.createdAt === null) {
    patch.createdAt = fallbackCreatedAt;
  }
  return Object.keys(patch).length === 0 ? null : patch;
}

module.exports = {planClientSortPatch};
```

- [ ] **Step 5: Run the policy test**

Run: `npm --prefix functions test -- client_sort_backfill_policy`
Expected: 7 passed.

- [ ] **Step 6: Write the script around it**

Create `functions/scripts/backfill-client-sort-fields.js`:

```js
"use strict";

/**
 * Stamp `jobCount` and `createdAt` on every client doc missing either, so the
 * Most jobs / Recently added sorts return the whole roster.
 *
 * PREREQUISITE for the search-first clients release, not a follow-up - see
 * docs/plans/2026-09-04-clients-page-search-first-implementation.md.
 *
 * Usage:
 *   node scripts/backfill-client-sort-fields.js --dry-run
 *   node scripts/backfill-client-sort-fields.js
 */

const admin = require("firebase-admin");
const {planClientSortPatch} = require("../client_sort_backfill_policy");

const DRY_RUN = process.argv.includes("--dry-run");
const PAGE_SIZE = 400;

/**
 * Walk the clients collection and apply the patch each doc needs.
 *
 * @return {!Promise<void>} Resolves when the whole collection is walked.
 */
async function main() {
  admin.initializeApp();
  const db = admin.firestore();
  const fallback = admin.firestore.FieldValue.serverTimestamp();

  let cursor = null;
  let scanned = 0;
  let patched = 0;

  for (;;) {
    let query = db.collection("clients")
        .orderBy(admin.firestore.FieldPath.documentId())
        .limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);

    const snapshot = await query.get();
    if (snapshot.empty) break;

    const batch = db.batch();
    let inBatch = 0;
    for (const doc of snapshot.docs) {
      scanned += 1;
      const patch = planClientSortPatch(doc.data(), fallback);
      if (!patch) continue;
      patched += 1;
      if (!DRY_RUN) {
        batch.set(doc.ref, patch, {merge: true});
        inBatch += 1;
      }
    }
    if (inBatch > 0) await batch.commit();

    cursor = snapshot.docs[snapshot.docs.length - 1];
    if (snapshot.size < PAGE_SIZE) break;
  }

  console.log(JSON.stringify({dryRun: DRY_RUN, scanned, patched}));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
```

> `--dry-run` must not write. `.claude/rules` records a backfill that wrote
> everything and then threw under `--dry-run`; the `if (!DRY_RUN)` guard above
> is inside the loop for exactly that reason. Verify by running the dry run
> against the emulator and confirming `patched > 0` with no document changed.

- [ ] **Step 7: Lint and run the whole functions suite**

Run: `npm --prefix functions run lint && npm --prefix functions test`
Expected: eslint clean; all suites pass.

- [ ] **Step 8: Commit**

```bash
git add firestore.indexes.json functions/client_sort_backfill_policy.js functions/scripts/backfill-client-sort-fields.js functions/__tests__/client_sort_backfill_policy.test.js
git commit -m "feat(clients): add the sort indexes and their prerequisite backfill"
```

---

### Task 4: The filter sheet

Owns the building scan watch, so the tab open no longer pays it.

**Files:**
- Create: `lib/features/clients/widgets/sheets/clients_filter_sheet.dart`
- Test: `test/features/clients/widgets/sheets/clients_filter_sheet_test.dart`

- [ ] **Step 1: Add the ARB keys**

In `lib/l10n/app_en.arb` add, keeping the file's existing `clients_` grouping:

```json
  "clients_filter": "Filter",
  "@clients_filter": {
    "description": "Label of the button that opens the clients filter sheet."
  },
  "clients_filterTitle": "Filter clients",
  "@clients_filterTitle": {
    "description": "Title of the clients filter sheet."
  },
  "clients_filterSectionType": "Type",
  "@clients_filterSectionType": {
    "description": "Heading of the type section inside the clients filter sheet."
  },
  "clients_filterSectionAddress": "Shared address",
  "@clients_filterSectionAddress": {
    "description": "Heading of the shared-address section inside the clients filter sheet."
  },
  "clients_filterAll": "All clients",
  "@clients_filterAll": {
    "description": "The option that clears every clients filter."
  },
  "clients_clearFilter": "Clear filter",
  "@clients_clearFilter": {
    "description": "Semantic label of the dismiss control on the active filter chip."
  },
```

In `lib/l10n/app_fr.arb` add the same keys in lockstep (no `@key` blocks — EN is
the template):

```json
  "clients_filter": "Filtrer",
  "clients_filterTitle": "Filtrer les clients",
  "clients_filterSectionType": "Type",
  "clients_filterSectionAddress": "Adresse partagée",
  "clients_filterAll": "Tous les clients",
  "clients_clearFilter": "Effacer le filtre",
```

The repo's ARB hook regenerates `lib/l10n/.gen/`; do not run `flutter gen-l10n`
by hand.

- [ ] **Step 2: Write the failing test**

Create `test/features/clients/widgets/sheets/clients_filter_sheet_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/features/clients/widgets/sheets/clients_filter_sheet.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _harness({
  required ClientsFilter selected,
  required ValueChanged<ClientsFilter> onChanged,
  List<ClientBuilding> buildings = const [],
  bool buildingsLoading = false,
}) {
  return ProviderScope(
    overrides: [
      clientBuildingsProvider.overrideWith(
        (ref) async {
          if (buildingsLoading) return await Completer<List<ClientBuilding>>().future;
          return buildings;
        },
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ClientsFilterSheet(selected: selected, onChanged: onChanged),
      ),
    ),
  );
}

void main() {
  testWidgets('renders every pickable type plus All and Archived',
      (tester) async {
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterAll(), onChanged: (_) {}),
    );
    await tester.pumpAndSettle();

    // F3: three pickable types, not two.
    for (final type in ClientType.pickable) {
      expect(find.text(clientTypeLabel(tester.l10n, type)), findsOneWidget);
    }
    expect(find.text(tester.l10n.clients_filterAll), findsOneWidget);
    expect(find.text(tester.l10n.clients_filterArchived), findsOneWidget);
  });

  testWidgets('picking a type emits that filter', (tester) async {
    ClientsFilter? emitted;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterAll(),
        onChanged: (next) => emitted = next,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.text(clientTypeLabel(tester.l10n, ClientType.residential)),
    );
    await tester.pumpAndSettle();

    expect(emitted, const ClientsFilterType(ClientType.residential));
  });

  // The whole point of the redesign: one radio group, so picking an address
  // clears the type rather than combining with it.
  testWidgets('picking an address replaces an active type filter',
      (tester) async {
    ClientsFilter? emitted;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterType(ClientType.commercial),
        onChanged: (next) => emitted = next,
        buildings: const [
          ClientBuilding(
            key: 'k1',
            street: '1200 Rue Sherbrooke',
            city: 'Montreal',
            clientCount: 4,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('1200 Rue Sherbrooke'));
    await tester.pumpAndSettle();

    expect(emitted, const ClientsFilterBuilding('k1'));
  });

  testWidgets('shows a skeleton in the address section while the scan resolves',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterAll(),
        onChanged: (_) {},
        buildingsLoading: true,
      ),
    );
    await tester.pump();

    // The sheet opens immediately rather than waiting on the scan.
    expect(find.text(tester.l10n.clients_filterTitle), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('hides the address section entirely when nothing is shared',
      (tester) async {
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterAll(), onChanged: (_) {}),
    );
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_filterSectionAddress), findsNothing);
  });
}
```

Add `import 'dart:async';` at the top of the test file for the `Completer`.
`tester.l10n` is the existing helper in `test/support/`; if that file does not
expose it, read the l10n through
`AppLocalizations.of(tester.element(find.byType(Scaffold)))` instead.

- [ ] **Step 3: Run it and confirm it fails**

Run: `flutter test test/features/clients/widgets/sheets/clients_filter_sheet_test.dart`
Expected: compile failure — `clients_filter_sheet.dart` does not exist.

- [ ] **Step 4: Write the sheet**

Create `lib/features/clients/widgets/sheets/clients_filter_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/application/clients_providers.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/domain/policies/client_building.dart';
import 'package:scheduling/l10n/l10n.dart';
import 'package:scheduling/shared/widgets/primitives/section_label.dart';

/// The clients list's one filter surface: Type and Shared address as a single
/// radio group.
///
/// ONE group across two sections because [ClientsFilter] is a sealed one-of —
/// picking an address clears a type and vice versa. That constraint was always
/// there; the chip row hid it behind controls that looked independent.
///
/// This is also the ONLY watcher of [clientBuildingsProvider]. Keeping it here
/// rather than in `ClientsListView` is what takes the ~700-doc `orderBy('name')`
/// scan off the clients-tab open — see that provider's own doc comment.
class ClientsFilterSheet extends ConsumerWidget {
  const ClientsFilterSheet({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final ClientsFilter selected;
  final ValueChanged<ClientsFilter> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final buildings = ref.watch(clientBuildingsProvider);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sp8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sp16,
                AppSpacing.sp8,
                AppSpacing.sp16,
                AppSpacing.sp8,
              ),
              child: Text(
                l10n.clients_filterTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _Option(
              label: l10n.clients_filterAll,
              value: const ClientsFilterAll(),
              selected: selected,
              onChanged: onChanged,
            ),
            _SectionHeading(l10n.clients_filterSectionType),
            for (final type in ClientType.pickable)
              _Option(
                label: clientTypeLabel(l10n, type),
                value: ClientsFilterType(type),
                selected: selected,
                onChanged: onChanged,
              ),
            _Option(
              label: l10n.clients_filterArchived,
              value: const ClientsFilterArchived(),
              selected: selected,
              onChanged: onChanged,
            ),
            ...buildings.when(
              // The sheet opens immediately; the scan fills this section in.
              loading: () => [
                _SectionHeading(l10n.clients_filterSectionAddress),
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.sp16),
                  child: Center(child: CircularProgressIndicator.adaptive()),
                ),
              ],
              // A failed scan hides the section rather than showing a broken
              // control - the type options above still work.
              error: (_, _) => const <Widget>[],
              data: (list) => list.isEmpty
                  ? const <Widget>[]
                  : [
                      _SectionHeading(l10n.clients_filterSectionAddress),
                      for (final building in list)
                        _Option(
                          label: building.street,
                          secondary: building.city.isEmpty
                              ? null
                              : building.city,
                          trailing: '${building.clientCount}',
                          value: ClientsFilterBuilding(building.key),
                          selected: selected,
                          onChanged: onChanged,
                        ),
                    ],
            ),
            const SizedBox(height: AppSpacing.sp8),
          ],
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.sp16,
      AppSpacing.sp16,
      AppSpacing.sp16,
      AppSpacing.sp4,
    ),
    child: SectionLabel(label),
  );
}

/// One row of the single radio group.
class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.value,
    required this.selected,
    required this.onChanged,
    this.secondary,
    this.trailing,
  });

  final String label;
  final String? secondary;
  final String? trailing;
  final ClientsFilter value;
  final ClientsFilter selected;
  final ValueChanged<ClientsFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = selected == value;
    return ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: isSelected ? theme.palette.primaryAccent : theme.palette.textMuted,
      ),
      title: Text(label),
      subtitle: secondary == null ? null : Text(secondary!),
      trailing: trailing == null
          ? null
          : Text(
              trailing!,
              style: theme.monoType.data.copyWith(
                color: theme.palette.textMuted,
              ),
            ),
      selected: isSelected,
      onTap: () => onChanged(value),
    );
  }
}

/// Opens the filter sheet and returns the picked filter, or null if dismissed.
Future<ClientsFilter?> showClientsFilterSheet(
  BuildContext context, {
  required ClientsFilter selected,
}) => showModalBottomSheet<ClientsFilter>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheetContext) => ClientsFilterSheet(
    selected: selected,
    onChanged: (next) => Navigator.of(sheetContext).pop(next),
  ),
);
```

- [ ] **Step 5: Run the sheet tests**

Run: `flutter test test/features/clients/widgets/sheets/clients_filter_sheet_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/clients/widgets/sheets/clients_filter_sheet.dart test/features/clients/widgets/sheets/clients_filter_sheet_test.dart lib/l10n/app_en.arb lib/l10n/app_fr.arb
git commit -m "feat(clients): add the filter sheet and move the building scan onto it"
```

---

### Task 5: The pinned Filter button and active-filter chip

**Files:**
- Create: `lib/features/clients/widgets/sections/clients_filter_bar.dart`
- Test: `test/features/clients/widgets/sections/clients_filter_bar_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/features/clients/widgets/sections/clients_filter_bar_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_filter_bar.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _harness({
  required ClientsFilter selected,
  VoidCallback? onOpen,
  ValueChanged<ClientsFilter>? onChanged,
  String? buildingLabel,
  double width = 260,
  double textScale = 2,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 640),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: ClientsFilterBar(
        selected: selected,
        onOpen: onOpen ?? () {},
        onChanged: onChanged ?? (_) {},
        activeBuildingLabel: buildingLabel,
      ),
    ),
  ),
);

void main() {
  testWidgets('the Filter button is present at 260px with 2x text',
      (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(selected: const ClientsFilterAll()));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_filter), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows no active chip when the filter is All', (tester) async {
    await tester.pumpWidget(_harness(selected: const ClientsFilterAll()));
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('shows one dismissible chip naming the active type',
      (tester) async {
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterType(ClientType.commercial)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(clientTypeLabel(tester.l10n, ClientType.commercial)),
      findsOneWidget,
    );
    expect(find.byType(InputChip), findsOneWidget);
  });

  testWidgets('dismissing the chip clears back to All', (tester) async {
    ClientsFilter? emitted;
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterArchived(),
        onChanged: (next) => emitted = next,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(emitted, const ClientsFilterAll());
  });

  testWidgets('an active building chip uses the label it is given',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        selected: const ClientsFilterBuilding('k1'),
        buildingLabel: '1200 Rue Sherbrooke',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1200 Rue Sherbrooke'), findsOneWidget);
  });

  testWidgets('tapping Filter calls onOpen', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _harness(selected: const ClientsFilterAll(), onOpen: () => opened++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(tester.l10n.clients_filter));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `flutter test test/features/clients/widgets/sections/clients_filter_bar_test.dart`
Expected: compile failure — `clients_filter_bar.dart` does not exist.

- [ ] **Step 3: Write the bar**

Create `lib/features/clients/widgets/sections/clients_filter_bar.dart`:

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/client_type.dart';
import 'package:scheduling/features/clients/domain/models/clients_filter.dart';
import 'package:scheduling/l10n/l10n.dart';

/// The Filter button, pinned FIRST and outside any scroller, plus the one chip
/// naming whatever filter is active.
///
/// Pinned because the row it replaces was a 48px horizontal scroller holding
/// five controls, so at large text scale something was always off-screen on
/// arrival. Only ONE chip can ever show: [ClientsFilter] is a sealed one-of.
class ClientsFilterBar extends StatelessWidget {
  const ClientsFilterBar({
    required this.selected,
    required this.onOpen,
    required this.onChanged,
    this.activeBuildingLabel,
    super.key,
  });

  final ClientsFilter selected;
  final VoidCallback onOpen;
  final ValueChanged<ClientsFilter> onChanged;

  /// Street of the active [ClientsFilterBuilding], resolved by the caller from
  /// the scan the sheet owns — this bar never watches it.
  final String? activeBuildingLabel;

  String? _activeLabel(AppLocalizations l10n) => switch (selected) {
    ClientsFilterAll() => null,
    ClientsFilterType(:final type) => clientTypeLabel(l10n, type),
    ClientsFilterArchived() => l10n.clients_filterArchived,
    ClientsFilterBuilding() => activeBuildingLabel ?? l10n.clients_filterByAddress,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = _activeLabel(l10n);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        AppSpacing.sp4,
        AppSpacing.sp16,
        AppSpacing.sp8,
      ),
      child: Row(
        children: [
          Badge(
            isLabelVisible: label != null,
            child: OutlinedButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.tune, size: 18),
              label: Text(l10n.clients_filter),
            ),
          ),
          if (label != null) ...[
            const SizedBox(width: AppSpacing.sp8),
            Flexible(
              child: InputChip(
                label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                deleteIcon: const Icon(Icons.close, size: 18),
                deleteButtonTooltipMessage: l10n.clients_clearFilter,
                onDeleted: () => onChanged(const ClientsFilterAll()),
                onPressed: onOpen,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run the bar tests**

Run: `flutter test test/features/clients/widgets/sections/clients_filter_bar_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/features/clients/widgets/sections/clients_filter_bar.dart test/features/clients/widgets/sections/clients_filter_bar_test.dart
git commit -m "feat(clients): add the pinned filter bar"
```

---

### Task 6: The list header — count left, sort right

**Files:**
- Create: `lib/features/clients/widgets/sections/clients_list_header.dart`
- Test: `test/features/clients/widgets/sections/clients_list_header_test.dart`

- [ ] **Step 1: Add the ARB keys**

In `lib/l10n/app_en.arb`:

```json
  "clients_countLabel": "{count, plural, =0{No clients} =1{1 client} other{{count} clients}}",
  "@clients_countLabel": {
    "description": "How many clients the list is currently showing.",
    "placeholders": {"count": {"type": "int"}}
  },
  "clients_sort": "Sort",
  "@clients_sort": {
    "description": "Label of the control that changes the clients list order."
  },
  "clients_sortByName": "Name",
  "@clients_sortByName": {
    "description": "Sort the clients list alphabetically by name."
  },
  "clients_sortMostJobs": "Most jobs",
  "@clients_sortMostJobs": {
    "description": "Sort the clients list by job count, highest first."
  },
  "clients_sortRecentlyAdded": "Recently added",
  "@clients_sortRecentlyAdded": {
    "description": "Sort the clients list by creation date, newest first."
  },
```

In `lib/l10n/app_fr.arb`:

```json
  "clients_countLabel": "{count, plural, =0{Aucun client} =1{1 client} other{{count} clients}}",
  "clients_sort": "Trier",
  "clients_sortByName": "Nom",
  "clients_sortMostJobs": "Plus de travaux",
  "clients_sortRecentlyAdded": "Ajoutés récemment",
```

- [ ] **Step 2: Write the failing test**

Create `test/features/clients/widgets/sections/clients_list_header_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_list_header.dart';
import 'package:scheduling/l10n/l10n.dart';

Widget _harness({
  int? count,
  ClientsSort sort = ClientsSort.name,
  ValueChanged<ClientsSort>? onSortChanged,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(260, 640),
      textScaler: TextScaler.linear(2),
    ),
    child: Scaffold(
      body: ClientsListHeader(
        count: count,
        sort: sort,
        onSortChanged: onSortChanged ?? (_) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('renders the pluralized count', (tester) async {
    await tester.pumpWidget(_harness(count: 3));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_countLabel(3)), findsOneWidget);
  });

  // Null is "not counted yet", which must not render as zero.
  testWidgets('renders no count while the first page is still loading',
      (tester) async {
    await tester.pumpWidget(_harness(count: null));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_countLabel(0)), findsNothing);
  });

  testWidgets('names the active sort', (tester) async {
    await tester.pumpWidget(_harness(count: 1, sort: ClientsSort.mostJobs));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_sortMostJobs), findsOneWidget);
  });

  testWidgets('picking a sort emits it', (tester) async {
    ClientsSort? emitted;
    await tester.pumpWidget(
      _harness(count: 1, onSortChanged: (next) => emitted = next),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(tester.l10n.clients_sortByName));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tester.l10n.clients_sortRecentlyAdded).last);
    await tester.pumpAndSettle();

    expect(emitted, ClientsSort.recentlyAdded);
  });

  testWidgets('does not overflow at 260px with 2x text', (tester) async {
    tester.view.physicalSize = const Size(260, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(count: 1234));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `flutter test test/features/clients/widgets/sections/clients_list_header_test.dart`
Expected: compile failure — `clients_list_header.dart` does not exist.

- [ ] **Step 4: Write the header**

Create `lib/features/clients/widgets/sections/clients_list_header.dart`:

```dart
import 'package:flutter/material.dart';

import 'package:scheduling/core/theme/design_tokens.dart';
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/l10n/l10n.dart';

/// One line above the list: how many clients on the left, the order on the
/// right.
class ClientsListHeader extends StatelessWidget {
  const ClientsListHeader({
    required this.count,
    required this.sort,
    required this.onSortChanged,
    super.key,
  });

  /// Null while the first page is still settling — an unknown count renders
  /// nothing rather than a misleading zero, the same rule the row's job count
  /// follows.
  final int? count;

  final ClientsSort sort;
  final ValueChanged<ClientsSort> onSortChanged;

  static String sortLabel(AppLocalizations l10n, ClientsSort sort) =>
      switch (sort) {
        ClientsSort.name => l10n.clients_sortByName,
        ClientsSort.mostJobs => l10n.clients_sortMostJobs,
        ClientsSort.recentlyAdded => l10n.clients_sortRecentlyAdded,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sp16,
        0,
        AppSpacing.sp8,
        AppSpacing.sp4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              count == null ? '' : l10n.clients_countLabel(count!),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.palette.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          PopupMenuButton<ClientsSort>(
            tooltip: l10n.clients_sort,
            initialValue: sort,
            onSelected: onSortChanged,
            itemBuilder: (context) => [
              for (final option in ClientsSort.values)
                PopupMenuItem<ClientsSort>(
                  value: option,
                  child: Text(sortLabel(l10n, option)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sp8,
                vertical: AppSpacing.sp8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      sortLabel(l10n, sort),
                      style: theme.textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Run the header tests**

Run: `flutter test test/features/clients/widgets/sections/clients_list_header_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/clients/widgets/sections/clients_list_header.dart test/features/clients/widgets/sections/clients_list_header_test.dart lib/l10n/app_en.arb lib/l10n/app_fr.arb
git commit -m "feat(clients): add the list header with count and sort"
```

---

### Task 7: `ClientsListView` drops the scan, gains sort and a count

This is the read-amplification fix.

**Files:**
- Modify: `lib/features/clients/widgets/views/clients_list_view.dart`
- Test: `test/features/clients/widgets/views/clients_list_view_test.dart`

- [ ] **Step 1: Write the failing tests**

Add to `test/features/clients/widgets/views/clients_list_view_test.dart`:

```dart
  // The read-amplification fix: opening the tab must not touch the scan.
  testWidgets('does not read the building providers on build', (tester) async {
    var buildingReads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clientsRepositoryProvider.overrideWithValue(_FakeRepo()),
          clientBuildingsProvider.overrideWith((ref) async {
            buildingReads += 1;
            return const <ClientBuilding>[];
          }),
        ],
        child: _listHarness(),
      ),
    );
    await tester.pumpAndSettle();

    expect(buildingReads, 0);
  });

  testWidgets('passes the sort through to the repository', (tester) async {
    final repo = _FakeRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [clientsRepositoryProvider.overrideWithValue(repo)],
        child: _listHarness(sort: ClientsSort.mostJobs),
      ),
    );
    await tester.pumpAndSettle();

    expect(repo.lastSort, ClientsSort.mostJobs);
  });

  testWidgets('reports the loaded count', (tester) async {
    int? reported;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clientsRepositoryProvider.overrideWithValue(_FakeRepo(pageSize: 2)),
        ],
        child: _listHarness(onCountChanged: (n) => reported = n),
      ),
    );
    await tester.pumpAndSettle();

    expect(reported, 2);
  });
```

`_listHarness` and `_FakeRepo` are the file's existing helpers — extend
`_FakeRepo.fetchClientsPage` to record `lastSort`, and give `_listHarness` the
new `sort` and `onCountChanged` parameters, forwarding both to
`ClientsListView`.

- [ ] **Step 2: Run and confirm they fail**

Run: `flutter test test/features/clients/widgets/views/clients_list_view_test.dart`
Expected: failures — `No named parameter with the name 'sort'`, and
`buildingReads` is 1 rather than 0.

- [ ] **Step 3: Widen the widget**

In `lib/features/clients/widgets/views/clients_list_view.dart`, add to the
constructor and fields:

```dart
    this.sort = ClientsSort.name,
    this.onCountChanged,
```

```dart
  /// Order for the unfiltered paginated list. Ignored by the filter and search
  /// paths, which are bounded in-memory lists ordered by the query behind them.
  final ClientsSort sort;

  /// Fires with however many rows are currently rendered, so the screen's
  /// header can show a count without this view owning any chrome — it is also
  /// the booking flow's client picker, which must stay chrome-free.
  final void Function(int count)? onCountChanged;
```

Add the import:

```dart
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
```

- [ ] **Step 4: Delete the scan watches**

In `build`, delete this whole block:

```dart
    // Only while this tab is the visible one.
    final tab = HubShellScope.currentOf(context);
    if (tab == null || tab == HubTab.clients) {
      _buildingCounts = ref.watch(clientBuildingCountsProvider);
      _buildingKeys = ref.watch(clientBuildingKeysProvider).value ?? const {};
    }
```

Delete the `_buildingCounts`, `_buildingKeys` and `_buildingKeyOf` members and
the `buildingCount:` argument in `_slidableTile`. Remove the now-unused imports:
`client_building.dart`, `hub_shell_scope.dart`, and `app_destination.dart` if
nothing else in the file uses it (`flutter analyze` will name any that are still
needed).

- [ ] **Step 5: Thread the sort and the count**

In `_fetchPage`, pass the sort:

```dart
      return await repository.fetchClientsPage(
        after: after,
        limit: _pageSize,
        sort: widget.sort,
      );
```

Refetch when the sort changes — add to the existing `didUpdateWidget` (the
`DebouncedPagedSearch` mixin already defines one, so call `super` first):

```dart
  @override
  void didUpdateWidget(ClientsListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sort != widget.sort) _pagingController.refresh();
  }
```

Report the count from `_resultsList` and from the paged list. Add this helper
and call it at the top of both:

```dart
  // Post-frame: this runs during build, and the header it feeds is a sibling
  // in the same tree.
  void _reportCount(int count) {
    final report = widget.onCountChanged;
    if (report == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) report(count);
    });
  }
```

In `_resultsList`, call `_reportCount(items.length)` before returning the
`ListView.separated`. In the `PagingListener` builder, call
`_reportCount(state.items?.length ?? 0)` before returning the `PagedListView`.

- [ ] **Step 6: Run the view tests**

Run: `flutter test test/features/clients/widgets/views/clients_list_view_test.dart`
Expected: `All tests passed!`

- [ ] **Step 7: Commit**

```bash
git add lib/features/clients/widgets/views/clients_list_view.dart test/features/clients/widgets/views/clients_list_view_test.dart
git commit -m "perf(clients): take the building scan off the clients tab open"
```

---

### Task 8: Calm the row

Two of the four signals go. The design accepts losing the Building pill (its
count moves to the detail sheet in Task 10).

**Files:**
- Modify: `lib/features/clients/widgets/cards/client_tile.dart`
- Test: `test/features/clients/widgets/cards/client_tile_test.dart`, `test/client_tile_test.dart`

- [ ] **Step 1: Write the failing tests**

In `test/features/clients/widgets/cards/client_tile_test.dart` add:

```dart
  testWidgets('no longer renders a type chip', (tester) async {
    await tester.pumpWidget(
      _tileHarness(_client(type: ClientType.commercial)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(clientTypeLabel(tester.l10n, ClientType.commercial)),
      findsNothing,
    );
  });

  testWidgets('still renders the archived pill', (tester) async {
    await tester.pumpWidget(_tileHarness(_client(archived: true)));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_filterArchived), findsOneWidget);
  });

  testWidgets('still renders the job count', (tester) async {
    await tester.pumpWidget(_tileHarness(_client(jobCount: 12)));
    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget);
  });
```

`_tileHarness` and `_client` are the file's existing helpers; add the `type`,
`archived` and `jobCount` parameters to `_client` if it does not take them.

- [ ] **Step 2: Run and confirm the type-chip test fails**

Run: `flutter test test/features/clients/widgets/cards/client_tile_test.dart`
Expected: the "no longer renders a type chip" test FAILS (`findsNothing` found
one); the other two pass already.

- [ ] **Step 3: Cut the two badges**

In `lib/features/clients/widgets/cards/client_tile.dart`:

- delete the `buildingCount` constructor parameter and field;
- delete the `hasType` and `isShared` locals;
- replace the `badges` list with:

```dart
    // Archived clients drop out of the list but stay in search results, so the
    // row is the only place that can say why one looks "missing". It is the one
    // badge left: type and shared-address moved to the filter sheet and the
    // client detail respectively, because four signals under one name competed.
    final badges = <Widget>[if (client.archived) const _ArchivedPill()];
```

- delete the `_TypeChip` and `_BuildingPill` classes entirely;
- remove the now-unused `client_type.dart` import if nothing else in the file
  uses it.

- [ ] **Step 4: Fix the other tile test file**

`test/client_tile_test.dart` also asserts on the type chip and may pass
`buildingCount:`. Update it the same way — drop the `buildingCount` argument and
any type-chip expectation.

- [ ] **Step 5: Run both tile suites**

Run: `flutter test test/features/clients/widgets/cards/client_tile_test.dart test/client_tile_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/clients/widgets/cards/client_tile.dart test/features/clients/widgets/cards/client_tile_test.dart test/client_tile_test.dart
git commit -m "refactor(clients): drop the type chip and building pill from the row"
```

---

### Task 9: Wire the screen, retire the chip row

**Files:**
- Modify: `lib/features/clients/screens/clients_screen.dart`
- Delete: `lib/features/clients/widgets/sections/client_type_filter_bar.dart`
- Delete: `lib/features/clients/widgets/sections/client_address_filter_menu.dart`
- Delete: `test/features/clients/widgets/sections/client_address_filter_menu_test.dart`
- Test: `test/features/clients/screens/clients_screen_test.dart`

- [ ] **Step 1: Retire the old search hint key**

In `lib/l10n/app_en.arb`, replace the `clients_searchByNameOrPhone` key and its
`@` block with:

```json
  "clients_searchAllFields": "Name, phone, address, email…",
  "@clients_searchAllFields": {
    "description": "Hint of the clients search field, naming what the search matches."
  },
```

In `lib/l10n/app_fr.arb`, replace `clients_searchByNameOrPhone` with:

```json
  "clients_searchAllFields": "Nom, téléphone, adresse, courriel…",
```

`clients_screen.dart:91` is the only caller (verified by grep), so nothing else
needs updating.

- [ ] **Step 2: Write the failing screen tests**

Add to `test/features/clients/screens/clients_screen_test.dart`:

```dart
  testWidgets('shows the Filter button, not the old chip row', (tester) async {
    await tester.pumpWidget(_screenHarness(isAdmin: true));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_filter), findsOneWidget);
    expect(
      find.text(clientTypeLabel(tester.l10n, ClientType.residential)),
      findsNothing,
    );
  });

  testWidgets('the search hint names every matched field', (tester) async {
    await tester.pumpWidget(_screenHarness(isAdmin: true));
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_searchAllFields), findsOneWidget);
  });

  testWidgets('opening the filter sheet and picking a type shows its chip',
      (tester) async {
    await tester.pumpWidget(_screenHarness(isAdmin: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text(tester.l10n.clients_filter));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(clientTypeLabel(tester.l10n, ClientType.residential)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsOneWidget);
  });
```

- [ ] **Step 3: Run and confirm they fail**

Run: `flutter test test/features/clients/screens/clients_screen_test.dart`
Expected: failures — the Filter button is not found.

- [ ] **Step 4: Rewrite the screen's master column**

In `lib/features/clients/screens/clients_screen.dart`:

Replace the `client_type_filter_bar.dart` import with:

```dart
import 'package:scheduling/features/clients/domain/models/clients_sort.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_filter_bar.dart';
import 'package:scheduling/features/clients/widgets/sections/clients_list_header.dart';
import 'package:scheduling/features/clients/widgets/sheets/clients_filter_sheet.dart';
```

Add to `_ListInformationState`:

```dart
  ClientsSort _sort = ClientsSort.name;
  int? _visibleCount;

  /// Street of the active building filter, remembered when it is picked so the
  /// chip can name it without this screen watching the scan.
  String? _activeBuildingLabel;

  Future<void> _openFilterSheet() async {
    final picked = await showClientsFilterSheet(context, selected: _filter);
    if (picked == null || !mounted) return;
    setState(() {
      _filter = picked;
      if (picked is! ClientsFilterBuilding) _activeBuildingLabel = null;
    });
  }
```

Change the search bar's hint:

```dart
      hintText: context.l10n.clients_searchAllFields,
```

Replace the `_tour.stepIf(TourStepId.clientsFilter, Consumer(...))` child of the
master `Column` with:

```dart
              _tour.stepIf(
                TourStepId.clientsFilter,
                ClientsFilterBar(
                  selected: _filter,
                  onOpen: _openFilterSheet,
                  onChanged: (next) => setState(() {
                    _filter = next;
                    _activeBuildingLabel = null;
                  }),
                  activeBuildingLabel: _activeBuildingLabel,
                ),
              ),
              ClientsListHeader(
                count: _visibleCount,
                sort: _sort,
                onSortChanged: (next) => setState(() => _sort = next),
              ),
```

Pass the two new arguments to `ClientsListView`:

```dart
                    sort: _sort,
                    onCountChanged: (count) {
                      if (_visibleCount == count) return;
                      setState(() => _visibleCount = count);
                    },
```

> The building chip's label: `ClientsFilterSheet` returns only the sealed
> filter, so have it pop a `(ClientsFilter, String?)` record instead — change
> `showClientsFilterSheet`'s type argument to
> `(ClientsFilter, String?)` and `_Option`'s `onChanged` to carry the row's
> `label` for the address rows and `null` for the rest. Assign the second
> element to `_activeBuildingLabel` in `_openFilterSheet`. Update the sheet's
> tests accordingly.

- [ ] **Step 5: Delete the retired widgets**

```bash
git rm lib/features/clients/widgets/sections/client_type_filter_bar.dart lib/features/clients/widgets/sections/client_address_filter_menu.dart test/features/clients/widgets/sections/client_address_filter_menu_test.dart
```

- [ ] **Step 6: Run the analyzer and the clients suites**

Run: `flutter analyze 2>&1 | grep -E "error •|warning •"`
Expected: empty.

Run: `flutter test test/features/clients/`
Expected: `All tests passed!` — fix `clients_scale_sweep_test.dart` and
`clients_providers_test.dart` if either still references the removed widgets or
the removed `buildingCount`.

- [ ] **Step 7: Commit**

```bash
git add -A lib/features/clients lib/l10n test/features/clients
git commit -m "feat(clients): replace the chip row with a filter sheet and sort"
```

---

### Task 10: The shared-address count moves to the client detail

The design accepts losing the Building pill *because* the count reappears here,
where it is a single document read rather than a roster scan.

**Files:**
- Modify: `lib/features/clients/widgets/views/client_detail_view.dart`
- Test: `test/features/clients/widgets/views/client_detail_view_test.dart`

- [ ] **Step 1: Add the ARB key**

In `lib/l10n/app_en.arb`:

```json
  "clients_sharedAddressCount": "{count, plural, =1{1 other client at this address} other{{count} other clients at this address}}",
  "@clients_sharedAddressCount": {
    "description": "How many other clients share this client's street address.",
    "placeholders": {"count": {"type": "int"}}
  },
```

In `lib/l10n/app_fr.arb`:

```json
  "clients_sharedAddressCount": "{count, plural, =1{1 autre client à cette adresse} other{{count} autres clients à cette adresse}}",
```

- [ ] **Step 2: Write the failing test**

Add to `test/features/clients/widgets/views/client_detail_view_test.dart`:

```dart
  testWidgets('names how many other clients share the address', (tester) async {
    await tester.pumpWidget(
      _detailHarness(
        _client(address: '1200 Rue Sherbrooke', city: 'Montreal'),
        buildings: const [
          ClientBuilding(
            key: 'k1',
            street: '1200 Rue Sherbrooke',
            city: 'Montreal',
            clientCount: 4,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(tester.l10n.clients_sharedAddressCount(3)), findsOneWidget);
  });

  testWidgets('says nothing when the address is not shared', (tester) async {
    await tester.pumpWidget(
      _detailHarness(_client(address: '1 Rue Unique', city: 'Montreal')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('at this address'), findsNothing);
  });
```

`_detailHarness` gains a `buildings` parameter that overrides
`clientBuildingsProvider`.

- [ ] **Step 3: Run and confirm it fails**

Run: `flutter test test/features/clients/widgets/views/client_detail_view_test.dart`
Expected: the first test fails — the string is not rendered.

- [ ] **Step 4: Render it**

In `client_detail_view.dart`, inside the address section, add a `Consumer` that
watches `clientBuildingsProvider`, finds the entry whose `key` equals
`buildingKeyFor(client)`, and renders
`l10n.clients_sharedAddressCount(entry.clientCount - 1)` when
`clientCount > 1`. Render nothing while the provider is loading or on error —
this is supplementary, and a spinner in a detail row reads as a fault.

Note the count shown is `clientCount - 1`: the string says *other* clients.

- [ ] **Step 5: Run the detail tests**

Run: `flutter test test/features/clients/widgets/views/client_detail_view_test.dart`
Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/clients/widgets/views/client_detail_view.dart test/features/clients/widgets/views/client_detail_view_test.dart lib/l10n/app_en.arb lib/l10n/app_fr.arb
git commit -m "feat(clients): show the shared-address count on the client detail"
```

---

### Task 11: The tour step and the rules

`TourStepId.clientsFilter` still targets the control this plan replaced, and its
copy describes chips that no longer exist. The 1.57 tour plan does NOT rewrite
it — it only carries the id in its frozen legacy snapshot — so it belongs here.

**Files:**
- Modify: `lib/l10n/app_en.arb:2821`, `lib/l10n/app_fr.arb`
- Modify: `.claude/rules/clients.md`
- Test: `test/features/clients/screens/clients_screen_test.dart`

- [ ] **Step 1: Rewrite the tour copy**

In `lib/l10n/app_en.arb`, replace the value of `tour_clientsFilterDesc`:

```json
  "tour_clientsFilterDesc": "Narrow the list by type, archived, or a shared address. Search still looks everywhere.",
```

Mirror in `lib/l10n/app_fr.arb`. Check `tour_clientsFilterTitle` too — if it
names "chips", reword it to name the Filter button.

- [ ] **Step 2: Confirm the step still has a target**

Run: `flutter test test/features/clients/screens/clients_screen_test.dart`

The screen already wraps `ClientsFilterBar` in
`_tour.stepIf(TourStepId.clientsFilter, ...)` from Task 9, so the target exists.
If `test/features/feature_tour/domain/tour_definitions_test.dart` pins the
clients catalog, run it too:

Run: `flutter test test/features/feature_tour/`
Expected: `All tests passed!`

- [ ] **Step 3: Record the rules**

In `.claude/rules/clients.md`, replace whatever documents the chip row and the
address menu with:

```markdown
- **The clients list's filter is ONE sheet, and the Filter button is pinned
  outside any scroller** (2026-09-04). The five-control 48px horizontal
  scroller it replaced put something off-screen on arrival at large text
  scale. `ClientsFilter` stays a sealed one-of, so the sheet is a SINGLE radio
  group across its two sections — picking an address clears a type. That reads
  as a bug and is not one; it is the constraint the chip row hid. Reopening
  multi-select means changing the sealed model, how the type and address
  queries compose, and the `firestore.rules` read clauses.
- **`ClientsFilterSheet` is the ONLY watcher of `clientBuildingsProvider`.**
  `ClientsListView` used to watch it and `clientBuildingKeysProvider` before
  the filter switch, so opening the tab paid the paged `orderBy('name')` scan
  (~700 docs) on top of the paginated first 50 — roughly 14x read
  amplification. Moving the watch onto the sheet takes it off the path
  everyone walks. Don't watch either provider from a list row or from
  `ClientsListView` again; removing the scan for real is still the
  server-maintained `buildings` aggregate at `clients_providers.dart`.
- **The clients row shows ONE badge.** Archived only. The type chip and the
  Building pill were removed 2026-09-04 — four signals competed under one
  name. Type lives in the filter sheet; the shared-address count lives on the
  client detail, where it is one document read.
- **`ClientsSort.mostJobs` and `.recentlyAdded` order by NULLABLE fields.**
  Firestore's `orderBy` returns only documents that HAVE the field, so a
  client whose `jobCount` the recount trigger never stamped, or a
  pre-`createdAt` import, silently disappears from those two sorts while still
  appearing under Name. `functions/scripts/backfill-client-sort-fields.js` is
  the prerequisite that closes it — a release prerequisite, not a follow-up,
  the same posture `searchTokens` took. `ClientsSort.requiresBackfill` is what
  a reader greps when a client goes missing from one sort only.
- **`fetchClientsPage`'s cursor tuple follows the sort.** The boundary cache is
  keyed `"<sort>:<docId>"` because a boundary captured under `name` resumes a
  `jobCount` query from a string. Don't collapse it back to one map.
- **`ClientsListView` carries no chrome.** The Filter button, the active chip
  and the header live in `clients_screen.dart`, because that view is ALSO the
  booking flow's client picker — keeping the chrome in the screen is what makes
  it suppressible for free rather than by a flag.
```

- [ ] **Step 4: Commit**

```bash
git add lib/l10n/app_en.arb lib/l10n/app_fr.arb .claude/rules/clients.md
git commit -m "docs(clients): rewrite the filter tour copy and record the new rules"
```

---

### Task 12: Full verification

- [ ] **Step 1: BOM scan**

```bash
git diff --name-only HEAD~11 -- '*.dart' | while read -r f; do
  [ -f "$f" ] && [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && echo "BOM: $f"
done
```

Expected: no output.

- [ ] **Step 2: Analyzer**

Run: `flutter analyze`
Expected: `No issues found!` — that is this repo's baseline, so any lint is
from this work.

- [ ] **Step 3: l10n drift**

Run: `cat lib/l10n/.gen/untranslated.json`
Expected: `{}`.

- [ ] **Step 4: Full Flutter suite**

Run: `flutter test`
Expected: `All tests passed!`, at a count at or above the 3255 recorded on
2026-09-05.

- [ ] **Step 5: Functions**

Run: `npm --prefix functions run lint && npm --prefix functions test`
Expected: eslint clean; all suites pass, at or above 1747.

- [ ] **Step 6: Report the deploy prerequisites, do NOT deploy**

This work is code-only by owner instruction (2026-09-05). Report, do not run:

1. `firebase deploy --only firestore:indexes` and wait for both new `clients`
   composites to read READY.
2. `node functions/scripts/backfill-client-sort-fields.js --dry-run`, then the
   real run.
3. Only then may an app build using "Most jobs" or "Recently added" ship.

Until 1 and 2 have both happened those two sorts return an incomplete list.
Never pass `--force` to a Firestore deploy — it deletes TTL policies missing
from `firestore.indexes.json` (all five went once, 2026-07-21).

---

## Self-review against the design doc

| Design element | Task |
|---|---|
| Search hint names what it matches | 9 |
| Filter button pinned first, outside the scroller, dot when active | 5 |
| Active filter as one dismissible chip | 5 |
| Filter sheet, two labelled sections, one radio group | 4 |
| List header: count left, sort right | 6 |
| Sort: Name / Most jobs / Recently added | 1, 2, 6 |
| Row: archived pill kept, type chip and Building pill removed | 8 |
| FAB unchanged | — (untouched) |
| Filters stay single-select | 4 (one radio group) |
| Building pill loss accepted, count moves to detail | 8, 10 |
| Sort ships with this change | 1, 2, 6 |
| Sheet shows counts next to each type and address | 4 (addresses) — **gap, see below** |
| Read-amplification fix: providers move to the sheet | 4, 7 |
| `clients_searchByNameOrPhone` retired, callers checked | 9 |
| Picker reuse: chrome suppressible | 7, 9 (chrome lives in the screen) |
| `tour_clientsFilterDesc` rewritten | 11 |
| "Most jobs" index confirmed or added | 3 |

**One deliberate gap.** The design says the sheet shows counts "next to each
type and address … free once it is open". Task 4 renders the count for
ADDRESSES only. A per-TYPE count is not free: `ClientBuilding` carries
`clientCount`, but nothing aggregates clients by type — it would need a second
reduction over the same scan window. That is a small addition to
`clients_providers.dart` (a `Provider.autoDispose<Map<ClientType, int>>` over
the scan, the shape `clientBuildingCountsProvider` already uses) and it is
deliberately left out of this plan so the read-amplification fix is not held up
by a cosmetic. Raise it with the owner rather than silently shipping either
choice.
